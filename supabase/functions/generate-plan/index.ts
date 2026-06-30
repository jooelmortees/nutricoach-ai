// ============================================================
// generate-plan - Edge Function de Supabase
// Genera un plan de dieta semanal o diario con Gemini 2.5 Flash
// y lo guarda en meal_plans. JSON garantizado por responseFormat.
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

interface GeneratePlanRequest {
  type: "weekly" | "daily";
  notes?: string;
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

    const supabaseUser = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !user) {
      return jsonError(401, "Invalid token");
    }

    const body: GeneratePlanRequest = await req.json();
    if (!body.type || (body.type !== "weekly" && body.type !== "daily")) {
      return jsonError(400, "type must be 'weekly' or 'daily'");
    }

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMeals = await loadRecentMeals(supabaseAdmin, user.id);

    const systemPrompt = buildPlanSystemPrompt(profile, facts, recentMeals, body.type, body.notes);

    const userPrompt = body.type === "weekly"
      ? "Genera un plan de comida para toda la semana (7 dias, lunes a domingo). Cada dia con desayuno, almuerzo, cena y un snack. Adapta las comidas a mi perfil y preferencias. Devuelve SOLO el JSON, sin texto adicional."
      : "Genera un plan de comida para un solo dia (hoy). Con desayuno, almuerzo, cena y un snack. Adapta las comidas a mi perfil y preferencias. Devuelve SOLO el JSON, sin texto adicional.";

    const geminiResponse = await fetch(
      `${GEMINI_BASE_URL}/${GEMINI_MODEL}:generateContent`,
      {
        method: "POST",
        headers: {
          "x-goog-api-key": GEMINI_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: systemPrompt }] },
          contents: [{ role: "user", parts: [{ text: userPrompt }] }],
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

    if (!geminiResponse.ok) {
      const errText = await geminiResponse.text();
      return jsonError(500, `Gemini error ${geminiResponse.status}: ${errText}`);
    }

    const geminiData = await geminiResponse.json();
    const content = geminiData.candidates?.[0]?.content?.parts?.[0]?.text ?? "";

    let planData: any;
    try {
      planData = JSON.parse(content);
    } catch (e) {
      // Fallback: extraer JSON del texto
      const jsonStr = extractJson(content) ?? content;
      try {
        planData = JSON.parse(jsonStr);
      } catch (e2) {
        return jsonError(500, `Error parseando JSON del plan: ${String(e2)}. Content: ${content.substring(0, 500)}`);
      }
    }

    if (!planData.days || !Array.isArray(planData.days)) {
      return jsonError(500, "El plan generado no tiene la estructura esperada (falta 'days')");
    }

    planData.type = body.type;
    if (!planData.title) {
      planData.title = body.type === "weekly" ? "Plan semanal" : "Plan diario";
    }
    if (!planData.summary) {
      planData.summary = "";
    }

    const today = new Date();
    const weekStart = today.toISOString().split("T")[0];

    const { data: insertedPlan, error: insertError } = await supabaseAdmin
      .from("meal_plans")
      .insert({
        user_id: user.id,
        week_start: weekStart,
        plan: planData,
        generated_by: "generate-plan",
        status: "draft",
        notes: body.notes ?? null,
      })
      .select()
      .single();

    if (insertError) {
      return jsonError(500, `Error guardando plan: ${insertError.message}`);
    }

    return new Response(
      JSON.stringify({ ok: true, plan: insertedPlan }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
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
    .limit(30);
  return data ?? [];
}

async function loadRecentMeals(supabase: any, userId: string) {
  const today = new Date();
  const weekAgo = new Date(today.getTime() - 7 * 24 * 60 * 60 * 1000);
  const { data } = await supabase
    .from("meals")
    .select("name, meal_type, total_kcal, total_protein_g, total_carbs_g, total_fat_g")
    .eq("user_id", userId)
    .gte("logged_at", weekAgo.toISOString())
    .order("logged_at", { ascending: false })
    .limit(10);
  return data ?? [];
}

function buildPlanSystemPrompt(
  profile: any,
  facts: any[],
  recentMeals: any[],
  planType: string,
  notes?: string
): string {
  const profileText = profile
    ? `PERFIL DEL USUARIO:
- Nombre: ${profile.full_name ?? "no indicado"}
- Objetivo: ${profile.goal ?? "no indicado"}
- Peso: ${profile.weight_kg ?? "?"} kg
- Altura: ${profile.height_cm ?? "?"} cm
- Objetivo diario: ${profile.daily_kcal_target ?? "?"} kcal
- Macros: ${profile.daily_protein_g ?? "?"}P / ${profile.daily_carbs_g ?? "?"}C / ${profile.daily_fat_g ?? "?"}G
- Nivel de actividad: ${profile.activity_level ?? "no indicado"}
- Estilo dietetico: ${(profile.dietary_style ?? []).join(", ") || "no indicado"}
- Alergenos: ${(profile.allergens ?? []).join(", ") || "ninguno"}
- Restricciones: ${(profile.restrictions ?? []).join(", ") || "ninguna"}
- Condiciones medicas: ${(profile.medical_conditions ?? []).join(", ") || "ninguna"}
- Habilidad cocinando: ${profile.cooking_skill ?? "no indicado"}
- Presupuesto semanal: ${profile.budget_eur_per_week ?? "no indicado"} EUR`
    : "PERFIL: (usuario sin perfil configurado)";

  const factsText = facts.length
    ? `\n\nHECHOS DEL USUARIO:\n${facts.map((f) => `- [${f.category}] ${f.fact}`).join("\n")}`
    : "";

  const mealsText = recentMeals.length
    ? `\n\nCOMIDAS RECIENTES (ultimos 7 dias):\n${recentMeals.map((m) => `- ${m.name} (${m.meal_type ?? "?"}): ${m.total_kcal ?? "?"} kcal`).join("\n")}`
    : "";

  const notesText = notes ? `\n\nNOTAS DEL USUARIO: ${notes}` : "";

  const diasSemana = planType === "weekly"
    ? `"lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"`
    : `"hoy"`;

  return `Eres NutriCoach, un dietista-nutricionista espanol experto. Generas planes de comida personalizados basados en evidencia.

${profileText}${factsText}${mealsText}${notesText}

Genera un plan de comida ${planType === "weekly" ? "semanal (7 dias)" : "diario (1 dia)"}.

REGLAS:
1. Adapta las comidas al perfil, preferencias y restricciones del usuario.
2. Respeta el objetivo calorico y de macros del usuario.
3. Si hay alergenos o restricciones, NUNCA los incluyas.
4. Usa ingredientes accesibles en Espana.
5. Las comidas deben ser realistas y variadas.
6. Si el usuario tiene habilidad de cocina baja, recetas simples. Si es alta, mas elaboradas.
7. Si hay presupuesto, ajusta las comidas a ese rango.

FORMATO DE RESPUESTA (JSON estricto):
Devuelve EXCLUSIVAMENTE un JSON valido con esta estructura exacta:

{
  "type": "${planType}",
  "title": "Titulo breve del plan",
  "summary": "Resumen del enfoque nutricional en 1-2 frases",
  "target_kcal": 2200,
  "target_protein_g": 160,
  "target_carbs_g": 220,
  "target_fat_g": 70,
  "days": [
    {
      "day": ${diasSemana},
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
}