// ============================================================
// mcp-router - Edge Function
// Router centralizado para los 7 MCPs custom del agente.
// El agente llama a esta función con { tool_name, arguments }
// y esta función despacha al MCP correspondiente.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { handleNutrition } from "./nutrition.ts";
import { handleFitness } from "./fitness.ts";
import { handleWearable } from "./wearable.ts";
import { handleMemory } from "./memory.ts";
import { handleRecipes } from "./recipes.ts";
import { handleFasting } from "./fasting.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface MCPCall {
  tool: string;
  arguments: Record<string, any>;
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
    const { data: { user } } = await supabaseUser.auth.getUser();
    if (!user) {
      return jsonError(401, "Invalid token");
    }

    const body: MCPCall = await req.json();
    if (!body.tool) {
      return jsonError(400, "Missing tool name");
    }

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const context = { userId: user.id, supabase: supabaseAdmin };

    const [namespace, method] = body.tool.split(".");
    const args = body.arguments ?? {};

    let result: any;

    switch (namespace) {
      case "nutrition":
        result = await handleNutrition(method, args, context);
        break;
      case "fitness":
        result = await handleFitness(method, args, context);
        break;
      case "wearable":
        result = await handleWearable(method, args, context);
        break;
      case "memory":
        result = await handleMemory(method, args, context);
        break;
      case "recipes":
        result = await handleRecipes(method, args, context);
        break;
      case "fasting":
        result = await handleFasting(method, args, context);
        break;
      default:
        return jsonError(404, `Unknown MCP: ${namespace}`);
    }

    return new Response(JSON.stringify({ ok: true, result }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
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
