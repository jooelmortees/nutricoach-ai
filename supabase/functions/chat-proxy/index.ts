// ============================================================
// chat-proxy - Edge Function de Supabase
// Proxy seguro al agente Gemini 3.5 Flash con loop agentico (tool use).
// Streaming SSE hacia el cliente iOS.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { fetchGeminiChatCompletion } from "../_shared/gemini.ts";
import { generateDetailedMealPlan } from "../_shared/meal-plan.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const GEMINI_BASE_URL = Deno.env.get("GEMINI_BASE_URL") ?? "https://generativelanguage.googleapis.com/v1beta/openai";
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash";
const GEMINI_FALLBACK_MODEL = Deno.env.get("GEMINI_FALLBACK_MODEL") ?? "gemini-3.1-flash-lite";

const corsHeaders = {
  "Access-Control-Allow-Origin": "app.nutricoach://",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_AGENT_ITERATIONS = 6;
const CHAT_ATTACHMENTS_BUCKET = "chat-attachments";
const MAX_ATTACHMENTS = 8;
const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
const SIGNED_URL_TTL_SECONDS = 10 * 60;

type AttachmentType = "image" | "audio";

interface AttachmentRequest {
  type?: unknown;
  bucket?: unknown;
  path?: unknown;
  mime_type?: unknown;
  name?: unknown;
  size_bytes?: unknown;
  duration_seconds?: unknown;
  url?: unknown;
  data?: unknown;
}

interface StoredAttachment {
  type: AttachmentType;
  bucket: typeof CHAT_ATTACHMENTS_BUCKET;
  path: string;
  mime_type: string;
  name: string;
  size_bytes: number;
  duration_seconds: number | null;
}

type ValidatedAttachment =
  | { kind: "storage"; metadata: StoredAttachment }
  | {
    kind: "legacy";
    type: AttachmentType;
    mimeType?: string;
    url?: string;
    base64Data?: string;
    persisted: Record<string, string>;
  };

interface PreparedAttachments {
  persisted: Array<StoredAttachment | Record<string, string>>;
  imageUrls: string[];
  audioBase64: string[];
}

interface ChatRequest {
  conversation_id: string;
  client_message_id?: string;
  assistant_message_id?: string;
  message: string;
  attachments?: AttachmentRequest[];
  web_search?: boolean;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonError(405, "Method not allowed");
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonError(401, "Missing Authorization header");
    }

    // 1. Identificar al usuario con el token JWT
    const supabaseUser = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !user) {
      return jsonError(401, "Invalid token");
    }

    // 2. Parsear body
    let rawBody: unknown;
    try {
      rawBody = await req.json();
    } catch (_) {
      return jsonError(400, "Invalid JSON body");
    }
    if (!rawBody || typeof rawBody !== "object" || Array.isArray(rawBody)) {
      return jsonError(400, "Invalid request body");
    }
    const body = rawBody as ChatRequest;
    // Normalizar message: si viene undefined/null, lo convertimos a string vacío
    // para evitar errores downstream (trim, insert en BD, etc.).
    if (body.message !== undefined && body.message !== null && typeof body.message !== "string") {
      return jsonError(400, "Invalid message");
    }
    body.message = body.message ?? "";
    if (body.message.length > 20_000) {
      return jsonError(400, "Message is too long");
    }
    const conversationId = validateOptionalUuid(body.conversation_id);
    if (!conversationId) return jsonError(400, "Invalid conversation_id");
    body.conversation_id = conversationId;
    const clientMessageId = validateOptionalUuid(body.client_message_id) ?? crypto.randomUUID();
    const assistantMessageId = validateOptionalUuid(body.assistant_message_id) ?? crypto.randomUUID();
    if (body.web_search !== undefined && typeof body.web_search !== "boolean") {
      return jsonError(400, "Invalid web_search value");
    }
    const rawAttachments = body.attachments ?? [];
    const hasAttachments = Array.isArray(rawAttachments) && rawAttachments.length > 0;
    // Permitir message vacío si hay adjuntos (audio-only, image-only, audio+image).
    // El cliente ya inyecta un fallback descriptivo, pero el backend debe tolerarlo.
    if (!body.message.trim() && !hasAttachments) {
      return jsonError(400, "Missing conversation_id or message/attachments");
    }

    const attachments = validateAttachments(rawAttachments, user.id, body.conversation_id);

    // 3. Cliente con service_role (bypasea RLS) para el agente
    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 4. Verificar ownership antes de leer historial o escribir con service_role.
    const ownershipError = await verifyConversationOwnership(
      supabaseAdmin,
      body.conversation_id,
      user.id,
    );
    if (ownershipError) return ownershipError;

    const preparedAttachments = await prepareAttachments(supabaseAdmin, attachments);

    // 5. Cargar perfil, hechos relevantes y mensajes recientes
    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMessages = await loadRecentMessages(
      supabaseAdmin,
      body.conversation_id,
      clientMessageId,
      20,
    );

    // 6. System prompt
    const systemPrompt = buildSystemPrompt(profile, facts);

    // 7. Guardar mensaje del usuario en BD
    await saveUserMessage(
      supabaseAdmin,
      clientMessageId,
      body.conversation_id,
      body.message,
      preparedAttachments.persisted,
    );

    // 8. Construir mensajes para la API (formato OpenAI multimodal).
    //    image_url acepta URL pública directamente (signed URL funciona).
    const userContent: any[] = [];
    for (const imageUrl of preparedAttachments.imageUrls) {
      userContent.push({
        type: "image_url",
        image_url: { url: imageUrl },
      });
    }
    // Audio: inline_data como input_audio (formato OpenAI-compatible soportado por Gemini).
    // El cliente envía WAV (PCM 16-bit) en base64 con mime_type "audio/wav".
    // NOTA: Verificado empiricamente 2026-07-08: Gemini 3.5 Flash NO procesa
    // audio en modo streaming (stream:true). El audio llega pero Gemini
    // responde "no he podido escuchar el audio". Sin streaming (stream:false)
    // el audio SÍ se procesa (confirmado con promptTokensDetails AUDIO=25).
    // Solucion: cuando hay audio, hacemos la llamada sin streaming y emitimos
    // la respuesta completa como eventos SSE al cliente.
    const hasAudio = preparedAttachments.audioBase64.length > 0;
    for (const audioBase64 of preparedAttachments.audioBase64) {
      userContent.push({
        type: "input_audio",
        input_audio: { data: audioBase64, format: "wav" },
      });
    }
    let displayMessage = body.message;
    if (preparedAttachments.imageUrls.length > 0 && preparedAttachments.audioBase64.length > 0) {
      // Imagen + audio: prompt conjunto
      const prefix = body.message.trim() ? body.message + "\n\n" : "";
      displayMessage = prefix +
        "Analiza esta imagen de comida y escucha el audio del usuario. " +
        "Devuelve las macros estimadas (kcal, proteínas, carbohidratos, grasas) en formato JSON al inicio de tu respuesta, seguido de un comentario en español.";
    } else if (preparedAttachments.imageUrls.length > 0) {
      displayMessage = body.message +
        (body.message.trim() ? "" : "\n\n") +
        "\n\nAnaliza esta imagen de comida y devuelve las macros estimadas (kcal, proteínas, carbohidratos, grasas) en formato JSON al inicio de tu respuesta, seguido de un comentario en español.";
    } else if (preparedAttachments.audioBase64.length > 0 && !body.message.trim()) {
      // Audio sin texto ni imagen: fallback descriptivo
      displayMessage = "Escucha este audio del usuario y responde.";
    }
    userContent.push({ type: "text", text: displayMessage });

    // 9. Mensajes base para la API. 'system' es un mensaje role: system.
    let apiMessages: any[] = [
      { role: "system", content: systemPrompt },
      ...recentMessages.map((m: any) => ({ role: m.role, content: m.content })),
      { role: "user", content: userContent },
    ];

    // 10. Tools (function calling formato OpenAI)
    const tools = getAgentTools().filter((tool) =>
      body.web_search === true || tool.function.name !== "web_search"
    );

    // 11. Loop agentico: Gemini puede llamar tools, ejecutamos, volvemos a llamar
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        let fullText = "";
        let detectedMacros: any = null;
        let savedMealFlag = false;
        let assistantMessageSaved = false;
        let activeModel = GEMINI_MODEL;

        try {
          for (let iteration = 0; iteration < MAX_AGENT_ITERATIONS; iteration++) {
            // Hacer request a Gemini.
            // NOTA: cuando hay audio (hasAudio && iteration === 0), usamos
            // stream: false porque Gemini 3.5 Flash NO procesa audio en
            // modo streaming (verificado empiricamente 2026-07-08: el audio
            // llega pero Gemini responde "no he podido escuchar el audio"
            // con stream:true, mientras que con stream:false el audio se
            // procesa correctamente con promptTokensDetails AUDIO=25).
            const useStreaming = !hasAudio;
            const geminiResult = await fetchGeminiChatCompletion({
              apiKey: GEMINI_API_KEY,
              baseUrl: GEMINI_BASE_URL,
              primaryModel: GEMINI_MODEL,
              fallbackModel: GEMINI_FALLBACK_MODEL,
              preferredModel: activeModel,
              body: {
                messages: apiMessages,
                tools,
                stream: useStreaming,
                max_completion_tokens: 16384,
                reasoning_effort: "medium",
                // IMPORTANTE: Gemini 3.5 Flash emite el thinking en delta.content
                // envuelto en tags <thought>...</thought> con un marcador
                // extra_content.google.thought = true en cada chunk de thinking.
                // El parser en backend separa los bloques <thought> del content.
              },
            });
            const upstreamResp = geminiResult.response;
            activeModel = geminiResult.model;

            if (!upstreamResp.ok) {
              const errText = await upstreamResp.text();
              controller.enqueue(encoder.encode(sseEvent("error", { message: `Gemini error ${upstreamResp.status}: ${errText}` })));
              return;
            }

            // Si no hay streaming (audio en primera iteracion), parsear JSON unico
            if (!useStreaming) {
              const data = await upstreamResp.json();
              const choice = data.choices?.[0];
              if (!choice) {
                controller.enqueue(encoder.encode(sseEvent("error", { message: "Gemini: respuesta vacia" })));
                return;
              }
              const message = choice.message;
              let iterThinking = "";
              let iterText = "";
              let toolCalls: any[] = [];

              // Parsear thinking (<thought>...</thought> en content)
              if (message?.content) {
                const thinkMatch = message.content.match(/<thought>([\s\S]*?)<\/thought>/);
                if (thinkMatch) {
                  iterThinking = thinkMatch[1];
                  iterText = message.content.substring(thinkMatch.index! + thinkMatch[0].length);
                } else {
                  iterText = message.content;
                }
              }

              // Emitir thinking
              if (iterThinking) {
                controller.enqueue(encoder.encode(sseEvent("thinking", { text: iterThinking })));
              }
              // Emitir texto
              if (iterText) {
                controller.enqueue(encoder.encode(sseEvent("text", { text: iterText })));
              }
              fullText = iterText;

              // Tool calls
              if (message?.tool_calls) {
                for (const tc of message.tool_calls) {
                  toolCalls.push({
                    id: tc.id,
                    type: "function",
                    function: { name: tc.function.name, arguments: tc.function.arguments },
                    thought_signature: tc.extra_content?.google?.thought_signature ?? null,
                  });
                }
              }

              // Si no hay tool_calls, guardar y terminar
              if (toolCalls.length === 0) {
                if (!assistantMessageSaved && (fullText || iterThinking)) {
                  await saveAssistantMessage(
                    supabaseAdmin,
                    assistantMessageId,
                    body.conversation_id,
                    fullText || iterText,
                    iterThinking || null
                  );
                  assistantMessageSaved = true;
                }
                break;
              }

              // Hay tool_calls: ejecutar y continuar el loop
              const toolNames = toolCalls.map(t => t.function.name);
              controller.enqueue(encoder.encode(sseEvent("tools_start", { names: toolNames })));

              apiMessages.push({
                role: "assistant",
                content: iterText || null,
                tool_calls: toolCalls.map(tc => {
                  const tcMsg: any = {
                    id: tc.id,
                    type: "function",
                    function: { name: tc.function.name, arguments: tc.function.arguments },
                  };
                  if (tc.thought_signature) {
                    tcMsg.extra_content = { google: { thought_signature: tc.thought_signature } };
                  }
                  return tcMsg;
                })
              });

              for (const tc of toolCalls) {
                const name = tc.function.name;
                let args: any = {};
                try { args = JSON.parse(tc.function.arguments || "{}"); } catch (_) { args = {}; }
                const toolResult = await executeToolWithKeepAlive(
                  name,
                  args,
                  supabaseAdmin,
                  user.id,
                  profile,
                  facts,
                  tc.id,
                  controller,
                  encoder,
                );
                controller.enqueue(encoder.encode(sseEvent("tool_done", { name, summary: toolResult.summary })));
                apiMessages.push({
                  role: "tool",
                  tool_call_id: tc.id,
                  content: toolResult.content
                });
              }
              continue;
            }

            // Parsear el stream de Gemini
            const reader = upstreamResp.body!.getReader();
            const decoder = new TextDecoder();
            let buffer = "";
            // Buffer persistente para el parser de <thought>...</thought>
            // (necesario porque los tags pueden llegar partidos en varios chunks)
            let rawContent = "";
            let emittedTextLen = 0;
            let iterThinking = "";
            let iterText = "";
            let toolCalls: any[] = [];
            let finishReason = "stop";

            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              buffer += decoder.decode(value, { stream: true });

              const lines = buffer.split("\n");
              buffer = lines.pop() ?? "";

              for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed || !trimmed.startsWith("data:")) continue;
                const payload = trimmed.slice(5).trim();
                if (payload === "[DONE]") continue;
                try {
                  const chunk = JSON.parse(payload);
                  const choice = chunk.choices?.[0];
                  if (!choice) continue;
                  finishReason = choice.finish_reason || finishReason;
                  const delta = choice.delta;

                  // 1. reasoning_content (algunos servers lo usan; Gemini no,
                  //    pero lo dejamos por compatibilidad futura)
                  if (delta?.reasoning_content) {
                    iterThinking += delta.reasoning_content;
                    controller.enqueue(encoder.encode(sseEvent("thinking", { text: delta.reasoning_content })));
                  }

                  // 2. content: parsear streaming de <thought>...</thought>
                  //    Gemini 3.5 Flash con reasoning_effort emite el thinking
                  //    en delta.content envuelto en tags <thought>...</thought>
                  //    con un marcador extra_content.google.thought = true en
                  //    cada chunk de thinking. Necesitamos separar en streaming
                  //    porque el cliente espera eventos thinking y text por
                  //    separado.
                  if (delta?.content) {
                    rawContent += delta.content;
                    // Aplicar regex para extraer bloque <thought> cerrado
                    const thinkMatch = rawContent.match(/<thought>([\s\S]*?)<\/thought>/);
                    if (thinkMatch) {
                      // Hay un bloque <thought> completo
                      const thinkStart = thinkMatch.index!;
                      const thinkEnd = thinkStart + thinkMatch[0].length;
                      // thinking text = lo que esta entre tags (sin doble emision)
                      const newThinking = thinkMatch[1];
                      if (newThinking.length > iterThinking.length) {
                        const thinkingDelta = newThinking.substring(iterThinking.length);
                        iterThinking = newThinking;
                        controller.enqueue(encoder.encode(sseEvent("thinking", { text: thinkingDelta })));
                      }
                      // text = lo que va despues de </thought>
                      const textAfter = rawContent.substring(thinkEnd);
                      if (textAfter.length > emittedTextLen) {
                        const textDelta = textAfter.substring(emittedTextLen);
                        emittedTextLen = textAfter.length;
                        iterText = textAfter;
                        fullText = textAfter;
                        controller.enqueue(encoder.encode(sseEvent("text", { text: textDelta })));
                      }
                    } else if (!rawContent.includes("<thought>")) {
                      // No hay <thought> y no se ha visto: emitir todo como text
                      if (rawContent.length > emittedTextLen) {
                        const textDelta = rawContent.substring(emittedTextLen);
                        emittedTextLen = rawContent.length;
                        iterText = rawContent;
                        fullText = rawContent;
                        controller.enqueue(encoder.encode(sseEvent("text", { text: textDelta })));
                      }
                    }
                    // Si <thought> esta abierto (sin cierre), esperar al siguiente chunk
                  }

                  // 3. tool_calls (function calling)
                  //    Gemini anade extra_content.google.thought_signature a cada
                  //    tool_call. Es OBLIGATORIO reenviarlo en el assistant message
                  //    del historial para la siguiente iteracion (si no, error 400).
                  if (delta?.tool_calls) {
                    for (const tc of delta.tool_calls) {
                      const idx = tc.index ?? toolCalls.length;
                      if (!toolCalls[idx]) {
                        toolCalls[idx] = {
                          id: tc.id,
                          type: "function",
                          function: { name: "", arguments: "" },
                          thought_signature: null as string | null,
                        };
                      }
                      if (tc.id) toolCalls[idx].id = tc.id;
                      if (tc.function?.name) toolCalls[idx].function.name = tc.function.name;
                      if (tc.function?.arguments) toolCalls[idx].function.arguments += tc.function.arguments;
                      // Capturar thought_signature (viene en extra_content.google)
                      const sig = tc.extra_content?.google?.thought_signature;
                      if (sig) toolCalls[idx].thought_signature = sig;
                    }
                  }
                } catch (e) {
                  // chunk malformado, ignorar
                }
              }
            }

            // Si no hay tool_calls, terminamos el loop
            // NOTA: Gemini en streaming puede emitir finish_reason "stop" incluso
            // cuando hay tool_calls acumulados (verificado empiricamente 2026-07-08).
            // Por eso comprobamos toolCalls.length primero: si hay tools, las
            // ejecutamos sin importar el finishReason.
            if (toolCalls.length === 0) {
              if (!assistantMessageSaved && (fullText || iterThinking)) {
                await saveAssistantMessage(
                  supabaseAdmin,
                  assistantMessageId,
                  body.conversation_id,
                  fullText || iterText,
                  iterThinking || null
                );
                assistantMessageSaved = true;
              }
              break;
            }

            // Hay tool_calls: ejecutar y volver a llamar a Gemini
            // Emitir evento tools_start con nombres legibles de las tools
            const toolNames = toolCalls.map(t => t.function.name);
            controller.enqueue(encoder.encode(sseEvent("tools_start", { names: toolNames })));

            // Anadir el assistant message con tool_calls al historial
            // CRITICO: incluir thought_signature en cada tool_call. Gemini lo
            // exige para la siguiente iteracion del loop (si no, error 400:
            // "Function call is missing a thought_signature").
            apiMessages.push({
              role: "assistant",
              content: iterText || null,
              tool_calls: toolCalls.map(tc => {
                const tcMsg: any = {
                  id: tc.id,
                  type: "function",
                  function: { name: tc.function.name, arguments: tc.function.arguments },
                };
                if (tc.thought_signature) {
                  tcMsg.extra_content = { google: { thought_signature: tc.thought_signature } };
                }
                return tcMsg;
              })
            });

            // Ejecutar cada tool y emitir su resultado al cliente
            for (const tc of toolCalls) {
              const name = tc.function.name;
              let args: any = {};
              try { args = JSON.parse(tc.function.arguments || "{}"); } catch (_) { args = {}; }
              const toolResult = await executeToolWithKeepAlive(
                name,
                args,
                supabaseAdmin,
                user.id,
                profile,
                facts,
                tc.id,
                controller,
                encoder,
              );
              // Emitir tool_done con el summary legible
              controller.enqueue(encoder.encode(sseEvent("tool_done", { name, summary: toolResult.summary })));
              // Anadir el resultado al historial
              apiMessages.push({
                role: "tool",
                tool_call_id: tc.id,
                content: toolResult.content
              });
            }

            // Limpiar toolCalls para la siguiente iteracion
            toolCalls = [];
          }

          // Guardar macros si hay imagen adjunta
          if (detectedMacros && !savedMealFlag) {
            try {
              await saveMeal(supabaseAdmin, user.id, detectedMacros);
              controller.enqueue(encoder.encode(sseEvent("meal_saved", detectedMacros)));
              savedMealFlag = true;
            } catch (e) {
              console.error("saveMeal error:", e);
            }
          }
        } catch (err) {
          controller.enqueue(encoder.encode(sseEvent("error", { message: String(err) })));
        } finally {
          // SIEMPRE emitir 'done' al final para que el cliente no se quede
          // colgado con isAgentThinking=true.
          controller.enqueue(encoder.encode(sseEvent("done", {})));
          controller.close();
        }
      },
    });

    return new Response(stream, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });
  } catch (err) {
    if (err instanceof HttpError) {
      return jsonError(err.status, err.message);
    }
    return jsonError(500, String(err));
  }
});

