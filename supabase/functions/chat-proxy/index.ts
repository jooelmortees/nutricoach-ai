// ============================================================
// chat-proxy - Edge Function de Supabase
// Proxy seguro al agente MiniMax-M3 vía API OpenAI-compatible.
// M3 soporta multimodalidad (texto + imagen + video) con formato
// image_url. Streaming con SSE hacia el cliente iOS.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const MINIMAX_API_KEY = Deno.env.get("MINIMAX_API_KEY")!;
// Endpoint OpenAI-compatible de MiniMax. La doc oficial dice
// https://api.minimax.io/v1 (NO /anthropic) para vision.
const MINIMAX_BASE_URL = Deno.env.get("MINIMAX_BASE_URL") ?? "https://api.minimax.io/v1";
const MINIMAX_MODEL = Deno.env.get("MINIMAX_MODEL") ?? "MiniMax-M3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ChatRequest {
  conversation_id: string;
  message: string;
  attachments?: Array<{ type: "image" | "video"; url: string }>;
}

interface MacrosAnalysis {
  description: string;
  meal_type?: string;
  kcal?: number;
  protein_g?: number;
  carbs_g?: number;
  fat_g?: number;
  confidence?: number;
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

    // 5. System prompt (en OpenAI es un mensaje role: system)
    const systemPrompt = buildSystemPrompt(profile, facts);

    // 6. Guardar mensaje del usuario en BD (incluye attachments para mostrar luego)
    await saveUserMessage(supabaseAdmin, body.conversation_id, body.message, body.attachments);

    // 7. Construir content del mensaje del usuario (formato OpenAI multimodal).
    // image_url acepta URL pública directamente (signed URL de Supabase Storage funciona)
    // por lo que NO necesitamos descargar y convertir a base64.
    const userContent: any[] = [];
    const imageAttachments = (body.attachments ?? []).filter((a) => a.type === "image");
    for (const att of imageAttachments) {
      userContent.push({
        type: "image_url",
        image_url: { url: att.url },
      });
    }
    let displayMessage = body.message;
    // Si hay imagen y el usuario no dio instruccion especifica, anadimos hint
    if (imageAttachments.length > 0) {
      // Hint sutil para que el modelo sepa que debe analizar y dar macros
      // (sin sobreescribir la pregunta del usuario)
      displayMessage = body.message +
        (body.message.trim() ? "" : "\n\n") +
        "\n\nAnaliza esta imagen de comida y devuelve las macros estimadas (kcal, proteínas, carbohidratos, grasas) en formato JSON al inicio de tu respuesta, seguido de un comentario en español.";
    }
    userContent.push({ type: "text", text: displayMessage });

    // 8. Mensajes para la API (formato OpenAI Chat Completions)
    const apiMessages: any[] = [
      { role: "system", content: systemPrompt },
      ...recentMessages.map((m: any) => ({
        role: m.role,
        content: m.content,
      })),
      { role: "user", content: userContent },
    ];

    // 9. Tools (function calling - OpenAI format)
    const tools = getAgentTools();

