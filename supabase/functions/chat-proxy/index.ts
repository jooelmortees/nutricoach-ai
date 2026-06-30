// ============================================================
// chat-proxy - Edge Function de Supabase
// Proxy seguro al agente Gemini 2.5 Flash con loop agentico (tool use).
// Streaming SSE hacia el cliente iOS.
// Soporta texto, imagenes y audio como input multimodal.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_AGENT_ITERATIONS = 6;

interface ChatRequest {
  conversation_id: string;
  message: string;
  attachments?: Array<{ type: "image" | "audio"; url: string; data?: string; mime_type?: string }>;
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

    // 7. Construir contents para Gemini (formato multimodal).
    //    Gemini usa "parts" con type text/inlineData.
    const userParts: any[] = [];
    const imageAttachments = (body.attachments ?? []).filter((a) => a.type === "image");
    const audioAttachments = (body.attachments ?? []).filter((a) => a.type === "audio");

    let displayMessage = body.message;
    if (imageAttachments.length > 0) {
      displayMessage = body.message +
        (body.message.trim() ? "" : "\n\n") +
        "\n\nAnaliza esta imagen de comida y devuelve las macros estimadas (kcal, proteinas, carbohidratos, grasas) en formato JSON al inicio de tu respuesta, seguido de un comentario en espanol.";
    } else if (audioAttachments.length > 0) {
      displayMessage = body.message +
        (body.message.trim() ? "" : "\n\n") +
        "\n\nEl usuario ha enviado un audio. Escuchalo y responde a lo que dice.";
    }

    // Imagenes: Gemini acepta URL via fileData o inlineData con base64.
    // Si viene URL publica, usamos fileData. Si viene data base64, inlineData.
    for (const att of imageAttachments) {
      if (att.data) {
        userParts.push({
          inlineData: { mimeType: att.mime_type ?? "image/jpeg", data: att.data }
        });
      } else if (att.url) {
        userParts.push({
          fileData: { mimeType: att.mime_type ?? "image/jpeg", fileUri: att.url }
        });
      }
    }

    // Audio: inlineData con base64
    for (const att of audioAttachments) {
      if (att.data) {
        userParts.push({
          inlineData: { mimeType: att.mime_type ?? "audio/mp3", data: att.data }
        });
      } else if (att.url) {
        userParts.push({
          fileData: { mimeType: att.mime_type ?? "audio/mp3", fileUri: att.url }
        });
      }
    }

    userParts.push({ text: displayMessage });

    // 8. Construir contents para la API (historial + mensaje actual)
    let apiContents: any[] = [
      ...recentMessages.map((m: any) => ({
        role: m.role === "assistant" ? "model" : "user",
        parts: [{ text: m.content ?? "" }]
      })),
      { role: "user", parts: userParts },
    ];

    // 9. Tools (function calling formato Gemini)
    const tools = getAgentTools();

    // 10. Loop agentico: Gemini puede llamar tools, ejecutamos, volvemos a llamar
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        let fullText = "";
        let detectedMacros: any = null;
        let savedMealFlag = false;
        let assistantMessageSaved = false;

        try {
          for (let iteration = 0; iteration < MAX_AGENT_ITERATIONS; iteration++) {
            // Hacer request a Gemini con streaming SSE
            const upstreamResp = await fetch(
              `${GEMINI_BASE_URL}/${GEMINI_MODEL}:streamGenerateContent?alt=sse`,
              {
                method: "POST",
                headers: {
                  "x-goog-api-key": GEMINI_API_KEY,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({
                  systemInstruction: { parts: [{ text: systemPrompt }] },
                  contents: apiContents,
                  tools,
                  generationConfig: {
                    maxOutputTokens: 16384,
                    temperature: 0.7,
                  },
                }),
              }
            );

            if (!upstreamResp.ok) {
              const errText = await upstreamResp.text();
              controller.enqueue(encoder.encode(sseEvent("error", { message: `Gemini error ${upstreamResp.status}: ${errText}` })));
              return;
            }

            // Parsear el stream SSE de Gemini
            const reader = upstreamResp.body!.getReader();
            const decoder = new TextDecoder();
            let buffer = "";
            let iterText = "";
            let functionCalls: any[] = [];

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
                  const candidate = chunk.candidates?.[0];
                  if (!candidate) continue;
                  const parts = candidate.content?.parts ?? [];

                  for (const part of parts) {
                    if (part.text) {
                      iterText += part.text;
                      fullText += part.text;
                      controller.enqueue(encoder.encode(sseEvent("text", { text: part.text })));
                    }
                    if (part.functionCall) {
                      functionCalls.push(part.functionCall);
                    }
                  }
                } catch (e) {
                  // chunk malformado, ignorar
                }
              }
            }