// ============================================================
// HELPERS
// ============================================================

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "HttpError";
  }
}

function jsonError(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function sseEvent(event: string, data: any) {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

function extractJson(text: string): string | null {
  const firstBrace = text.indexOf("{");
  const lastBrace = text.lastIndexOf("}");
  if (firstBrace === -1 || lastBrace === -1 || lastBrace <= firstBrace) return null;
  return text.substring(firstBrace, lastBrace + 1);
}

async function verifyConversationOwnership(
  supabase: any,
  conversationId: string,
  userId: string,
): Promise<Response | null> {
  const { data, error } = await supabase
    .from("conversations")
    .select("user_id")
    .eq("id", conversationId)
    .maybeSingle();

  if (error) {
    throw new HttpError(500, `Error verificando la conversación: ${error.message}`);
  }
  if (!data) return jsonError(404, "Conversation not found");
  if (String(data.user_id).toLowerCase() !== userId.toLowerCase()) {
    return jsonError(403, "Conversation does not belong to the authenticated user");
  }
  return null;
}

function validateAttachments(
  rawAttachments: unknown,
  userId: string,
  conversationId: string,
): ValidatedAttachment[] {
  if (!Array.isArray(rawAttachments)) {
    throw new HttpError(400, "attachments must be an array");
  }
  if (rawAttachments.length > MAX_ATTACHMENTS) {
    throw new HttpError(400, `A maximum of ${MAX_ATTACHMENTS} attachments is allowed`);
  }

  const validated = rawAttachments.map((rawAttachment, index) => {
    if (!rawAttachment || typeof rawAttachment !== "object" || Array.isArray(rawAttachment)) {
      throw new HttpError(400, `Attachment ${index + 1} is invalid`);
    }
    const attachment = rawAttachment as AttachmentRequest;
    const type = validateAttachmentType(attachment.type, index);
    const isStorageAttachment = attachment.path !== undefined || attachment.bucket !== undefined;

    if (isStorageAttachment) {
      return validateStorageAttachment(attachment, type, userId, conversationId, index);
    }
    throw new HttpError(400, `Attachment ${index + 1} must use private storage`);
  });

  if (validated.filter((attachment) => attachment.kind === "storage" && attachment.metadata.type === "audio").length > 1) {
    throw new HttpError(400, "Only one audio attachment is allowed");
  }
  return validated;
}

function validateOptionalUuid(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new HttpError(400, "Invalid message id");
  }
  return value.toLowerCase();
}

function validateAttachmentType(value: unknown, index: number): AttachmentType {
  if (value !== "image" && value !== "audio") {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid type`);
  }
  return value;
}

function validateStorageAttachment(
  attachment: AttachmentRequest,
  type: AttachmentType,
  userId: string,
  conversationId: string,
  index: number,
): ValidatedAttachment {
  if (attachment.bucket !== CHAT_ATTACHMENTS_BUCKET) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid bucket`);
  }
  if (attachment.url !== undefined || attachment.data !== undefined) {
    throw new HttpError(400, `Storage attachment ${index + 1} must not include legacy url or data`);
  }
  if (typeof attachment.path !== "string" || !attachment.path || attachment.path.length > 1024) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid path`);
  }

  const pathSegments = attachment.path.split("/");
  if (
    pathSegments.length < 3 ||
    pathSegments.some((segment) => !segment || segment === "." || segment === "..") ||
    pathSegments[0].toLowerCase() !== userId.toLowerCase() ||
    pathSegments[1].toLowerCase() !== conversationId.toLowerCase()
  ) {
    throw new HttpError(400, `Attachment ${index + 1} path does not match the user and conversation`);
  }

  const mimeType = validateMimeType(attachment.mime_type, type, index);
  if (typeof attachment.name !== "string" || !attachment.name.trim() || attachment.name.length > 255) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid name`);
  }
  if (
    typeof attachment.size_bytes !== "number" ||
    !Number.isSafeInteger(attachment.size_bytes) ||
    attachment.size_bytes <= 0 ||
    attachment.size_bytes > MAX_ATTACHMENT_BYTES
  ) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid size_bytes`);
  }

  const duration = attachment.duration_seconds;
  if (
    duration !== undefined &&
    duration !== null &&
    (typeof duration !== "number" || !Number.isFinite(duration) || duration < 0)
  ) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid duration_seconds`);
  }

  return {
    kind: "storage",
    metadata: {
      type,
      bucket: CHAT_ATTACHMENTS_BUCKET,
      path: attachment.path,
      mime_type: mimeType,
      name: attachment.name.trim(),
      size_bytes: attachment.size_bytes,
      duration_seconds: duration === undefined || duration === null ? null : duration,
    },
  };
}

