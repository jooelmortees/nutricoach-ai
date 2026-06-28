// ============================================================
// recalculate-macros - Edge Function
// Recibe ingredientes editados por el usuario y pide a MiniMax-M3
// que calcule los macros (kcal, protein, carbs, fat) y devuelva
// un JSON estructurado.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const MINIMAX_API_KEY = Deno.env.get("MINIMAX_API_KEY")!;
const MINIMAX_BASE_URL = Deno.env.get("MINIMAX_BASE_URL") ?? "https://api.minimax.io/v1";
const MINIMAX_MODEL = Deno.env.get("MINIMAX_MODEL") ?? "MiniMax-M3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface Ingredient {
  name: string;
  quantity: number;
  unit: string;
}

interface RecalculateRequest {
  name: string;
  meal_type?: string;
  ingredients: Ingredient[];
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

    // Verificar usuario
    const supabaseUser = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !user) {
      return jsonError(401, "Invalid token");
    }

    const body: RecalculateRequest = await req.json();
    if (!body.ingredients || body.ingredients.length === 0) {
      return jsonError(400, "ingredients array required");
    }

    // Construir prompt para MiniMax
    const ingredientsText = body.ingredients
      .map(i => `- ${i.name}: ${i.quantity} ${i.unit}`)
      .join("\n");

    const systemPrompt = `Eres un dietista-nutricionista experto. Recibes una lista de ingredientes con cantidades y debes calcular los macros totales (kcal, proteínas, carbohidratos y grasas) de la comida resultante.

Responde SOLO con un JSON válido, sin texto adicional, con este formato exacto:
{"description": "nombre de la comida", "kcal": 450, "protein_g": 25, "carbs_g": 55, "fat_g": 15}

Reglas:
- kcal: calorías totales sumando todos los ingredientes
- protein_g: gramos de proteína totales
- carbs_g: gramos de carbohidratos totales
- fat_g: gramos de grasa totales
- Usa tu conocimiento de densidad calórica: proteína 4 kcal/g, carbs 4 kcal/g, grasa 9 kcal/g
- NUNCA dejes ningún campo en 0 si la comida tiene macros
- Redondea a números enteros`;

    const userPrompt = `Comida: ${body.name}\nIngredientes:\n${ingredientsText}\n\nCalcula los macros totales y responde SOLO con el JSON.`;

    // Llamar a MiniMax
    const response = await fetch(`${MINIMAX_BASE_URL}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${MINIMAX_API_KEY}`,
      },
      body: JSON.stringify({
        model: MINIMAX_MODEL,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: 0.3,
        max_tokens: 200,
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      console.error("MiniMax error:", response.status, errText);
      return jsonError(500, `Error del modelo: ${response.status}`);
    }

    const data = await response.json();
    const content = data.choices?.[0]?.message?.content ?? "";

    // Extraer JSON de la respuesta
    let jsonStr = content.trim();
    // Si viene envuelto en ```json ... ```, extraerlo
    if (jsonStr.startsWith("```")) {
      jsonStr = jsonStr.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "");
    }
    // Buscar el primer { y el último }
    const firstBrace = jsonStr.indexOf("{");
    const lastBrace = jsonStr.lastIndexOf("}");
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      jsonStr = jsonStr.substring(firstBrace, lastBrace + 1);
    }

    let macros;
    try {
      macros = JSON.parse(jsonStr);
    } catch {
      return jsonError(500, "El modelo no devolvió un JSON válido");
    }

    return new Response(
      JSON.stringify({
        description: macros.description ?? body.name,
        meal_type: body.meal_type ?? "other",
        kcal: macros.kcal ?? 0,
        protein_g: macros.protein_g ?? 0,
        carbs_g: macros.carbs_g ?? 0,
        fat_g: macros.fat_g ?? 0,
        ingredients: body.ingredients,
        confidence: 0.9,
      }),
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