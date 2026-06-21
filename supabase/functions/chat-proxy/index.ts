// ============================================================
// chat-proxy - Edge Function de Supabase
// Proxy seguro al agente MiniMax-M3 con loop agentico (tool use).
// Streaming SSE hacia el cliente iOS.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const MINIMAX_API_KEY = Deno.env.get("MINIMAX_API_KEY")!;
const MINIMAX_BASE_URL = Deno.env.get("MINIMAX_BASE_URL") ?? "https://api.minimax.io/v1";
const MINIMAX_MODEL = Deno.env.get("MINIMAX_MODEL") ?? "MiniMax-M3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_AGENT_ITERATIONS = 6;

interface ChatRequest {
  conversation_id: string;
  message: string;
  attachments?: Array<{ type: "image" | "video"; url: string }>;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
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
    const body: ChatRequest = await req.json();
    if (!body.conversation_id || !body.message) {
      return jsonError(400, "Missing conversation_id or message");
    }

    // 3. Cliente con service_role (bypasea RLS) para el agente
    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 4. Cargar perfil, hechos relevantes y mensajes recientes
    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMessages = await loadRecentMessages(supabaseAdmin, body.conversation_id, 20);

    // 5. System prompt
    const systemPrompt = buildSystemPrompt(profile, facts);

    // 6. Guardar mensaje del usuario en BD
    await saveUserMessage(supabaseAdmin, body.conversation_id, body.message, body.attachments);

    // 7. Construir mensajes para la API (formato OpenAI multimodal).
    //    image_url acepta URL pública directamente (signed URL funciona).
    const userContent: any[] = [];
    const imageAttachments = (body.attachments ?? []).filter((a) => a.type === "image");
    for (const att of imageAttachments) {
      userContent.push({
        type: "image_url",
        image_url: { url: att.url },
      });
    }
    let displayMessage = body.message;
    if (imageAttachments.length > 0) {
      displayMessage = body.message +
        (body.message.trim() ? "" : "\n\n") +
        "\n\nAnaliza esta imagen de comida y devuelve las macros estimadas (kcal, proteínas, carbohidratos, grasas) en formato JSON al inicio de tu respuesta, seguido de un comentario en español.";
    }
    userContent.push({ type: "text", text: displayMessage });

    // 8. Mensajes base para la API. 'system' es un mensaje role: system.
    let apiMessages: any[] = [
      { role: "system", content: systemPrompt },
      ...recentMessages.map((m: any) => ({ role: m.role, content: m.content })),
      { role: "user", content: userContent },
    ];

    // 9. Tools (function calling formato OpenAI)
    const tools = getAgentTools();

    // 10. Loop agentico: M3 puede llamar tools, ejecutamos, volvemos a llamar
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        let fullText = "";
        let detectedMacros: any = null;
        let savedMealFlag = false;
        let assistantMessageSaved = false;