function validateLegacyAttachment(
  attachment: AttachmentRequest,
  type: AttachmentType,
  index: number,
): ValidatedAttachment {
  const url = attachment.url === undefined ? undefined : validateLegacyUrl(attachment.url, index);
  const mimeType = attachment.mime_type === undefined
    ? undefined
    : validateMimeType(attachment.mime_type, type, index);
  if (attachment.data !== undefined && !mimeType) {
    throw new HttpError(400, `Legacy attachment ${index + 1} with data requires mime_type`);
  }
  const base64Data = attachment.data === undefined
    ? undefined
    : validateBase64Data(attachment.data, mimeType, type, index);

  if (type === "image" && !url && !base64Data) {
    throw new HttpError(400, `Legacy image attachment ${index + 1} requires url or data`);
  }
  if (type === "audio" && !base64Data) {
    throw new HttpError(400, `Legacy audio attachment ${index + 1} requires data`);
  }

  const persisted: Record<string, string> = { type };
  if (url) persisted.url = url;
  if (base64Data) persisted.data = attachment.data as string;
  if (mimeType) persisted.mime_type = mimeType;

  return { kind: "legacy", type, mimeType, url, base64Data, persisted };
}

function validateMimeType(value: unknown, type: AttachmentType, index: number): string {
  if (typeof value !== "string") {
    throw new HttpError(400, `Attachment ${index + 1} requires mime_type`);
  }
  const mimeType = value.toLowerCase();
  const allowed = type === "image" ? ["image/jpeg", "image/png"] : ["audio/wav"];
  if (!allowed.includes(mimeType)) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid mime_type`);
  }
  return mimeType;
}

function validateLegacyUrl(value: unknown, index: number): string {
  if (typeof value !== "string" || value.length > 4096) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid url`);
  }
  try {
    const url = new URL(value);
    if (url.protocol !== "https:") throw new Error("Invalid protocol");
  } catch (_) {
    throw new HttpError(400, `Attachment ${index + 1} has an invalid url`);
  }
  return value;
}