            // Si no hay function calls, terminamos el loop
            if (functionCalls.length === 0) {
              if (!assistantMessageSaved && (fullText || iterText)) {
                // Detectar macros en la respuesta si hay JSON al inicio
                detectedMacros = extractMacrosFromText(fullText);
                await saveAssistantMessage(
                  supabaseAdmin,
                  body.conversation_id,
                  fullText || iterText,
                  null
                );
                assistantMessageSaved = true;
              }
              break;
            }

            // Hay function_calls: ejecutar y volver a llamar a Gemini
            const toolNames = functionCalls.map(fc => fc.name);
            controller.enqueue(encoder.encode(sseEvent("tools_start", { names: toolNames })));

            // Anadir el assistant message con functionCalls al historial
            apiContents.push({
              role: "model",
              parts: functionCalls.map(fc => ({
                functionCall: { name: fc.name, args: fc.args ?? {} }
              }))
            });

            // Ejecutar cada tool y emitir su resultado al cliente
            for (const fc of functionCalls) {
              const name = fc.name;
              const args = fc.args ?? {};
              const toolResult = await executeTool(name, args, supabaseAdmin, user.id, profile, facts);
              controller.enqueue(encoder.encode(sseEvent("tool_done", { name, summary: toolResult.summary })));
              // Anadir el resultado al historial (formato Gemini: functionResponse)
              apiContents.push({
                role: "user",
                parts: [{
                  functionResponse: { name, response: { result: toolResult.content } }
                }]
              });
            }
          }

          // Guardar macros si se detectaron
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

