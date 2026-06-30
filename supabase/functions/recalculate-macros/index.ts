// ============================================================
// recalculate-macros - Edge Function
// Recibe ingredientes editados por el usuario y pide a Gemini 2.5 Flash
// que calcule los macros (kcal, protein, carbs, fat) y devuelva
// un JSON estructurado garantizado por responseFormat.
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models";

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

    const ingredientsText = body.ingredients
      .map(i => `- ${i.name}: ${i.quantity} ${i.unit}`)
      .join("\n");

    const systemPrompt = `Eres un dietista-nutricionista experto. Recibes una lista de ingredientes con cantidades y debes calcular los macros totales (kcal, proteinas, carbohidratos y grasas) de la comida resultante.

Responde SOLO con un JSON valido, sin texto adicional, con este formato exacto:
{"description": "nombre de la comida", "kcal": 450, "protein_g": 25, "carbs_g": 55, "fat_g": 15}

Reglas:
- kcal: calorias totales sumando todos los ingredientes
- protein_g: gramos de proteina totales
- carbs_g: gramos de carbohidratos totales
- fat_g: gramos de grasa totales
- Usa tu conocimiento de densidad calorica: proteina 4 kcal/g, carbs 4 kcal/g, grasa 9 kcal/g
- NUNCA dejes ningun campo en 0 si la comida tiene macros
- Redondea a numeros enteros`;

    const userPrompt = `Comida: ${body.name}\nIngredientes:\n${ingredientsText}\n\nCalcula los macros totales y responde SOLO con el JSON.`;

    const response = await fetch(
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
            temperature: 0.3,
            maxOutputTokens: 500,
            responseFormat: [{
              type: "text",
              mimeType: "application/json",
              schema: {
                type: "OBJECT",
                properties: {
                  description: { type: "STRING" },
                  kcal: { type: "NUMBER" },
                  protein_g: { type: "NUMBER" },
                  carbs_g: { type: "NUMBER" },
                  fat_g: { type: "NUMBER" },
                },
                required: ["description", "kcal", "protein_g", "carbs_g", "fat_g"],
              },
            }],
          },
        }),
      }
    );

    if (!response.ok) {
      const errText = await response.text();
      console.error("Gemini error:", response.status, errText);
      return jsonError(500, `Error del modelo: ${response.status}`);
    }

    const data = await response.json();
    const content = data.candidates?.[0]?.content?.parts?.[0]?.text ?? "";

    let macros;
    try {
      macros = JSON.parse(content);
    } catch {
      // Fallback: extraer JSON del texto si responseFormat no lo garantizo
      const jsonStr = extractJson(content);
      if (!jsonStr) {
        return jsonError(500, "El modelo no devolvio un JSON valido");
      }
      macros = JSON.parse(jsonStr);
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

function extractJson(text: string): string | null {
  const firstBrace = text.indexOf("{");
  const lastBrace = text.lastIndexOf("}");
  if (firstBrace === -1 || lastBrace === -1 || lastBrace <= firstBrace) return null;
  return text.substring(firstBrace, lastBrace + 1);
}