function validateBase64Data(
  value: unknown,
  mimeType: string | undefined,
  type: AttachmentType,
  index: number,
): string {
  if (typeof value !== "string" || !value) {
    throw new HttpError(400, `Attachment ${index + 1} has invalid base64 data`);
  }

  let base64Data = value;
  const dataUrlMatch = value.match(/^data:([^;,]+);base64,([A-Za-z0-9+/]*={0,2})$/);
  if (value.startsWith("data:")) {
    if (!dataUrlMatch) {
      throw new HttpError(400, `Attachment ${index + 1} has invalid base64 data`);
    }
    const embeddedMimeType = validateMimeType(dataUrlMatch[1], type, index);
    if (mimeType && embeddedMimeType !== mimeType) {
      throw new HttpError(400, `Attachment ${index + 1} has inconsistent mime_type`);
    }
    base64Data = dataUrlMatch[2];
  }

  if (
    base64Data.length > Math.ceil(MAX_ATTACHMENT_BYTES * 4 / 3) + 4 ||
    base64Data.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(base64Data)
  ) {
    throw new HttpError(400, `Attachment ${index + 1} has invalid base64 data`);
  }

  const padding = base64Data.endsWith("==") ? 2 : base64Data.endsWith("=") ? 1 : 0;
  const decodedSize = (base64Data.length * 3 / 4) - padding;
  if (decodedSize <= 0 || decodedSize > MAX_ATTACHMENT_BYTES) {
    throw new HttpError(400, `Attachment ${index + 1} exceeds the 8 MiB limit`);
  }
  return base64Data;
}

async function prepareAttachments(
  supabase: any,
  attachments: ValidatedAttachment[],
): Promise<PreparedAttachments> {
  const prepared: PreparedAttachments = { persisted: [], imageUrls: [], audioBase64: [] };

  for (const attachment of attachments) {
    if (attachment.kind === "legacy") {
      prepared.persisted.push(attachment.persisted);
      if (attachment.type === "image") {
        if (attachment.url) {
          prepared.imageUrls.push(attachment.url);
        } else if (attachment.base64Data && attachment.mimeType) {
          prepared.imageUrls.push(`data:${attachment.mimeType};base64,${attachment.base64Data}`);
        }
      } else if (attachment.base64Data) {
        prepared.audioBase64.push(attachment.base64Data);
      }
      continue;
    }

    const metadata = attachment.metadata;
    prepared.persisted.push(metadata);
    const storage = supabase.storage.from(metadata.bucket);

    if (metadata.type === "image") {
      const { data, error } = await storage.createSignedUrl(metadata.path, SIGNED_URL_TTL_SECONDS);
      if (error || !data?.signedUrl) {
        throw new HttpError(400, `No se pudo acceder al adjunto ${metadata.name}: ${error?.message ?? "URL no disponible"}`);
      }
      prepared.imageUrls.push(data.signedUrl);
      continue;
    }

    const { data, error } = await storage.download(metadata.path);
    if (error || !data) {
      throw new HttpError(400, `No se pudo descargar el adjunto ${metadata.name}: ${error?.message ?? "archivo no disponible"}`);
    }
    if (data.size > MAX_ATTACHMENT_BYTES || data.size !== metadata.size_bytes) {
      throw new HttpError(400, `El tamaño real del adjunto ${metadata.name} no coincide con size_bytes`);
    }
    if (data.type && data.type.toLowerCase() !== metadata.mime_type) {
      throw new HttpError(400, `El MIME real del adjunto ${metadata.name} no coincide con mime_type`);
    }
    prepared.audioBase64.push(bytesToBase64(new Uint8Array(await data.arrayBuffer())));
  }

  return prepared;
}