function extractMacrosFromText(text: string): any | null {
  const jsonStr = extractJson(text);
  if (!jsonStr) return null;
  try {
    const macros = JSON.parse(jsonStr);
    if (macros.description && macros.kcal) return macros;
    return null;
  } catch {
    return null;
  }
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
  thinking?: string | null
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
    name: analysis.description ?? "Sin descripcion",
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
  content: string;       // Texto que se envia a Gemini como functionResponse
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

        // Generar el plan llamando a Gemini con prompt de plan
        const planPrompt = buildPlanPrompt(profile, facts, type, notes);
        const geminiResp = await fetch(
          `${GEMINI_BASE_URL}/${GEMINI_MODEL}:generateContent`,
          {
            method: "POST",
            headers: {
              "x-goog-api-key": GEMINI_API_KEY,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              systemInstruction: { parts: [{ text: planPrompt.system }] },
              contents: [{ role: "user", parts: [{ text: planPrompt.user }] }],
              generationConfig: {
                maxOutputTokens: 8192,
                temperature: 0.7,
                responseFormat: [{
                  type: "text",
                  mimeType: "application/json",
                }],
              },
            }),
          }
        );

        if (!geminiResp.ok) {
          const errText = await geminiResp.text();
          return { content: `Error generando plan: Gemini error ${geminiResp.status}`, summary: "Error generando plan" };
        }

        const geminiData = await geminiResp.json();
        const content = geminiData.candidates?.[0]?.content?.parts?.[0]?.text ?? "";

        let planData: any;
        try {
          const jsonStr = extractJson(content) ?? content;
          planData = JSON.parse(jsonStr);
        } catch (e) {
          return { content: `Error parseando JSON del plan: ${String(e)}`, summary: "Error parseando plan" };
        }

        if (!planData.days || !Array.isArray(planData.days)) {
          return { content: "El plan generado no tiene estructura valida (falta 'days')", summary: "Plan invalido" };
        }

        planData.type = type;
        if (!planData.title) planData.title = type === "weekly" ? "Plan semanal" : "Plan diario";
        if (!planData.summary) planData.summary = "";

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
            notes: notes ?? null,
          })
          .select()
          .single();

        if (insertError) {
          return { content: `Error guardando plan: ${insertError.message}`, summary: "Error guardando plan" };
        }

        const dayCount = planData.days.length;
        const mealCount = planData.days.reduce((sum: number, d: any) => sum + (d.meals?.length ?? 0), 0);
        return {
          content: JSON.stringify({ ok: true, plan_id: insertedPlan?.id, plan: planData }),
          summary: `Plan ${type === "weekly" ? "semanal" : "diario"} generado: ${dayCount} dias, ${mealCount} comidas`
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

  const ahora = new Date();
  const fechaHora = ahora.toLocaleString("es-ES", { timeZone: "Europe/Madrid", weekday: "long", year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", timeZoneName: "short" });
  const diaSemana = ahora.toLocaleDateString("es-ES", { timeZone: "Europe/Madrid", weekday: "long" });
  const fechaISO = ahora.toISOString();

  return `Eres NutriCoach, un dietista-nutricionista espanol con 15 anos de experiencia, especializado en nutricion clinica y deportiva. Hablas en espanol de Espana, en tono cercano y directo, basado en evidencia. No sustituyes a un medico.

CONTEXTO TEMPORAL:
- Fecha y hora actual: ${fechaHora}
- Dia de la semana: ${diaSemana}
- Fecha ISO: ${fechaISO}
- Zona horaria del usuario: Europe/Madrid (UTC+1 o UTC+2 en horario de verano)
Usa esta informacion para contextualizar tus respuestas (ej: "que has comido hoy?", "como te fue anoche durmiendo?").

TUS REGLAS:
1. SIEMPRE contrasta la peticion del usuario con su perfil antes de responder.
2. Si no cocinas o vives con familia, adapta los menus a esa realidad.
3. Antes de inventar informacion nutricional, di que necesitas verificarla.
4. Si una recomendacion medica podria ser peligrosa, sugiere consultar al medico.
5. USA LAS HERRAMIENTAS (tools) en lugar de inventar datos:
   - get_user_profile: para recordar el perfil completo
   - get_recent_meals: para ver que ha comido esta semana
   - get_health_metrics: para ver peso, pasos, FC, etc. de la ultima semana
   - remember_fact: para guardar info importante que el usuario te cuente (alergia, preferencia, objetivo)
   - web_search: para buscar info nutricional actualizada
   - calculate_daily_target: para calcular kcal/macros diarias recomendadas
   - generate_meal_plan: para generar un plan de comida semanal o diario
6. ANTES de pedir datos al usuario, CONSULTA las herramientas. Solo pregunta si no puedes obtener la info.
7. Si el usuario no tiene objetivo diario configurado, preguntale sus datos (peso, altura, edad, sexo, nivel de actividad, objetivo) y usa calculate_daily_target para calcularlo.
8. Puedes recibir AUDIOS del usuario. Escuchalos y responde a lo que dicen como si fuera texto.

FORMATO DE MACROS PARA COMIDAS:
Cuando el usuario te describa una comida o envie una foto, tu respuesta DEBE empezar con un bloque JSON valido con este formato EXACTO:

{"description": "nombre de la comida", "meal_type": "breakfast|lunch|dinner|snack|other", "kcal": 450, "protein_g": 25, "carbs_g": 55, "fat_g": 15, "confidence": 0.8, "ingredients": [{"name": "huevo", "quantity": 2, "unit": "unidades"}, {"name": "pan integral", "quantity": 50, "unit": "gramos"}]}

Reglas del JSON:
- description: nombre claro de la comida
- meal_type: uno de "breakfast", "lunch", "dinner", "snack", "other"
- kcal: calorias totales estimadas (numero)
- protein_g, carbs_g, fat_g: gramos (numero, NO 0 ni null)
- confidence: 0-1, tu confianza en la estimacion
- ingredients: lista de ingredientes con nombre, cantidad y unidad

Tras el JSON, escribe tu comentario en espanol explicando la comida y los ingredientes detectados.

Responde de forma clara, concisa y util.${profileText}${factsText}`;
}

function getAgentTools() {
  return [{
    functionDeclarations: [
      {
        name: "get_user_profile",
        description: "Obtiene el perfil completo del usuario y sus hechos guardados en memoria.",
        parameters: { type: "OBJECT", properties: {}, required: [] },
      },
      {
        name: "get_recent_meals",
        description: "Obtiene las comidas registradas en los ultimos 7 dias con sus macros.",
        parameters: { type: "OBJECT", properties: {}, required: [] },
      },
      {
        name: "get_health_metrics",
        description: "Obtiene las metricas de salud (peso, pasos, FC, etc.) de los ultimos 7 dias.",
        parameters: { type: "OBJECT", properties: {}, required: [] },
      },
      {
        name: "remember_fact",
        description: "Guarda un hecho importante sobre el usuario en memoria persistente. Usar para alergias, preferencias, objetivos, contexto familiar, etc.",
        parameters: {
          type: "OBJECT",
          properties: {
            category: {
              type: "STRING",
              enum: ["preference", "intolerance", "allergy", "goal", "context", "medical", "family", "habit", "feedback", "observation"],
              description: "Categoria del hecho"
            },
            fact: { type: "STRING", description: "El hecho a recordar (frase completa y clara)" },
            confidence: { type: "NUMBER", minimum: 0, maximum: 1, description: "Confianza (0-1)" },
          },
          required: ["category", "fact"],
        },
      },
      {
        name: "web_search",
        description: "Busca informacion en internet (alergenos, info nutricional actualizada, etc).",
        parameters: {
          type: "OBJECT",
          properties: { query: { type: "STRING", description: "Consulta de busqueda" } },
          required: ["query"],
        },
      },
      {
        name: "calculate_daily_target",
        description: "Calcula las kcal diarias recomendadas y el reparto de macros segun los datos del usuario. Usa Mifflin-St Jeor. Guarda el resultado en el perfil automaticamente.",
        parameters: {
          type: "OBJECT",
          properties: {
            weight_kg: { type: "NUMBER", description: "Peso en kg" },
            height_cm: { type: "NUMBER", description: "Altura en cm" },
            age: { type: "NUMBER", description: "Edad" },
            sex: { type: "STRING", enum: ["male", "female"], description: "Sexo biologico" },
            activity_level: { type: "STRING", enum: ["sedentary", "lightly_active", "moderately_active", "very_active", "extremely_active"], description: "Nivel de actividad" },
            goal: { type: "STRING", enum: ["lose_weight", "maintain", "gain_muscle", "recomposition", "health", "performance"], description: "Objetivo" },
          },
          required: ["weight_kg", "height_cm", "age", "sex", "activity_level", "goal"],
        },
      },
      {
        name: "generate_meal_plan",
        description: "Genera un plan de comida personalizado (semanal o diario) basado en el perfil, preferencias y restricciones del usuario. Lo guarda en la base de datos.",
        parameters: {
          type: "OBJECT",
          properties: {
            type: { type: "STRING", enum: ["weekly", "daily"], description: "Tipo de plan: semanal o diario" },
            notes: { type: "STRING", description: "Notas o preferencias adicionales (opcional)" },
          },
          required: ["type"],
        },
      },
    ]
  }];
}

function buildPlanPrompt(profile: any, facts: any[], type: string, notes?: string): { system: string; user: string } {
  const profileText = profile
    ? `PERFIL DEL USUARIO:
- Objetivo: ${profile.goal ?? "no indicado"}
- Peso: ${profile.weight_kg ?? "?"} kg
- Altura: ${profile.height_cm ?? "?"} cm
- Objetivo diario: ${profile.daily_kcal_target ?? "?"} kcal
- Macros: ${profile.daily_protein_g ?? "?"}P / ${profile.daily_carbs_g ?? "?"}C / ${profile.daily_fat_g ?? "?"}G
- Nivel de actividad: ${profile.activity_level ?? "no indicado"}
- Estilo dietetico: ${(profile.dietary_style ?? []).join(", ") || "no indicado"}
- Alergenos: ${(profile.allergens ?? []).join(", ") || "ninguno"}
- Restricciones: ${(profile.restrictions ?? []).join(", ") || "ninguna"}
- Habilidad cocinando: ${profile.cooking_skill ?? "no indicado"}`
    : "PERFIL: (usuario sin perfil configurado)";

  const factsText = facts.length
    ? `\n\nHECHOS DEL USUARIO:\n${facts.map((f) => `- [${f.category}] ${f.fact}`).join("\n")}`
    : "";

  const notesText = notes ? `\n\nNOTAS: ${notes}` : "";

  const dias = type === "weekly"
    ? `"lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"`
    : `"hoy"`;

  const system = `Eres NutriCoach, un dietista-nutricionista espanol experto. Generas planes de comida personalizados.

${profileText}${factsText}${notesText}

Genera un plan de comida ${type === "weekly" ? "semanal (7 dias)" : "diario (1 dia)"}.

REGLAS:
1. Adapta las comidas al perfil y restricciones del usuario.
2. Respeta el objetivo calorico y de macros.
3. Si hay alergenos o restricciones, NUNCA los incluyas.
4. Usa ingredientes accesibles en Espana.
5. Las comidas deben ser realistas y variadas.

FORMATO DE RESPUESTA (JSON estricto):
Devuelve EXCLUSIVAMENTE un JSON valido con esta estructura:

{
  "type": "${type}",
  "title": "Titulo breve del plan",
  "summary": "Resumen del enfoque nutricional en 1-2 frases",
  "target_kcal": ${profile?.daily_kcal_target ?? 2000},
  "target_protein_g": ${profile?.daily_protein_g ?? 150},
  "target_carbs_g": ${profile?.daily_carbs_g ?? 220},
  "target_fat_g": ${profile?.daily_fat_g ?? 70},
  "days": [
    {
      "day": ${dias},
      "meals": [
        { "type": "breakfast", "name": "...", "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "notes": "..." },
        { "type": "lunch", "name": "...", "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "notes": "..." },
        { "type": "dinner", "name": "...", "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "notes": "..." },
        { "type": "snack", "name": "...", "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "notes": "..." }
      ]
    }
  ]
}

NO escribas texto fuera del JSON.`;

  const user = `Genera un plan de comida ${type === "weekly" ? "semanal (7 dias, lunes a domingo)" : "diario (hoy)"}. Cada dia con desayuno, almuerzo, cena y un snack. Devuelve SOLO el JSON.`;

  return { system, user };
}