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

    // 4. Cargar perfil, hechos relevantes y memoria RAG
    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMessages = await loadRecentMessages(supabaseAdmin, body.conversation_id, 20);

    // 5. Construir system prompt (cargado desde BD o desde archivo)
    const systemPrompt = buildSystemPrompt(profile, facts);

    // 6. Cliente MiniMax (Anthropic-compatible)
    const anthropic = new Anthropic({
      apiKey: MINIMAX_API_KEY,
      baseURL: MINIMAX_BASE_URL,
    });

    // 7. Guardar mensaje del usuario
    await saveUserMessage(supabaseAdmin, body.conversation_id, body.message, body.attachments);

    // 8. Construir mensajes para la API
    const apiMessages = recentMessages.map((m: any) => ({
      role: m.role,
      content: m.content,
    }));
    apiMessages.push({
      role: "user" as const,
      content: body.message,
    });

    // 9. Herramientas disponibles (stubs - se completan en siguientes fases)
    const tools = getAgentTools();

    // 10. Loop del agente con tool use (fase 1: solo texto)
    // Streaming con Server-Sent Events
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

          for await (const event of messageStream) {
            if (event.type === "content_block_start") {
              controller.enqueue(encoder.encode(sseEvent("block_start", event)));
            } else if (event.type === "content_block_delta") {
              if (event.delta.type === "thinking_delta") {
                fullThinking += event.delta.thinking;
                controller.enqueue(encoder.encode(sseEvent("thinking", { text: event.delta.thinking })));
              } else if (event.delta.type === "text_delta") {
                fullText += event.delta.text;
                controller.enqueue(encoder.encode(sseEvent("text", { text: event.delta.text })));
              }
            } else if (event.type === "content_block_stop") {
              controller.enqueue(encoder.encode(sseEvent("block_stop", {})));
            } else if (event.type === "message_stop") {
              controller.enqueue(encoder.encode(sseEvent("done", {})));
            }
          }

          // 11. Guardar respuesta completa
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

function buildSystemPrompt(profile: any, facts: any[]): string {
  // En fase 1, un system prompt mínimo. Se enriquecerá en fases siguientes
  // cargando desde BD o archivo en /workspace/prompts/agent.md
  const factsText = facts.length
    ? `\n\nHECHOS RECORDADOS DEL USUARIO:\n${facts.map((f) => `- [${f.category}] ${f.fact}`).join("\n")}`
    : "";

  const profileText = profile
    ? `\n\nPERFIL:\n- Nombre: ${profile.full_name ?? "no indicado"}\n- Objetivo: ${profile.goal ?? "no indicado"}\n- Peso: ${profile.weight_kg ?? "?"} kg, Altura: ${profile.height_cm ?? "?"} cm\n- Contexto del hogar: ${profile.household_context ?? "no indicado"}`
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

Responde de forma clara, concisa y útil.${profileText}${factsText}`;
}

function getAgentTools() {
  // Stubs en fase 1. En fases siguientes se completan todos los tools
  // definidos en docs/TOOLS.md.
  return [
    {
      name: "get_user_profile",
      description: "Obtiene el perfil completo del usuario.",
      input_schema: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "web_search",
      description: "Busca información en internet (alérgenos, info nutricional, etc).",
      input_schema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Consulta de búsqueda" },
        },
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