        try {
          for (let iteration = 0; iteration < MAX_AGENT_ITERATIONS; iteration++) {
            // Hacer request a M3 con streaming
            const upstreamResp = await fetch(`${MINIMAX_BASE_URL}/chat/completions`, {
              method: "POST",
              headers: {
                "Authorization": `Bearer ${MINIMAX_API_KEY}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                model: MINIMAX_MODEL,
                messages: apiMessages,
                tools,
                stream: true,
                max_completion_tokens: 16384,
                thinking: { type: "adaptive" },
                // IMPORTANTE: NO usamos reasoning_split. Emite TODO en delta.content
                // mezclando thinking con content. El parser en backend separa
                // los bloques <think>...</think> del content.
              }),
            });

            if (!upstreamResp.ok) {
              const errText = await upstreamResp.text();
              controller.enqueue(encoder.encode(sseEvent("error", { message: `M3 error ${upstreamResp.status}: ${errText}` })));
              return;
            }

            // Parsear el stream de M3
            const reader = upstreamResp.body!.getReader();
            const decoder = new TextDecoder();
            let buffer = "";
            // Buffer persistente para el parser de <think>...</think>
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

                  // 1. reasoning_content (algunos servers lo usan)
                  if (delta?.reasoning_content) {
                    iterThinking += delta.reasoning_content;
                    controller.enqueue(encoder.encode(sseEvent("thinking", { text: delta.reasoning_content })));
                  }

                  // 2. content: parsear streaming de <think>...</think>
                  //    M3 con thinking:adaptive emite TODO en delta.content
                  //    mezclando los tags <think>...</think> con la respuesta.
                  //    Necesitamos separar en streaming porque el cliente espera
                  //    eventos 'thinking' y 'text' por separado.
                  if (delta?.content) {
                    rawContent += delta.content;
                    // Aplicar regex para extraer bloque <think> cerrado
                    const thinkMatch = rawContent.match(/<think>([\s\S]*?)<\/think>/);
                    if (thinkMatch) {
                      // Hay un bloque <think> completo
                      const thinkStart = thinkMatch.index!;
                      const thinkEnd = thinkStart + thinkMatch[0].length;
                      // thinking text = lo que esta entre tags (sin doble emision)
                      const newThinking = thinkMatch[1];
                      if (newThinking.length > iterThinking.length) {
                        const thinkingDelta = newThinking.substring(iterThinking.length);
                        iterThinking = newThinking;
                        controller.enqueue(encoder.encode(sseEvent("thinking", { text: thinkingDelta })));
                      }
                      // text = lo que va despues de </think>
                      const textAfter = rawContent.substring(thinkEnd);
                      if (textAfter.length > emittedTextLen) {
                        const textDelta = textAfter.substring(emittedTextLen);
                        emittedTextLen = textAfter.length;
                        iterText = textAfter;
                        fullText = textAfter;
                        controller.enqueue(encoder.encode(sseEvent("text", { text: textDelta })));
                      }
                    } else if (!rawContent.includes("<think>")) {
                      // No hay <think> y no se ha visto: emitir todo como text
                      if (rawContent.length > emittedTextLen) {
                        const textDelta = rawContent.substring(emittedTextLen);
                        emittedTextLen = rawContent.length;
                        iterText = rawContent;
                        fullText = rawContent;
                        controller.enqueue(encoder.encode(sseEvent("text", { text: textDelta })));
                      }
                    }
                    // Si <think> esta abierto (sin cierre), esperar al siguiente chunk
                  }

                  // 3. tool_calls (function calling)
                  if (delta?.tool_calls) {
                    for (const tc of delta.tool_calls) {
                      const idx = tc.index ?? toolCalls.length;
                      if (!toolCalls[idx]) {
                        toolCalls[idx] = {
                          id: tc.id,
                          type: "function",
                          function: { name: "", arguments: "" }
                        };
                      }
                      if (tc.id) toolCalls[idx].id = tc.id;
                      if (tc.function?.name) toolCalls[idx].function.name = tc.function.name;
                      if (tc.function?.arguments) toolCalls[idx].function.arguments += tc.function.arguments;
                    }
                  }
                } catch (e) {
                  // chunk malformado, ignorar
                }
              }
            }

            // Si no hay tool_calls, terminamos el loop
            if (toolCalls.length === 0 || finishReason !== "tool_calls") {
              if (!assistantMessageSaved && (fullText || iterThinking)) {
                await saveAssistantMessage(
                  supabaseAdmin,
                  body.conversation_id,
                  fullText || iterText,
                  iterThinking || null
                );
                assistantMessageSaved = true;
              }
              break;
            }

            // Hay tool_calls: ejecutar y volver a llamar a M3
            controller.enqueue(encoder.encode(sseEvent("tools_start", { count: toolCalls.length, names: toolCalls.map(t => t.function.name) })));

            // Anadir el assistant message con tool_calls al historial
            apiMessages.push({
              role: "assistant",
              content: iterText || null,
              tool_calls: toolCalls.map(tc => ({
                id: tc.id,
                type: "function",
                function: { name: tc.function.name, arguments: tc.function.arguments }
              }))
            });

            // Ejecutar cada tool
            for (const tc of toolCalls) {
              const name = tc.function.name;
              let args: any = {};
              try { args = JSON.parse(tc.function.arguments || "{}"); } catch (_) { args = {}; }
              const toolResult = await executeTool(name, args, supabaseAdmin, user.id, profile, facts);
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
    return jsonError(500, String(err));
  }
});

// ============================================================
// HELPERS
// ============================================================

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

async function loadRecentMessages(supabase: any, conversationId: string, limit: number) {
  const { data } = await supabase
    .from("messages")
    .select("role, content, thinking")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: false })
    .limit(limit);
  return (data ?? []).reverse();
}

async function saveUserMessage(
  supabase: any,
  conversationId: string,
  content: string,
  attachments?: any[]
) {
  await supabase.from("messages").insert({
    conversation_id: conversationId,
    role: "user",
    content,
    attachments: attachments ?? [],
  });
  await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}

async function saveAssistantMessage(
  supabase: any,
  conversationId: string,
  content: string,
  thinking?: string
) {
  await supabase.from("messages").insert({
    conversation_id: conversationId,
    role: "assistant",
    content: content || "",
    thinking: thinking || null,
  });
  await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}

async function saveMeal(supabase: any, userId: string, analysis: any) {
  const { error } = await supabase.from("meals").insert({
    user_id: userId,
    description: analysis.description ?? "Sin descripción",
    meal_type: analysis.meal_type ?? "other",
    kcal: analysis.kcal ?? null,
    protein_g: analysis.protein_g ?? null,
    carbs_g: analysis.carbs_g ?? null,
    fat_g: analysis.fat_g ?? null,
    confidence: analysis.confidence ?? null,
    source: "photo",
  });
  if (error) console.error("saveMeal error:", error);
}

// ============================================================
// AGENT TOOLS - ejecutados en el loop agentico
// ============================================================

interface ToolResult {
  content: string;       // Texto que se envia a M3 como tool_result
  summary: string;       // Resumen para emitir al cliente via SSE
}

async function executeTool(
  name: string,
  args: any,
  supabase: any,
  userId: string,
  profile: any,
  facts: any[]
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
          .select("description, kcal, protein_g, carbs_g, fat_g, consumed_at")
          .eq("user_id", userId)
          .gte("consumed_at", weekAgo.toISOString())
          .order("consumed_at", { ascending: false });
        if (error) {
          return { content: `Error: ${error.message}`, summary: "Error leyendo meals" };
        }
        return {
          content: JSON.stringify({ meals: data ?? [], count: data?.length ?? 0 }),
          summary: `${data?.length ?? 0} comidas de los ultimos 7 dias`
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
      (profile.daily_kcal_target ? `\n- Objetivo diario: ${profile.daily_kcal_target} kcal (${profile.daily_protein_g ?? "?"}P / ${profile.daily_carbs_g ?? "?"}C / ${profile.daily_fat_g ?? "?"}G)` : "")
    : "";

  return `Eres NutriCoach, un dietista-nutricionista español con 15 años de experiencia, especializado en nutrición clínica y deportiva. Hablas en español de España, en tono cercano y directo, basado en evidencia. No sustituyes a un médico.

TUS REGLAS:
1. SIEMPRE contrasta la petición del usuario con su perfil antes de responder.
2. Si no cocinas o vives con familia, adapta los menús a esa realidad.
3. Antes de inventar información nutricional, di que necesitas verificarla.
4. Si una recomendación médica podría ser peligrosa, sugiere consultar al médico.
5. USA LAS HERRAMIENTAS (tools) en lugar de inventar datos:
   - get_user_profile: para recordar el perfil completo
   - get_recent_meals: para ver qué ha comido esta semana
   - get_health_metrics: para ver peso, pasos, FC, etc. de la última semana
   - remember_fact: para guardar info importante que el usuario te cuente (alergia, preferencia, objetivo)
   - web_search: para buscar info nutricional actualizada
6. ANTES de pedir datos al usuario, CONSULTA las herramientas. Solo pregunta si no puedes obtener la info.
7. Cuando el usuario envíe una FOTO DE COMIDA, tu respuesta DEBE empezar con un bloque JSON válido con las macros estimadas, seguido de un comentario en español.

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
        description: "Obtiene las comidas registradas en los últimos 7 días con sus macros.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "get_health_metrics",
        description: "Obtiene las métricas de salud (peso, pasos, FC, etc.) de los últimos 7 días.",
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
        description: "Busca información en internet (alérgenos, info nutricional actualizada, etc).",
        parameters: {
          type: "object",
          properties: { query: { type: "string", description: "Consulta de búsqueda" } },
          required: ["query"],
        },
      },
    },
  ];
}