function bytesToBase64(bytes: Uint8Array): string {
  const chunkSize = 0x8000;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

async function loadProfile(supabase: any, userId: string) {
  const { data } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", userId)
    .single();
  return data;
}

async function loadActiveFacts(supabase: any, userId: string) {
  const { data } = await supabase
    .from("user_facts")
    .select("*")
    .eq("user_id", userId)
    .eq("is_active", true)
    .order("last_confirmed_at", { ascending: false })
    .limit(50);
  return data ?? [];
}

async function loadRecentMessages(
  supabase: any,
  conversationId: string,
  excludeMessageId: string,
  limit: number,
) {
  const { data, error } = await supabase
    .from("messages")
    .select("role, content, thinking, attachments")
    .eq("conversation_id", conversationId)
    .neq("id", excludeMessageId)
    .order("created_at", { ascending: false })
    .order("id", { ascending: false })
    .limit(limit);
  if (error) {
    throw new Error(`Error cargando mensajes recientes: ${error.message}`);
  }
  return (data ?? []).reverse().map((message: any) => {
    if (message.content?.trim()) return message;
    const attachments = Array.isArray(message.attachments) ? message.attachments : [];
    const hasAudio = attachments.some((attachment: any) => attachment?.type === "audio");
    const hasImage = attachments.some((attachment: any) => attachment?.type === "image");
    return {
      ...message,
      content: hasAudio && hasImage
        ? "[El usuario envió una imagen y una nota de voz en este turno.]"
        : hasAudio
        ? "[El usuario envió una nota de voz en este turno.]"
        : hasImage
        ? "[El usuario envió una imagen en este turno.]"
        : "[Mensaje sin texto]",
    };
  });
}

async function saveUserMessage(
  supabase: any,
  messageId: string,
  conversationId: string,
  content: string,
  attachments?: any[]
) {
  const { error: insertError } = await supabase.from("messages").insert({
    id: messageId,
    conversation_id: conversationId,
    role: "user",
    content,
    attachments: attachments ?? [],
  });
  if (insertError) {
    if (insertError.code !== "23505") {
      throw new Error(`Error guardando el mensaje del usuario: ${insertError.message}`);
    }
    const { data: existing, error: existingError } = await supabase
      .from("messages")
      .select("conversation_id, role")
      .eq("id", messageId)
      .maybeSingle();
    if (
      existingError ||
      !existing ||
      String(existing.conversation_id).toLowerCase() !== conversationId.toLowerCase() ||
      existing.role !== "user"
    ) {
      throw new HttpError(409, "Message id is already in use");
    }
  }

  const { error: updateError } = await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
  if (updateError) {
    throw new Error(`Error actualizando la conversación: ${updateError.message}`);
  }
}

async function saveAssistantMessage(
  supabase: any,
  messageId: string,
  conversationId: string,
  content: string,
  thinking?: string | null
) {
  const { data: existing, error: existingError } = await supabase
    .from("messages")
    .select("conversation_id, role")
    .eq("id", messageId)
    .maybeSingle();
  if (existingError) {
    throw new Error(`Error comprobando el mensaje del asistente: ${existingError.message}`);
  }

  if (existing) {
    if (String(existing.conversation_id).toLowerCase() !== conversationId.toLowerCase() || existing.role !== "assistant") {
      throw new HttpError(409, "Assistant message id is already in use");
    }
    const { error: updateMessageError } = await supabase
      .from("messages")
      .update({ content: content || "", thinking: thinking || null })
      .eq("id", messageId);
    if (updateMessageError) {
      throw new Error(`Error actualizando el mensaje del asistente: ${updateMessageError.message}`);
    }
  } else {
    const { error: insertError } = await supabase.from("messages").insert({
      id: messageId,
      conversation_id: conversationId,
      role: "assistant",
      content: content || "",
      thinking: thinking || null,
    });
    if (insertError) {
      throw new Error(`Error guardando el mensaje del asistente: ${insertError.message}`);
    }
  }

  const { error: updateError } = await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
  if (updateError) {
    throw new Error(`Error actualizando la conversación: ${updateError.message}`);
  }
}

async function saveMeal(supabase: any, userId: string, analysis: any) {
  const { error } = await supabase.from("meals").insert({
    user_id: userId,
    name: analysis.description ?? "Sin descripción",
    meal_type: analysis.meal_type ?? "other",
    total_kcal: analysis.kcal ?? null,
    total_protein_g: analysis.protein_g ?? null,
    total_carbs_g: analysis.carbs_g ?? null,
    total_fat_g: analysis.fat_g ?? null,
    source: "ai_suggestion",
    notes: analysis.confidence ? `confidence=${analysis.confidence} source=ai` : "source=ai",
  });
  if (error) console.error("saveMeal error:", error);
}

// ============================================================
// AGENT TOOLS - ejecutados en el loop agentico
// ============================================================

interface ToolResult {
  content: string;       // Texto que se envia a Gemini como tool_result
  summary: string;       // Resumen para emitir al cliente via SSE
}

async function executeToolWithKeepAlive(
  name: string,
  args: any,
  supabase: any,
  userId: string,
  profile: any,
  facts: any[],
  toolCallId: string | undefined,
  controller: ReadableStreamDefaultController<Uint8Array>,
  encoder: TextEncoder,
): Promise<ToolResult> {
  const intervalId = setInterval(() => {
    try {
      controller.enqueue(encoder.encode(": keep-alive\n\n"));
    } catch (error) {
      console.warn("No se pudo emitir keep-alive SSE:", error);
      clearInterval(intervalId);
    }
  }, 10_000);
  try {
    return await executeTool(name, args, supabase, userId, profile, facts, toolCallId);
  } finally {
    clearInterval(intervalId);
  }
}

async function executeTool(
  name: string,
  args: any,
  supabase: any,
  userId: string,
  profile: any,
  facts: any[],
  toolCallId?: string,
): Promise<ToolResult> {
  try {
    switch (name) {
      case "get_user_profile": {
        // El perfil ya esta en el system prompt, pero podemos dar info adicional
        return {
          content: JSON.stringify({
            profile: profile || null,
            facts_count: facts?.length ?? 0,
            note: "El perfil completo ya esta en el system prompt."
          }),
          summary: "Perfil del usuario consultado"
        };
      }
      case "remember_fact": {
        const { category, fact, confidence } = args;
        if (!category || !fact) {
          return { content: "Error: faltan campos category o fact", summary: "Error en remember_fact" };
        }
        // Guardar el fact en user_facts
        const { data, error } = await supabase
          .from("user_facts")
          .insert({
            user_id: userId,
            category,
            fact,
            confidence: confidence ?? 0.8,
            is_active: true,
            last_confirmed_at: new Date().toISOString(),
          })
          .select()
          .single();
        if (error) {
          console.error("remember_fact error:", error);
          return { content: `Error guardando fact: ${error.message}`, summary: "Error al guardar" };
        }
        return {
          content: JSON.stringify({ ok: true, id: data?.id, fact, category }),
          summary: `Recordado: [${category}] ${fact}`
        };
      }
      case "web_search": {
        // TODO: implementar busqueda real cuando haya MCP de web search
        // Por ahora devolvemos un placeholder
        return {
          content: "La busqueda web no esta implementada todavia. Usa tu conocimiento general para esta consulta.",
          summary: "Busqueda web no implementada"
        };
      }
      case "get_recent_meals": {
        const today = new Date();
        const weekAgo = new Date(today.getTime() - 7 * 24 * 60 * 60 * 1000);
        const { data, error } = await supabase
          .from("meals")
          .select("name, meal_type, total_kcal, total_protein_g, total_carbs_g, total_fat_g, logged_at")
          .eq("user_id", userId)
          .gte("logged_at", weekAgo.toISOString())
          .order("logged_at", { ascending: false });
        if (error) {
          return { content: `Error: ${error.message}`, summary: "Error leyendo meals" };
        }
        return {
          content: JSON.stringify({ meals: data ?? [], count: data?.length ?? 0 }),
          summary: `${data?.length ?? 0} comidas de los ultimos 7 dias`
        };
      }
      case "get_water_summary": {
        const summary = await fetchWaterSummary(supabase, userId, profile);
        return {
          content: JSON.stringify({ ok: true, ...summary }),
          summary: `${summary.consumed_ml} de ${summary.target_ml} ml de agua hoy`,
        };
      }
      case "log_water": {
        const amountMl = Number(args?.amount_ml);
        if (!Number.isInteger(amountMl) || amountMl < 1 || amountMl > 5000) {
          return {
            content: JSON.stringify({
              ok: false,
              error: "amount_ml debe ser un entero entre 1 y 5000",
            }),
            summary: "Cantidad de agua no valida",
          };
        }

        let loggedAt = new Date();
        if (args?.logged_at !== undefined) {
          if (typeof args.logged_at !== "string") {
            return {
              content: JSON.stringify({ ok: false, error: "logged_at debe ser una fecha ISO" }),
              summary: "Fecha de agua no valida",
            };
          }
          loggedAt = new Date(args.logged_at);
          if (Number.isNaN(loggedAt.getTime())) {
            return {
              content: JSON.stringify({ ok: false, error: "logged_at no es una fecha ISO valida" }),
              summary: "Fecha de agua no valida",
            };
          }
        }
        if (loggedAt.getTime() > Date.now() + 5 * 60 * 1000) {
          return {
            content: JSON.stringify({ ok: false, error: "No se puede registrar agua en el futuro" }),
            summary: "Fecha de agua futura rechazada",
          };
        }

        const rawEventId = typeof toolCallId === "string" && toolCallId.length > 0
          ? toolCallId
          : crypto.randomUUID();
        const clientEventId = `agent:${rawEventId}`.slice(0, 128);
        const { error } = await supabase
          .from("water_logs")
          .upsert({
            user_id: userId,
            amount_ml: amountMl,
            logged_at: loggedAt.toISOString(),
            source: "agent",
            client_event_id: clientEventId,
          }, {
            onConflict: "user_id,client_event_id",
            ignoreDuplicates: true,
          });
        if (error) {
          return {
            content: JSON.stringify({ ok: false, error: error.message }),
            summary: "Error registrando agua",
          };
        }

        const summary = await fetchWaterSummary(supabase, userId, profile);
        return {
          content: JSON.stringify({
            ok: true,
            registered_ml: amountMl,
            logged_at: loggedAt.toISOString(),
            ...summary,
          }),
          summary: `${amountMl} ml registrados; hoy lleva ${summary.consumed_ml} ml`,
        };
      }
      case "get_active_meal_plan": {
        const requestedDay = resolvePlanDay(args?.day);
        if (args?.day !== undefined && !requestedDay) {
          return {
            content: JSON.stringify({
              ok: false,
              error: "Dia no valido",
              allowed_days: ["hoy", ...PLAN_DAYS],
            }),
            summary: "Dia no valido al consultar el plan activo",
          };
        }

        const { data, error } = await supabase
          .from("meal_plans")
          .select("id, week_start, plan, generated_by, status, notes, created_at, updated_at")
          .eq("user_id", userId)
          .eq("status", "active")
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        if (error) {
          return {
            content: JSON.stringify({ ok: false, error: error.message }),
            summary: "Error leyendo el plan activo",
          };
        }
        if (!data) {
          return {
            content: JSON.stringify({ ok: true, active_plan: null }),
            summary: "No hay ningun plan activo",
          };
        }

        const plan = data.plan && typeof data.plan === "object" && !Array.isArray(data.plan)
          ? data.plan
          : {};
        const days = Array.isArray(plan.days) ? plan.days : [];
        const availableDays = days
          .map((day: any) => typeof day?.day === "string" ? day.day : null)
          .filter((day: string | null): day is string => day !== null);

        if (requestedDay) {
          const selectedDay = days.find((day: any) =>
            normalizePlanDay(day?.day) === requestedDay
          ) ?? null;
          return {
            content: JSON.stringify({
              ok: true,
              active_plan: {
                id: data.id,
                week_start: data.week_start,
                status: data.status,
                generated_by: data.generated_by,
                notes: data.notes,
                created_at: data.created_at,
                updated_at: data.updated_at,
                type: plan.type ?? null,
                title: plan.title ?? null,
                summary: plan.summary ?? null,
                target_kcal: plan.target_kcal ?? null,
                target_protein_g: plan.target_protein_g ?? null,
                target_carbs_g: plan.target_carbs_g ?? null,
                target_fat_g: plan.target_fat_g ?? null,
              },
              requested_day: requestedDay,
              day: selectedDay,
              available_days: availableDays,
            }),
            summary: selectedDay
              ? `Plan activo consultado: ${requestedDay}`
              : `El plan activo no contiene ${requestedDay}`,
          };
        }

        return {
          content: JSON.stringify({
            ok: true,
            active_plan: {
              ...plan,
              id: data.id,
              week_start: data.week_start,
              status: data.status,
              generated_by: data.generated_by,
              notes: data.notes,
              created_at: data.created_at,
              updated_at: data.updated_at,
            },
            available_days: availableDays,
          }),
          summary: `Plan activo consultado: ${plan.title ?? "sin titulo"}`,
        };
      }
      case "get_health_metrics": {
        const today = new Date();
        const weekAgo = new Date(today.getTime() - 7 * 24 * 60 * 60 * 1000);
        const { data, error } = await supabase
          .from("health_metrics")
          .select("type, value, unit, recorded_at")
          .eq("user_id", userId)
          .gte("recorded_at", weekAgo.toISOString())
          .order("recorded_at", { ascending: false });
        if (error) {
          return { content: `Error: ${error.message}`, summary: "Error leyendo health_metrics" };
        }
        return {
          content: JSON.stringify({ metrics: data ?? [], count: data?.length ?? 0 }),
          summary: `${data?.length ?? 0} metricas de los ultimos 7 dias`
        };
      }
      case "calculate_daily_target": {
        // Mifflin-St Jeor para calcular TMB (Tasa Metabolica Basal)
        const { weight_kg, height_cm, age, sex, activity_level, goal } = args;
        if (!weight_kg || !height_cm || !age || !sex || !activity_level || !goal) {
          return { content: "Error: faltan parametros", summary: "Error en calculate_daily_target" };
        }
        let bmr: number;
        if (sex === "male") {
          bmr = 10 * weight_kg + 6.25 * height_cm - 5 * age + 5;
        } else {
          bmr = 10 * weight_kg + 6.25 * height_cm - 5 * age - 161;
        }
        const activityMultipliers: Record<string, number> = {
          sedentary: 1.2,
          lightly_active: 1.375,
          moderately_active: 1.55,
          very_active: 1.725,
          extremely_active: 1.9,
        };
        const tdee = bmr * (activityMultipliers[activity_level] ?? 1.55);
        let dailyKcal: number;
        let proteinPct: number, carbsPct: number, fatPct: number;
        switch (goal) {
          case "lose_weight":
            dailyKcal = Math.round(tdee - 500);
            proteinPct = 0.40; carbsPct = 0.35; fatPct = 0.25;
            break;
          case "gain_muscle":
            dailyKcal = Math.round(tdee + 300);
            proteinPct = 0.30; carbsPct = 0.45; fatPct = 0.25;
            break;
          case "recomposition":
            dailyKcal = Math.round(tdee);
            proteinPct = 0.35; carbsPct = 0.40; fatPct = 0.25;
            break;
          case "performance":
            dailyKcal = Math.round(tdee + 200);
            proteinPct = 0.25; carbsPct = 0.50; fatPct = 0.25;
            break;
          case "health":
          case "maintain":
          default:
            dailyKcal = Math.round(tdee);
            proteinPct = 0.30; carbsPct = 0.40; fatPct = 0.30;
            break;
        }
        const proteinG = Math.round((dailyKcal * proteinPct) / 4);
        const carbsG = Math.round((dailyKcal * carbsPct) / 4);
        const fatG = Math.round((dailyKcal * fatPct) / 9);

        const { error: updateError } = await supabase
          .from("profiles")
          .update({
            daily_kcal_target: dailyKcal,
            daily_protein_g: proteinG,
            daily_carbs_g: carbsG,
            daily_fat_g: fatG,
            weight_kg,
            height_cm,
            goal,
            activity_level,
            updated_at: new Date().toISOString(),
          })
          .eq("id", userId);
        if (updateError) {
          console.error("calculate_daily_target update error:", updateError);
        }
        return {
          content: JSON.stringify({
            ok: true,
            bmr: Math.round(bmr),
            tdee: Math.round(tdee),
            daily_kcal_target: dailyKcal,
            daily_protein_g: proteinG,
            daily_carbs_g: carbsG,
            daily_fat_g: fatG,
            macros_split: { protein: `${proteinPct * 100}%`, carbs: `${carbsPct * 100}%`, fat: `${fatPct * 100}%` },
            saved_to_profile: !updateError,
          }),
          summary: `Objetivo calculado: ${dailyKcal} kcal (${proteinG}P/${carbsG}C/${fatG}G)`
        };
      }
      case "generate_meal_plan": {
        const { type, notes } = args;
        if (!type || (type !== "weekly" && type !== "daily")) {
          return { content: "Error: type debe ser 'weekly' o 'daily'", summary: "Error en generate_meal_plan" };
        }
        if (notes !== undefined && typeof notes !== "string") {
          return { content: "Error: notes debe ser texto", summary: "Error en generate_meal_plan" };
        }
        const safeNotes = typeof notes === "string" ? notes.trim().slice(0, 2_000) : undefined;
        const weekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
        const { data: recentMeals, error: recentMealsError } = await supabase
          .from("meals")
          .select("name, meal_type, total_kcal, total_protein_g, total_carbs_g, total_fat_g")
          .eq("user_id", userId)
          .gte("logged_at", weekAgo)
          .order("logged_at", { ascending: false })
          .limit(10);
        if (recentMealsError) {
          throw new Error(`No se pudieron cargar las comidas recientes: ${recentMealsError.message}`);
        }

        const generated = await generateDetailedMealPlan({
          apiKey: GEMINI_API_KEY,
          baseUrl: GEMINI_BASE_URL,
          primaryModel: GEMINI_MODEL,
          fallbackModel: GEMINI_FALLBACK_MODEL,
          profile,
          facts,
          recentMeals: recentMeals ?? [],
          type,
          notes: safeNotes,
        });
        if (!generated.plan) {
          return {
            content: `No se pudo generar el plan detallado: ${generated.errors.join("; ")}`,
            summary: "Plan incompleto; no se ha guardado",
          };
        }
        const planData = generated.plan;

        // Guardar en meal_plans con status=draft
        const today = new Date();
        const weekStart = today.toISOString().split("T")[0];
        const { data: insertedPlan, error: insertError } = await supabase
          .from("meal_plans")
          .insert({
            user_id: userId,
            week_start: weekStart,
            plan: planData,
            generated_by: "agent",
            status: "draft",
            notes: safeNotes ?? null,
          })
          .select()
          .single();

        if (insertError) {
          return { content: `Error guardando plan: ${insertError.message}`, summary: "Error guardando plan" };
        }

        const dayCount = planData.days.length;
        const mealCount = planData.days.reduce((sum: number, d: any) => sum + (d.meals?.length ?? 0), 0);
        return {
          content: JSON.stringify({
            ok: true,
            plan_id: insertedPlan?.id,
            title: planData.title,
            day_count: dayCount,
            meal_count: mealCount,
            includes_detailed_recipes: true,
          }),
          summary: `Plan ${type === "weekly" ? "semanal" : "diario"} generado: ${dayCount} días, ${mealCount} comidas`
        };
      }
      default:
        return { content: `Tool '${name}' no reconocida`, summary: `Tool desconocida: ${name}` };
    }
  } catch (err) {
    return { content: `Error ejecutando ${name}: ${String(err)}`, summary: `Error en ${name}` };
  }
}

function buildSystemPrompt(profile: any, facts: any[]): string {
  const factsText = facts.length
    ? `\n\nHECHOS RECORDADOS DEL USUARIO (memoria persistente):\n${facts.map((f) => `- [${f.category}] ${f.fact}`).join("\n")}\n\nSi detectas informacion nueva importante (alergias, preferencias, objetivos), llama a la herramienta remember_fact para guardarla en memoria. Antes de inventar informacion, CONSULTA tu memoria con get_user_profile.`
    : `\n\n(El usuario aun no tiene hechos guardados. Si detectas informacion importante sobre el (alergias, preferencias, objetivos), llama a remember_fact para guardarla.)`;

  const profileText = profile
    ? `\n\nPERFIL DEL USUARIO:\n- Nombre: ${profile.full_name ?? "no indicado"}\n- Objetivo: ${profile.goal ?? "no indicado"}\n- Peso: ${profile.weight_kg ?? "?"} kg, Altura: ${profile.height_cm ?? "?"} cm` +
      (profile.daily_kcal_target ? `\n- Objetivo diario: ${profile.daily_kcal_target} kcal (${profile.daily_protein_g ?? "?"}P / ${profile.daily_carbs_g ?? "?"}C / ${profile.daily_fat_g ?? "?"}G)` : "") +
      `\n- Objetivo de agua: ${profile.daily_water_target_ml ?? 2000} ml`
    : "";

  // Fecha y hora exacta para que el agente sepa en que momento esta respondiendo
  const ahora = new Date();
  const timeZone = resolveTimeZone(profile?.timezone);
  const fechaHora = ahora.toLocaleString("es-ES", { timeZone, weekday: "long", year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", timeZoneName: "short" });
  const diaSemana = ahora.toLocaleDateString("es-ES", { timeZone, weekday: "long" });
  const fechaISO = ahora.toISOString();

  return `Eres NutriCoach, un dietista-nutricionista español con 15 años de experiencia, especializado en nutrición clínica y deportiva. Hablas en español de España, en tono cercano y directo, basado en evidencia. No sustituyes a un médico.

CONTEXTO TEMPORAL:
- Fecha y hora actual: ${fechaHora}
- Día de la semana: ${diaSemana}
- Fecha ISO: ${fechaISO}
- Zona horaria del usuario: ${timeZone}
Usa esta información para contextualizar tus respuestas (ej: "¿qué has comido hoy?", "¿cómo te fue anoche durmiendo?").

TUS REGLAS:
1. SIEMPRE contrasta la petición del usuario con su perfil antes de responder.
2. Si no cocinas o vives con familia, adapta los menús a esa realidad.
3. Antes de inventar información nutricional, di que necesitas verificarla.
4. Si una recomendación médica podría ser peligrosa, sugiere consultar al médico.
5. USA LAS HERRAMIENTAS (tools) en lugar de inventar datos:
   - get_user_profile: para recordar el perfil completo
   - get_recent_meals: para ver qué ha comido esta semana
   - get_water_summary: para ver cuanta agua lleva hoy y cuanto le falta
   - log_water: para registrar agua que el usuario afirma haber bebido
   - get_active_meal_plan: para leer el plan o rutina alimentaria activa, completo o por dia
   - get_health_metrics: para ver peso, pasos, FC, etc. de la última semana
   - remember_fact: para guardar info importante que el usuario te cuente (alergia, preferencia, objetivo)
   - web_search: para buscar info nutricional actualizada
   - calculate_daily_target: para calcular kcal/macros diarias recomendadas según peso, altura, edad, sexo, actividad y objetivo
6. ANTES de pedir datos al usuario, CONSULTA las herramientas. Solo pregunta si no puedes obtener la info.
7. Si el usuario no tiene objetivo diario configurado, pregúntale sus datos (peso, altura, edad, sexo, nivel de actividad, objetivo) y usa calculate_daily_target para calcularlo.
8. Si pregunta por su plan, rutina, menu activo o que debe comer un dia, llama SIEMPRE a get_active_meal_plan antes de responder. No afirmes que no puedes ver el plan sin consultar esta herramienta.
9. Si pregunta por su hidratacion de hoy, llama SIEMPRE a get_water_summary. Si afirma claramente que ha bebido agua o pide registrarla, llama a log_water. Un "vaso" sin tamano indicado equivale a 250 ml. No registres recomendaciones ni intenciones futuras como si ya hubieran ocurrido.

FORMATO DE MACROS PARA COMIDAS:
Cuando el usuario te describa una comida o envíe una foto, tu respuesta DEBE empezar con un bloque JSON válido con este formato EXACTO:

{"description": "nombre de la comida", "meal_type": "breakfast|lunch|dinner|snack|other", "kcal": 450, "protein_g": 25, "carbs_g": 55, "fat_g": 15, "confidence": 0.8, "ingredients": [{"name": "huevo", "quantity": 2, "unit": "unidades"}, {"name": "pan integral", "quantity": 50, "unit": "gramos"}]}

Reglas del JSON:
- description: nombre claro de la comida (ej: "Tortilla francesa de 2 huevos con pan")
- meal_type: uno de "breakfast", "lunch", "dinner", "snack", "other"
- kcal: calorías totales estimadas (numero)
- protein_g: gramos de proteína (numero, NO 0 ni null)
- carbs_g: gramos de carbohidratos (numero, NO 0 ni null)
- fat_g: gramos de grasa (numero, NO 0 ni null)
- confidence: 0-1, tu confianza en la estimación (0.5 si es una foto ambigua, 0.9 si es claramente identificable)
- ingredients: lista de ingredientes con nombre, cantidad y unidad. Si estimation es por foto, estima las cantidades.

COMO ESTIMAR MACROS:
- Usa tu conocimiento de densidad calórica: proteína 4 kcal/g, carbs 4 kcal/g, grasa 9 kcal/g.
- Para huevos: 1 huevo mediano ~70 kcal, 6g proteína, 0.6g carbs, 5g grasa.
- Para pan: ~250 kcal/100g, 9g proteína/100g, 45g carbs/100g, 3g grasa/100g.
- Para arroz cocido: ~130 kcal/100g, 2.7g proteína, 28g carbs, 0.3g grasa.
- Para pollo cocido: ~165 kcal/100g, 31g proteína, 0g carbs, 3.6g grasa.
- Si no estás seguro de un ingrediente, estima conservadoramente y pon confidence mas baja.
- NUNCA dejes protein_g, carbs_g o fat_g en 0 si la comida tiene macros. Si no los conoces, estima.

Tras el JSON, escribe tu comentario en español explicando la comida, los ingredientes detectados y cualquier sugerencia.

Responde de forma clara, concisa y útil.${profileText}${factsText}`;
}

function getAgentTools() {
  return [
    {
      type: "function",
      function: {
        name: "get_user_profile",
        description: "Obtiene el perfil completo del usuario y sus hechos guardados en memoria.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "get_recent_meals",
        description: "Obtiene las comidas registradas en los ultimos 7 dias con sus macros.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "get_water_summary",
        description: "Obtiene el agua registrada hoy, el objetivo diario y la cantidad restante segun la zona horaria del usuario.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "log_water",
        description: "Registra agua que el usuario confirma haber bebido. Si dice 'un vaso' sin indicar tamano, usar 250 ml. No usar para recomendaciones o planes futuros.",
        parameters: {
          type: "object",
          properties: {
            amount_ml: {
              type: "integer",
              minimum: 1,
              maximum: 5000,
              description: "Cantidad de agua bebida en mililitros.",
            },
            logged_at: {
              type: "string",
              description: "Fecha y hora ISO 8601. Omitir para registrar ahora.",
            },
          },
          required: ["amount_ml"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "get_active_meal_plan",
        description: "Lee el plan o rutina alimentaria que el usuario tiene activa en la aplicacion. Usar siempre que pregunte por su plan, rutina, menu activo o que debe comer hoy o cualquier dia. Puede devolver toda la semana o solo un dia.",
        parameters: {
          type: "object",
          properties: {
            day: {
              type: "string",
              enum: ["hoy", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"],
              description: "Dia que se quiere consultar. Omitir para obtener el plan completo.",
            },
          },
          required: [],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "get_health_metrics",
        description: "Obtiene las metricas de salud (peso, pasos, FC, etc.) de los ultimos 7 dias.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "remember_fact",
        description: "Guarda un hecho importante sobre el usuario en memoria persistente. Usar para alergias, preferencias, objetivos, contexto familiar, etc.",
        parameters: {
          type: "object",
          properties: {
            category: {
              type: "string",
              enum: ["preference", "intolerance", "allergy", "goal", "context", "medical", "family", "habit", "feedback", "observation"],
              description: "Categoria del hecho"
            },
            fact: { type: "string", description: "El hecho a recordar (frase completa y clara)" },
            confidence: { type: "number", minimum: 0, maximum: 1, description: "Confianza (0-1)" },
          },
          required: ["category", "fact"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "web_search",
        description: "Busca informacion en internet (alergenos, info nutricional actualizada, etc).",
        parameters: {
          type: "object",
          properties: { query: { type: "string", description: "Consulta de busqueda" } },
          required: ["query"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "calculate_daily_target",
        description: "Calcula las kcal diarias recomendadas y el reparto de macros (proteina, carbs, grasa) segun los datos del usuario. Usa Mifflin-St Jeor. Guarda el resultado en el perfil del usuario automaticamente.",
        parameters: {
          type: "object",
          properties: {
            weight_kg: { type: "number", description: "Peso en kg" },
            height_cm: { type: "number", description: "Altura en cm" },
            age: { type: "number", description: "Edad en anos" },
            sex: { type: "string", enum: ["male", "female"], description: "Sexo biologico" },
            activity_level: { type: "string", enum: ["sedentary", "lightly_active", "moderately_active", "very_active", "extremely_active"], description: "Nivel de actividad" },
            goal: { type: "string", enum: ["lose_weight", "maintain", "gain_muscle", "recomposition", "health", "performance"], description: "Objetivo" },
          },
          required: ["weight_kg", "height_cm", "age", "sex", "activity_level", "goal"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "generate_meal_plan",
        description: "Genera un plan de comida personalizado (semanal o diario) basado en el perfil, preferencias y restricciones del usuario. Lo guarda en la base de datos. Usar cuando el usuario pida un plan de comida, menu semanal o sugerencia de comidas.",
        parameters: {
          type: "object",
          properties: {
            type: { type: "string", enum: ["weekly", "daily"], description: "Tipo de plan: semanal (7 dias) o diario (1 dia)" },
            notes: { type: "string", maxLength: 2000, description: "Notas o preferencias adicionales del usuario para el plan (opcional)" },
          },
          required: ["type"],
        },
      },
    },
  ];
}

const PLAN_DAYS = [
  "lunes",
  "martes",
  "miercoles",
  "jueves",
  "viernes",
  "sabado",
  "domingo",
];

function resolvePlanDay(value: unknown): string | null {
  const normalized = normalizePlanDay(value);
  if (normalized !== "hoy") return normalized;

  const currentDay = new Intl.DateTimeFormat("es-ES", {
    timeZone: "Europe/Madrid",
    weekday: "long",
  }).format(new Date());
  return normalizePlanDay(currentDay);
}

function normalizePlanDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value
    .trim()
    .toLocaleLowerCase("es-ES")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
  if (normalized === "hoy" || PLAN_DAYS.includes(normalized)) return normalized;
  return null;
}

async function fetchWaterSummary(
  supabase: any,
  userId: string,
  profile: any,
) {
  const timeZone = resolveTimeZone(profile?.timezone);
  const bounds = getTodayBounds(timeZone);
  const { data, error } = await supabase
    .from("water_logs")
    .select("amount_ml, logged_at, source")
    .eq("user_id", userId)
    .gte("logged_at", bounds.start.toISOString())
    .lt("logged_at", bounds.end.toISOString())
    .order("logged_at", { ascending: true });
  if (error) {
    throw new Error(`No se pudo consultar el agua: ${error.message}`);
  }

  const logs = data ?? [];
  const consumedMl = logs.reduce(
    (total: number, log: any) => total + Number(log.amount_ml ?? 0),
    0,
  );
  const configuredTarget = Number(profile?.daily_water_target_ml);
  const targetMl = Number.isFinite(configuredTarget) && configuredTarget > 0
    ? configuredTarget
    : 2000;

  return {
    date: bounds.localDate,
    timezone: timeZone,
    consumed_ml: consumedMl,
    target_ml: targetMl,
    remaining_ml: Math.max(targetMl - consumedMl, 0),
    progress_pct: Math.round((consumedMl / targetMl) * 100),
    logs,
  };
}

function resolveTimeZone(value: unknown): string {
  const candidate = typeof value === "string" && value.trim()
    ? value.trim()
    : "Europe/Madrid";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: candidate }).format(new Date());
    return candidate;
  } catch {
    return "Europe/Madrid";
  }
}

function getTodayBounds(timeZone: string, now = new Date()) {
  const current = zonedDateParts(now, timeZone);
  const nextDay = new Date(Date.UTC(current.year, current.month - 1, current.day + 1));
  const next = {
    year: nextDay.getUTCFullYear(),
    month: nextDay.getUTCMonth() + 1,
    day: nextDay.getUTCDate(),
  };
  return {
    start: zonedMidnightToUtc(current.year, current.month, current.day, timeZone),
    end: zonedMidnightToUtc(next.year, next.month, next.day, timeZone),
    localDate: `${current.year}-${String(current.month).padStart(2, "0")}-${String(current.day).padStart(2, "0")}`,
  };
}

function zonedMidnightToUtc(
  year: number,
  month: number,
  day: number,
  timeZone: string,
): Date {
  const utcGuess = Date.UTC(year, month - 1, day);
  const firstOffset = timeZoneOffsetMs(new Date(utcGuess), timeZone);
  let result = new Date(utcGuess - firstOffset);
  const correctedOffset = timeZoneOffsetMs(result, timeZone);
  if (correctedOffset !== firstOffset) {
    result = new Date(utcGuess - correctedOffset);
  }
  return result;
}

function timeZoneOffsetMs(date: Date, timeZone: string): number {
  const parts = zonedDateParts(date, timeZone);
  const representedAsUtc = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
  );
  const roundedInput = Math.floor(date.getTime() / 1000) * 1000;
  return representedAsUtc - roundedInput;
}

function zonedDateParts(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const values = Object.fromEntries(
    parts
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)]),
  );
  return {
    year: values.year,
    month: values.month,
    day: values.day,
    hour: values.hour,
    minute: values.minute,
    second: values.second,
  };
}
