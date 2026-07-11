// ============================================================
// generate-plan - Edge Function de Supabase
// Genera un plan de dieta semanal o diario con Gemini y lo guarda en meal_plans.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const GEMINI_BASE_URL = Deno.env.get("GEMINI_BASE_URL") ?? "https://generativelanguage.googleapis.com/v1beta/openai";
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash";

const corsHeaders = {
  "Access-Control-Allow-Origin": "app.nutricoach://",
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

    // Cargar perfil, facts y comidas recientes
    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMeals = await loadRecentMeals(supabaseAdmin, user.id);

    // System prompt para generar el plan
    const systemPrompt = buildPlanSystemPrompt(profile, facts, recentMeals, body.type, body.notes);

    const userPrompt = body.type === "weekly"
      ? "Genera un plan de comida para toda la semana (7 días, lunes a domingo). Cada día con desayuno, almuerzo, cena y un snack. Adapta las comidas a mi perfil y preferencias. Devuelve SOLO el JSON, sin texto adicional."
      : "Genera un plan de comida para un solo día (hoy). Con desayuno, almuerzo, cena y un snack. Adapta las comidas a mi perfil y preferencias. Devuelve SOLO el JSON, sin texto adicional.";

    // Llamar a Gemini sin streaming (queremos el JSON completo)
    const geminiResponse = await fetch(`${GEMINI_BASE_URL}/chat/completions`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${GEMINI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: GEMINI_MODEL,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        stream: false,
        max_completion_tokens: 8192,
        temperature: 0.7,
        // CRITICO: reasoning_effort minimal para que response_format produzca
        // JSON puro. Con reasoning_effort medium/high, Gemini emite bloques
        // de razonamiento dentro de content y corrompe el JSON.
        // Verificado empiricamente 2026-07-07.
        response_format: { type: "json_object" },
        reasoning_effort: "minimal",
      }),
    });

    if (!geminiResponse.ok) {
      const errText = await geminiResponse.text();
      return jsonError(500, `Gemini error ${geminiResponse.status}: ${errText}`);
    }

    const geminiData = await geminiResponse.json();
    const content = geminiData.choices?.[0]?.message?.content ?? "";

    // Parsear el JSON del plan
    let planData: any;
    try {
      // Gemini con response_format json_object deberia devolver JSON puro,
      // pero por si acaso extraemos el JSON del texto.
      const jsonStr = extractJson(content) ?? content;
      planData = JSON.parse(jsonStr);
    } catch (e) {
      return jsonError(500, `Error parseando JSON del plan: ${String(e)}. Content: ${content.substring(0, 500)}`);
    }

    // Validar estructura minima
    if (!planData.days || !Array.isArray(planData.days)) {
      return jsonError(500, "El plan generado no tiene la estructura esperada (falta 'days')");
    }

    // Asegurar campos obligatorios
    planData.type = body.type;
    if (!planData.title) {
      planData.title = body.type === "weekly" ? "Plan semanal" : "Plan diario";
    }
    if (!planData.summary) {
      planData.summary = "";
    }

    // Guardar en meal_plans con status=draft
    const today = new Date();
    const weekStart = today.toISOString().split("T")[0]; // YYYY-MM-DD

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
- Alérgenos: ${(profile.allergens ?? []).join(", ") || "ninguno"}
- Restricciones: ${(profile.restrictions ?? []).join(", ") || "ninguna"}
- Condiciones médicas: ${(profile.medical_conditions ?? []).join(", ") || "ninguna"}
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
    ? `"lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"`
    : `"hoy"`;

  return `Eres NutriCoach, un dietista-nutricionista español experto. Generas planes de comida personalizados basados en evidencia.

${profileText}${factsText}${mealsText}${notesText}

Genera un plan de comida ${planType === "weekly" ? "semanal (7 días)" : "diario (1 día)"}.

REGLAS:
1. Adapta las comidas al perfil, preferencias y restricciones del usuario.
2. Respeta el objetivo calórico y de macros del usuario.
3. Si hay alérgenos o restricciones, NUNCA los incluyas.
4. Usa ingredientes accesibles en España.
5. Las comidas deben ser realistas y variadas.
6. Si el usuario tiene habilidad de cocina baja, recetas simples. Si es alta, más elaboradas.
7. Si hay presupuesto, ajusta las comidas a ese rango.

FORMATO DE RESPUESTA (JSON estricto):
Devuelve EXCLUSIVAMENTE un JSON válido con esta estructura exacta. Cada comida debe ser completa y detallada:

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
        {
          "type": "breakfast",
          "name": "Nombre del plato",
          "kcal": 450,
          "protein_g": 22,
          "carbs_g": 38,
          "fat_g": 24,
          "fiber_g": 6,
          "notes": "Resumen breve de la comida en 1 frase",
          "ingredients": [
            { "name": "Avena", "quantity": 50, "unit": "g" },
            { "name": "Leche semidesnatada", "quantity": 200, "unit": "ml" },
            { "name": "Platano", "quantity": 1, "unit": "ud" }
          ],
          "preparation": "Pasos detallados de preparacion (1-2-3...), claros y concisos, en español. Incluye cantidades, temperaturas y tiempos cuando aplique.",
          "prep_time_min": 5,
          "cook_time_min": 10,
          "servings": 1,
          "difficulty": "facil",
          "tips": "Truco o variante opcional (sustituciones, ahorro tiempo, etc.)",
          "allergens": ["leche", "gluten"]
        },
        {
          "type": "lunch",
          "name": "...",
          "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "fiber_g": ...,
          "notes": "...",
          "ingredients": [ ... ],
          "preparation": "...",
          "prep_time_min": ..., "cook_time_min": ..., "servings": ..., "difficulty": "...",
          "tips": "...",
          "allergens": [ ... ]
        },
        {
          "type": "dinner",
          "name": "...",
          "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "fiber_g": ...,
          "notes": "...",
          "ingredients": [ ... ],
          "preparation": "...",
          "prep_time_min": ..., "cook_time_min": ..., "servings": ..., "difficulty": "...",
          "tips": "...",
          "allergens": [ ... ]
        },
        {
          "type": "snack",
          "name": "...",
          "kcal": ..., "protein_g": ..., "carbs_g": ..., "fat_g": ..., "fiber_g": ...,
          "notes": "...",
          "ingredients": [ ... ],
          "preparation": "...",
          "prep_time_min": ..., "cook_time_min": ..., "servings": ..., "difficulty": "...",
          "tips": "...",
          "allergens": [ ... ]
        }
      ]
    }
  ]
}

Reglas del JSON:
- type: "${planType}"
- target_kcal, target_protein_g, target_carbs_g, target_fat_g: los del perfil del usuario
- days: array con ${planType === "weekly" ? "7 dias (lunes a domingo)" : "1 dia (hoy)"}
- Cada dia tiene 4 comidas: breakfast, lunch, dinner, snack
- kcal, protein_g, carbs_g, fat_g, fiber_g: numeros enteros
- notes: resumen breve de la comida en 1 frase
- ingredients: lista SIEMPRE con al menos 3 ingredientes. Cada uno con name, quantity (numero) y unit (g, ml, ud, cda, cdta, etc.)
- preparation: pasos detallados en español, claros y accionables. Para snacks sin cocccion, indicar montaje o preparacion.
- prep_time_min, cook_time_min: minutos enteros (0 si no hay coccion)
- servings: raciones (normalmente 1)
- difficulty: "facil", "media" o "alta"
- tips: truco o variante opcional (puede ser string vacio)
- allergens: lista de alérgenos presentes (leche, gluten, huevo, frutos secos, soja, pescado, marisco, etc.). Array vacio si ninguno.

CRITICO: ingredients y preparation son OBLIGATORIOS en cada comida. No los omitas nunca.

NO escribas texto fuera del JSON.`;
}