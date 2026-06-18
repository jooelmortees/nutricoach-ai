// ============================================================
// mcp-router/nutrition.ts
// MCP de nutrición: USDA FoodData Central + Open Food Facts
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const USDA_FDC_BASE = "https://api.nal.usda.gov/fdc/v1";
const OFF_BASE = "https://world.openfoodfacts.org/api/v2";
const USDA_API_KEY = Deno.env.get("USDA_FDC_API_KEY") ?? "DEMO_KEY";

interface Context {
  userId: string;
  supabase: ReturnType<typeof createClient>;
}

export async function handleNutrition(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "search_food":
      return await searchFood(args.query, args.limit ?? 10);
    case "get_food_details":
      return await getFoodDetails(args.source, args.external_id);
    case "calculate_tdee":
      return calculateTDEE(args);
    case "calculate_macros":
      return calculateMacros(args);
    default:
      throw new Error(`Unknown nutrition method: ${method}`);
  }
}

async function searchFood(query: string, limit: number) {
  // Búsqueda dual: USDA + Open Food Facts
  const [usdaResults, offResults] = await Promise.all([
    searchUSDA(query, limit),
    searchOFF(query, limit),
  ]);

  return {
    usda: usdaResults,
    open_food_facts: offResults,
  };
}

async function searchUSDA(query: string, limit: number) {
  const url = new URL(`${USDA_FDC_BASE}/foods/search`);
  url.searchParams.set("api_key", USDA_API_KEY);
  url.searchParams.set("query", query);
  url.searchParams.set("pageSize", String(limit));

  const resp = await fetch(url.toString());
  if (!resp.ok) {
    return { error: `USDA error: ${resp.status}` };
  }
  const data = await resp.json();
  return (data.foods ?? []).map((f: any) => ({
    fdc_id: f.fdcId,
    description: f.description,
    brand: f.brandOwner ?? null,
    data_type: f.dataType,
    nutrients: f.foodNutrients?.slice(0, 10) ?? [],
  }));
}

async function searchOFF(query: string, limit: number) {
  const url = new URL(`${OFF_BASE}/search`);
  url.searchParams.set("categories_tags", "en:foods");
  url.searchParams.set("search_terms", query);
  url.searchParams.set("page_size", String(limit));
  url.searchParams.set("fields", "code,product_name,brands,nutriments,nutriscore_grade,image_url");

  const resp = await fetch(url.toString());
  if (!resp.ok) {
    return { error: `OFF error: ${resp.status}` };
  }
  const data = await resp.json();
  return (data.products ?? []).map((p: any) => ({
    code: p.code,
    name: p.product_name ?? "Sin nombre",
    brand: p.brands ?? null,
    nutriscore: p.nutriscore_grade ?? null,
    image: p.image_url ?? null,
    nutriments: p.nutriments ?? {},
  }));
}

async function getFoodDetails(source: string, externalId: string) {
  if (source === "usda_fdc") {
    const url = `${USDA_FDC_BASE}/food/${externalId}?api_key=${USDA_API_KEY}`;
    const resp = await fetch(url);
    if (!resp.ok) return { error: `USDA error: ${resp.status}` };
    return await resp.json();
  }
  if (source === "open_food_facts") {
    const url = `${OFF_BASE}/product/${externalId}.json`;
    const resp = await fetch(url);
    if (!resp.ok) return { error: `OFF error: ${resp.status}` };
    return await resp.json();
  }
  throw new Error(`Unknown source: ${source}`);
}

// Fórmula Mifflin-St Jeor para TMB
function calculateTDEE(args: {
  sex: "male" | "female";
  weight_kg: number;
  height_cm: number;
  age: number;
  activity_level: string;
}): number {
  const { sex, weight_kg, height_cm, age, activity_level } = args;
  const bmr = sex === "male"
    ? 10 * weight_kg + 6.25 * height_cm - 5 * age + 5
    : 10 * weight_kg + 6.25 * height_cm - 5 * age - 161;

  const factors: Record<string, number> = {
    sedentary: 1.2,
    lightly_active: 1.375,
    moderately_active: 1.55,
    very_active: 1.725,
    extremely_active: 1.9,
  };
  return Math.round(bmr * (factors[activity_level] ?? 1.55));
}

function calculateMacros(args: {
  daily_kcal: number;
  goal: string;
  weight_kg: number;
}) {
  const { daily_kcal, goal, weight_kg } = args;
  let protein_pct = 0.30, carbs_pct = 0.40, fat_pct = 0.30;
  if (goal === "lose_weight") {
    protein_pct = 0.35; carbs_pct = 0.35; fat_pct = 0.30;
  } else if (goal === "gain_muscle") {
    protein_pct = 0.30; carbs_pct = 0.45; fat_pct = 0.25;
  }

  const protein_g = Math.round((daily_kcal * protein_pct) / 4);
  const carbs_g = Math.round((daily_kcal * carbs_pct) / 4);
  const fat_g = Math.round((daily_kcal * fat_pct) / 9);

  return {
    daily_kcal,
    protein: { grams: protein_g, pct: protein_pct * 100, kcal: protein_g * 4 },
    carbs: { grams: carbs_g, pct: carbs_pct * 100, kcal: carbs_g * 4 },
    fat: { grams: fat_g, pct: fat_pct * 100, kcal: fat_g * 9 },
  };
}
