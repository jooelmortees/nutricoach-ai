// ============================================================
// chat-proxy - Edge Function de Supabase
// Proxy seguro al agente MiniMax-M3. Ejecuta el loop de tools.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MINIMAX_API_KEY = Deno.env.get("MINIMAX_API_KEY")!;
const MINIMAX_BASE_URL = Deno.env.get("MINIMAX_BASE_URL") ?? "https://api.minimax.io/anthropic";
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

interface ImageAnalysis {
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
      Deno.env.get("SUPABASE_ANON_KEY")!,
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

    // 6. Cliente MiniMax
    const anthropic = new Anthropic({
      apiKey: MINIMAX_API_KEY,
      baseURL: MINIMAX_BASE_URL,
    });

    // 7. Guardar mensaje del usuario
    await saveUserMessage(supabaseAdmin, body.conversation_id, body.message, body.attachments);

    // 8. Construir contenido del mensaje del usuario (puede incluir imagen)
    const imageAttachments = (body.attachments ?? []).filter((a) => a.type === "image");
    const userContentBlocks: any[] = [];

    // Si hay imagen, la descargamos y la pasamos a M3 como bloque image
    let analysisHint = "";
    if (imageAttachments.length > 0) {
      const firstUrl = imageAttachments[0].url;
      try {
        const imgResp = await fetch(firstUrl);
        if (imgResp.ok) {
          const contentType = imgResp.headers.get("content-type") ?? "image/jpeg";
          const buf = new Uint8Array(await imgResp.arrayBuffer());
          const b64 = btoa(String.fromCharCode(...buf));
          userContentBlocks.push({
            type: "image",
            source: { type: "base64", media_type: contentType, data: b64 },
          });
          analysisHint =
            "\n\n[El usuario ha enviado una FOTO DE COMIDA. Analízala y devuelve EXCLUSIVAMENTE un JSON válido con esta estructura exacta, sin texto adicional: " +
            '{"description": "<nombre del plato en español>", "meal_type": "breakfast|lunch|dinner|snack|other", ' +
            '"kcal": <número>, "protein_g": <número>, "carbs_g": <número>, "fat_g": <número>, "confidence": <0-1>}. ' +
            'Si no puedes identificar la comida, devuelve {"description": "Comida no identificada", "confidence": 0}.]';
        }
      } catch (e) {
        console.error("Error descargando imagen:", e);
      }
    }

    userContentBlocks.push({ type: "text", text: body.message + analysisHint });

    // 9. Mensajes para la API
    const apiMessages = recentMessages.map((m: any) => ({
      role: m.role,
      content: m.content,
    }));
    apiMessages.push({
      role: "user" as const,
      content: userContentBlocks,
    });

    // 10. Tools
    const tools = getAgentTools();

    // 11. Loop del agente con tool use
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        try {
          const messageStream = await anthropic.messages.create({
            model: MINIMAX_MODEL,
            max_tokens: 4096,
            system: systemPrompt,
            messages: apiMessages,
            tools,
            stream: true,
          });

          let fullText = "";
          let fullThinking = "";
          let detectedMacros: ImageAnalysis | null = null;

          for await (const event of messageStream) {
            if (event.type === "content_block_start") {
              controller.enqueue(encoder.encode(sseEvent("block_start", event)));
            } else if (event.type === "content_block_delta") {
              if (event.delta.type === "thinking_delta") {
                fullThinking += event.delta.thinking;
                controller.enqueue(encoder.encode(sseEvent("thinking", { text: event.delta.thinking })));
              } else if (event.delta.type === "text_delta") {
                const delta = event.delta.text;
                fullText += delta;
                controller.enqueue(encoder.encode(sseEvent("text", { text: delta })));

                // Si hay imagen adjunta, intentar parsear JSON de macros del texto
                if (imageAttachments.length > 0 && !detectedMacros) {
                  const jsonMatch = extractJson(fullText);
                  if (jsonMatch) {
                    try {
                      const parsed = JSON.parse(jsonMatch);
                      if (parsed.kcal !== undefined || parsed.protein_g !== undefined || parsed.description) {
                        detectedMacros = parsed as ImageAnalysis;
                      }
                    } catch (_e) { /* no es JSON válido todavía */ }
                  }
                }
              }
            } else if (event.type === "content_block_stop") {
              controller.enqueue(encoder.encode(sseEvent("block_stop", {})));
            } else if (event.type === "message_stop") {
              // Si detectamos macros de una foto, guardar en meals
              if (detectedMacros) {
                try {
                  await saveMeal(supabaseAdmin, user.id, detectedMacros);
                  controller.enqueue(encoder.encode(sseEvent("meal_saved", detectedMacros)));
                } catch (e) {
                  console.error("Error guardando meal:", e);
                }
              }
              controller.enqueue(encoder.encode(sseEvent("done", {})));
            }
          }

          // 12. Guardar respuesta completa
          await saveAssistantMessage(
            supabaseAdmin,
            body.conversation_id,
            fullText,
            fullThinking
          );
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

/** Extrae el primer bloque JSON válido de un texto. */
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
  thinking: string
) {
  await supabase.from("messages").insert({
    conversation_id: conversationId,
    role: "assistant",
    content,
    thinking,
  });
  await supabase
    .from("conversations")
    .update({ last_message_at: new Date().toISOString() })
    .eq("id", conversationId);
}

async function saveMeal(supabase: any, userId: string, analysis: ImageAnalysis) {
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
      (profile.kcal_target ? `\n- Objetivo diario: ${profile.kcal_target} kcal` : "")
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
      name: "get_user_profile",
      description: "Obtiene el perfil completo del usuario.",
      input_schema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "web_search",
      description: "Busca información en internet (alérgenos, info nutricional, etc).",
      input_schema: {
        type: "object",
        properties: { query: { type: "string", description: "Consulta de búsqueda" } },
        required: ["query"],
      },
    },
    {
      name: "remember_fact",
      description: "Guarda un hecho importante sobre el usuario para futuras conversaciones.",
      input_schema: {
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
  ];
}