    // 10. Llamada a MiniMax con streaming via fetch directo (controlamos
    //     exactamente el formato y el parseo SSE).
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
        thinking: { type: "adaptive" },  // M3 con thinking adaptativo
      }),
    });

    if (!upstreamResp.ok) {
      const errText = await upstreamResp.text();
      return jsonError(upstreamResp.status, `MiniMax upstream error: ${errText}`);
    }

    // 11. Stream SSE al cliente iOS, parseando el formato OpenAI
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        const reader = upstreamResp.body!.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        let fullText = "";
        let detectedMacros: MacrosAnalysis | null = null;

        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });

            // Procesar lineas SSE de OpenAI (formato data: {...})
            const lines = buffer.split("\n");
            buffer = lines.pop() ?? "";

            for (const line of lines) {
              const trimmed = line.trim();
              if (!trimmed || !trimmed.startsWith("data:")) continue;
              const payload = trimmed.slice(5).trim();
              if (payload === "[DONE]") {
                // Final del stream OpenAI. Emitir nuestro evento 'done'.
                if (detectedMacros) {
                  try {
                    await saveMeal(supabaseAdmin, user.id, detectedMacros);
                    controller.enqueue(encoder.encode(sseEvent("meal_saved", detectedMacros)));
                  } catch (e) {
                    console.error("saveMeal error:", e);
                  }
                }
                controller.enqueue(encoder.encode(sseEvent("done", {})));
                continue;
              }
              try {
                const chunk = JSON.parse(payload);
                const delta = chunk.choices?.[0]?.delta;
                if (!delta) continue;
                // OpenAI M3 incluye reasoning_content y content juntos en delta.content
                const text = delta.content ?? "";
                if (text) {
                  fullText += text;
                  // Emitir el delta al cliente iOS (que ahora no distingue thinking/text,
                  // sino que lo muestra todo como texto; si queremos separar,
                  // podemos parsear el <think>...</think> del texto completo).
                  controller.enqueue(encoder.encode(sseEvent("text", { text })));
                  // Intentar parsear macros JSON si hay imagen adjunta
                  if (imageAttachments.length > 0 && !detectedMacros) {
                    const jsonMatch = extractJson(fullText);
                    if (jsonMatch) {
                      try {
                        const parsed = JSON.parse(jsonMatch);
                        if (parsed.kcal !== undefined || parsed.protein_g !== undefined || parsed.description) {
                          detectedMacros = parsed as MacrosAnalysis;
                        }
                      } catch (_e) { /* no es JSON válido todavía */ }
                    }
                  }
                }
                // Si hay tool_calls en el delta
                if (delta.tool_calls) {
                  controller.enqueue(encoder.encode(sseEvent("tool_calls", delta.tool_calls)));
                }
              } catch (e) {
                // JSON malformado en chunk, ignorar
              }
            }
          }
          // Guardar respuesta completa del asistente
          await saveAssistantMessage(supabaseAdmin, body.conversation_id, fullText);
        } catch (err) {
          controller.enqueue(encoder.encode(sseEvent("error", { message: String(err) })));
        } finally {
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
  content: string
) {
  await supabase.from("messages").insert({
    conversation_id: conversationId,
    role: "assistant",
    content,
  });
  await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}

async function saveMeal(supabase: any, userId: string, analysis: MacrosAnalysis) {
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
  if (error) {
    console.error("saveMeal error:", error);
    throw error;
  }
}

function buildSystemPrompt(profile: any, facts: any[]): string {
  const factsText = facts.length
    ? `\n\nHECHOS RECORDADOS DEL USUARIO:\n${facts.map((f) => `- [${f.category}] ${f.fact}`).join("\n")}`
    : "";

  const profileText = profile
    ? `\n\nPERFIL:\n- Nombre: ${profile.full_name ?? "no indicado"}\n- Objetivo: ${profile.goal ?? "no indicado"}\n- Peso: ${profile.weight_kg ?? "?"} kg, Altura: ${profile.height_cm ?? "?"} cm` +
      (profile.daily_kcal_target ? `\n- Objetivo diario: ${profile.daily_kcal_target} kcal` : "")
    : "";

  return `Eres NutriCoach, un dietista-nutricionista español con 15 años de experiencia, especializado en nutrición clínica y deportiva. Hablas en español de España, en tono cercano y directo, basado en evidencia. No sustituyes a un médico.

TUS REGLAS:
1. SIEMPRE contrasta la petición del usuario con su perfil antes de responder.
2. Si no cocinas o vives con familia, adapta los menús a esa realidad.
3. Antes de inventar información nutricional, di que necesitas verificarla.
4. Si una recomendación médica podría ser peligrosa, sugiere consultar al médico.
5. Usa las herramientas disponibles (tools) en lugar de inventar datos.
6. Recuerda hechos importantes del usuario con la herramienta remember_fact.
7. Antes de responder, busca en tu memoria (recall_facts) si hay info relevante.

Cuando el usuario envíe una FOTO DE COMIDA, tu respuesta DEBE empezar con un bloque JSON válido con las macros estimadas (lo extrae automáticamente el sistema). Tras el JSON, puedes añadir texto explicativo para el usuario.

Responde de forma clara, concisa y útil.${profileText}${factsText}`;
}

function getAgentTools() {
  return [
    {
      type: "function",
      function: {
        name: "get_user_profile",
        description: "Obtiene el perfil completo del usuario.",
        parameters: { type: "object", properties: {}, required: [] },
      },
    },
    {
      type: "function",
      function: {
        name: "web_search",
        description: "Busca información en internet (alérgenos, info nutricional, etc).",
        parameters: {
          type: "object",
          properties: { query: { type: "string", description: "Consulta de búsqueda" } },
          required: ["query"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "remember_fact",
        description: "Guarda un hecho importante sobre el usuario para futuras conversaciones.",
        parameters: {
          type: "object",
          properties: {
            category: {
              type: "string",
              enum: ["preference", "intolerance", "allergy", "goal", "context", "medical", "family", "habit", "feedback", "observation"],
            },
            fact: { type: "string" },
            confidence: { type: "number", minimum: 0, maximum: 1 },
          },
          required: ["category", "fact"],
        },
      },
    },
  ];
}