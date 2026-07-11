// ============================================================
// hk-sync - Edge Function
// Recibe datos de HealthKit desde la app iOS y los persiste
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "app.nutricoach://",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface HealthMetric {
  type: string;
  value: number;
  unit: string;
  recorded_at: string;
  source?: string;
  payload?: any;
}

interface SyncRequest {
  metrics: HealthMetric[];
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
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !user) {
      return jsonError(401, "Invalid token");
    }

    const body: SyncRequest = await req.json();
    if (!Array.isArray(body.metrics) || body.metrics.length === 0) {
      return jsonError(400, "metrics array required");
    }

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Validar y normalizar
    const rows = body.metrics
      .filter((m) => m && m.type && typeof m.value === "number" && m.unit && m.recorded_at)
      .map((m) => ({
        user_id: user.id,
        type: m.type,
        value: m.value,
        unit: m.unit,
        recorded_at: m.recorded_at,
        source: m.source ?? "apple_health",
        payload: m.payload ?? null,
      }));

    if (rows.length === 0) {
      return jsonError(400, "No valid metrics");
    }

    // Upsert con ON CONFLICT DO UPDATE: las metricas diarias (pasos, kcal...)
    // crecen a lo largo del dia. Cada sync del cliente trae el aggregate
    // actualizado (HKStatisticsQuery.cumulativeSum). Con ignoreDuplicates: true
    // (ON CONFLICT DO NOTHING) el valor se congela en la primera sync del dia.
    // Con ignoreDuplicates: false (ON CONFLICT DO UPDATE) cada sync actualiza
    // el valor al aggregate mas reciente.
    const { data, error } = await supabaseAdmin
      .from("health_metrics")
      .upsert(rows, {
        onConflict: "user_id,type,recorded_at",
        ignoreDuplicates: false,
      });

    if (error) {
      return jsonError(500, error.message);
    }

    return new Response(
      JSON.stringify({ ok: true, inserted: rows.length }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return jsonError(500, String(err));
  }
});

function jsonError(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
