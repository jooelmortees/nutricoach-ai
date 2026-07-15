// ============================================================
// generate-plan - Edge Function de Supabase
// Genera un plan de dieta semanal o diario con Gemini y lo guarda en meal_plans.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
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
    if (body.notes !== undefined && typeof body.notes !== "string") {
      return jsonError(400, "notes must be a string");
    }
    if (body.notes && body.notes.length > 2_000) {
      return jsonError(400, "notes must not exceed 2000 characters");
    }
    const notes = body.notes?.trim() || undefined;

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Cargar perfil, facts y comidas recientes
    const profile = await loadProfile(supabaseAdmin, user.id);
    const facts = await loadActiveFacts(supabaseAdmin, user.id);
    const recentMeals = await loadRecentMeals(supabaseAdmin, user.id);

    const generated = await generateDetailedMealPlan({
      apiKey: GEMINI_API_KEY,
      baseUrl: GEMINI_BASE_URL,
      primaryModel: GEMINI_MODEL,
      fallbackModel: GEMINI_FALLBACK_MODEL,
      profile,
      facts,
      recentMeals,
      type: body.type,
      notes,
    });
    if (!generated.plan) {
      return jsonError(502, `No se pudo generar el plan detallado: ${generated.errors.join("; ")}`);
    }
    const planData = generated.plan;

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
        notes: notes ?? null,
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
