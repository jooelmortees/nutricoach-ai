import { fetchGeminiChatCompletion } from "./gemini.ts";

export type MealPlanType = "weekly" | "daily";

interface GenerateDetailedMealPlanOptions {
  apiKey: string;
  baseUrl: string;
  primaryModel: string;
  fallbackModel: string;
  profile: any;
  facts: any[];
  recentMeals?: any[];
  type: MealPlanType;
  notes?: string;
}

interface GeneratedMealPlan {
  plan: any | null;
  errors: string[];
}

interface ParsedMealDay {
  day: any | null;
  errors: string[];
}

const WEEK_DAYS = [
  "lunes",
  "martes",
  "miercoles",
  "jueves",
  "viernes",
  "sabado",
  "domingo",
];
const MEAL_TYPES = ["breakfast", "lunch", "dinner", "snack"];
const PLAN_GENERATION_BUDGET_MS = 125_000;
const ALLERGEN_ALIASES: Record<string, string[]> = {
  gluten: ["trigo", "cebada", "centeno", "pan", "pasta", "harina", "cuscus", "tortilla de trigo"],
  leche: ["leche", "lactosa", "queso", "yogur", "mantequilla", "nata", "suero", "whey"],
  lactosa: ["leche", "lactosa", "queso", "yogur", "mantequilla", "nata", "suero", "whey"],
  dairy: ["leche", "lactosa", "queso", "yogur", "mantequilla", "nata", "suero", "whey"],
  huevo: ["huevo", "clara", "yema"],
  soja: ["soja", "tofu", "edamame", "tempeh"],
  cacahuete: ["cacahuete", "mani"],
  "frutos secos": ["almendra", "nuez", "anacardo", "avellana", "pistacho", "macadamia", "pecana"],
  nuts: ["almendra", "nuez", "anacardo", "avellana", "pistacho", "macadamia", "pecana"],
  pescado: ["salmon", "atun", "merluza", "bacalao", "sardina", "anchoa", "lubina", "dorada"],
  marisco: ["gamba", "langostino", "camaron", "cangrejo", "langosta", "mejillon", "almeja", "calamar"],
  sesamo: ["sesamo", "tahini"],
};

export async function generateDetailedMealPlan(
  options: GenerateDetailedMealPlanOptions,
): Promise<GeneratedMealPlan> {
  const requestedDays = options.type === "weekly" ? WEEK_DAYS : ["hoy"];
  const generatedDays: any[] = [];
  const usedMealNames: string[] = [];
  let activeModel = options.primaryModel;
  const deadlineAt = Date.now() + PLAN_GENERATION_BUDGET_MS;
  const safeNotes = normalizeNotes(options.notes);
  const promptOptions = { ...options, notes: safeNotes };

  for (const day of requestedDays) {
    const prompt = buildDetailedMealDayPrompt(promptOptions, day, usedMealNames);
    let result: Awaited<ReturnType<typeof fetchGeminiChatCompletion>>;
    try {
      result = await fetchGeminiChatCompletion({
        apiKey: options.apiKey,
        baseUrl: options.baseUrl,
        primaryModel: options.primaryModel,
        fallbackModel: options.fallbackModel,
        preferredModel: activeModel,
        headerTimeoutMs: 30_000,
        deadlineAt,
        body: {
          messages: [
            { role: "system", content: prompt.system },
            { role: "user", content: prompt.user },
          ],
          stream: false,
          max_completion_tokens: 8192,
          temperature: 0.4,
          response_format: mealDayResponseFormat(day),
          reasoning_effort: "minimal",
        },
      });
    } catch (error) {
      return { plan: null, errors: [`No se pudo generar ${day}: ${String(error)}`] };
    }
    activeModel = result.model;

    if (!result.response.ok) {
      const errorBody = await result.response.text();
      return {
        plan: null,
        errors: [`Gemini ${result.response.status} al generar ${day}: ${errorBody.substring(0, 300)}`],
      };
    }

    let geminiData: any;
    try {
      geminiData = await readJsonBeforeDeadline(result.response, deadlineAt);
    } catch (error) {
      return { plan: null, errors: [`No se pudo completar ${day}: ${String(error)}`] };
    }
    const choice = geminiData.choices?.[0];
    if (choice?.finish_reason === "length") {
      return { plan: null, errors: [`Gemini trunco la receta de ${day}`] };
    }
    const parsed = parseAndValidateMealDay(
      choice?.message?.content ?? "",
      day,
      options.profile,
    );
    if (!parsed.day) {
      return {
        plan: null,
        errors: parsed.errors.map((error) => `${day}: ${error}`),
      };
    }

    generatedDays.push(parsed.day);
    usedMealNames.push(...parsed.day.meals.map((meal: any) => meal.name));
  }

  return {
    plan: {
      type: options.type,
      title: options.type === "weekly" ? "Plan semanal personalizado" : "Plan diario personalizado",
      summary: buildPlanSummary(options.profile, safeNotes),
      target_kcal: numericTarget(options.profile?.daily_kcal_target, 2000),
      target_protein_g: numericTarget(options.profile?.daily_protein_g, 150),
      target_carbs_g: numericTarget(options.profile?.daily_carbs_g, 220),
      target_fat_g: numericTarget(options.profile?.daily_fat_g, 70),
      days: generatedDays,
    },
    errors: [],
  };
}

function buildDetailedMealDayPrompt(
  options: GenerateDetailedMealPlanOptions,
  day: string,
  usedMealNames: string[],
): { system: string; user: string } {
  const { profile, facts, recentMeals = [], notes } = options;
  const targetKcal = numericTarget(profile?.daily_kcal_target, 2000);
  const targetProtein = numericTarget(profile?.daily_protein_g, 150);
  const targetCarbs = numericTarget(profile?.daily_carbs_g, 220);
  const targetFat = numericTarget(profile?.daily_fat_g, 70);
  const profileText = profile
    ? `PERFIL DEL USUARIO:
- Nombre: ${profile.full_name ?? "no indicado"}
- Objetivo: ${profile.goal ?? "no indicado"}
- Peso: ${profile.weight_kg ?? "?"} kg
- Altura: ${profile.height_cm ?? "?"} cm
- Objetivo diario: ${targetKcal} kcal
- Macros diarios: ${targetProtein}P / ${targetCarbs}C / ${targetFat}G
- Nivel de actividad: ${profile.activity_level ?? "no indicado"}
- Estilo dietetico: ${(profile.dietary_style ?? []).join(", ") || "no indicado"}
- Alergenos: ${(profile.allergens ?? []).join(", ") || "ninguno"}
- Restricciones: ${(profile.restrictions ?? []).join(", ") || "ninguna"}
- Condiciones medicas: ${(profile.medical_conditions ?? []).join(", ") || "ninguna"}
- Habilidad cocinando: ${profile.cooking_skill ?? "no indicado"}
- Presupuesto semanal: ${profile.budget_eur_per_week ?? "no indicado"} EUR`
    : `PERFIL: usuario sin perfil configurado
- Objetivo diario provisional: ${targetKcal} kcal
- Macros diarios provisionales: ${targetProtein}P / ${targetCarbs}C / ${targetFat}G`;
  const factsText = facts.length
    ? `\n\nHECHOS DEL USUARIO:\n${facts.map((fact) => `- [${fact.category}] ${fact.fact}`).join("\n")}`
    : "";
  const mealsText = recentMeals.length
    ? `\n\nCOMIDAS RECIENTES:\n${recentMeals.map((meal) => `- ${meal.name} (${meal.meal_type ?? "?"}): ${meal.total_kcal ?? "?"} kcal`).join("\n")}`
    : "";
  const notesText = notes?.trim() ? `\n\nNOTAS DEL USUARIO: ${notes.trim()}` : "";
  const usedMealsText = usedMealNames.length
    ? `\n\nPLATOS YA USADOS EN OTROS DIAS (no repetir):\n${usedMealNames.map((name) => `- ${name}`).join("\n")}`
    : "";

  const system = `Eres NutriCoach, un dietista-nutricionista espanol experto y cocinero didactico. Genera exclusivamente las cuatro comidas de ${day}.

${profileText}${factsText}${mealsText}${notesText}${usedMealsText}

REGLAS NUTRICIONALES:
1. Adapta las comidas al perfil, preferencias, habilidad culinaria y presupuesto.
2. La suma del dia debe aproximarse al objetivo calorico y de macros.
3. Nunca incluyas un alergeno o alimento restringido por el usuario.
4. Usa ingredientes faciles de encontrar en Espana y cantidades realistas.
5. Incluye exactamente breakfast, lunch, dinner y snack, sin repetir tipos.

DETALLE OBLIGATORIO DE CADA COMIDA:
1. ingredients incluye TODOS los ingredientes utilizados, incluidos aceite, salsas, especias y guarniciones. Cada uno lleva name, quantity numerica exacta y unit.
2. preparation_steps contiene entre 4 y 8 pasos, en orden, muy detallados y accionables.
3. Explica preparacion previa, cortes o mezclas, utensilios, orden de incorporacion, potencia o temperatura, tiempos, punto de coccion, emplatado y conservacion cuando aplique.
4. Repite en los pasos las cantidades relevantes para poder seguir la receta sin volver continuamente a la lista.
5. No uses frases vagas como "cocinar hasta que este listo"; describe senales observables del punto correcto.
6. Incluso un desayuno o snack sin coccion debe explicar montaje, orden, textura y servicio en al menos 4 pasos.
7. Los tiempos y raciones deben concordar con la receta. allergens lleva solo alergenos presentes.

Devuelve exclusivamente el JSON exigido por el schema.`;
  const user = `Genera ${day} con cuatro comidas distintas y recetas de 4 a 8 pasos suficientemente detalladas para una persona sin experiencia.`;
  return { system, user };
}

function mealDayResponseFormat(day: string): Record<string, unknown> {
  const ingredientSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      name: { type: "string", minLength: 1 },
      quantity: { type: "number", exclusiveMinimum: 0 },
      unit: { type: "string", minLength: 1 },
    },
    required: ["name", "quantity", "unit"],
  };
  const mealSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      type: { type: "string", enum: MEAL_TYPES },
      name: { type: "string", minLength: 1 },
      kcal: { type: "number", minimum: 0 },
      protein_g: { type: "number", minimum: 0 },
      carbs_g: { type: "number", minimum: 0 },
      fat_g: { type: "number", minimum: 0 },
      fiber_g: { type: "number", minimum: 0 },
      notes: { type: "string" },
      ingredients: { type: "array", minItems: 2, items: ingredientSchema },
      preparation_steps: {
        type: "array",
        minItems: 4,
        maxItems: 8,
        items: { type: "string", minLength: 20 },
      },
      prep_time_min: { type: "integer", minimum: 0 },
      cook_time_min: { type: "integer", minimum: 0 },
      servings: { type: "integer", minimum: 1 },
      difficulty: { type: "string", enum: ["facil", "media", "alta"] },
      tips: { type: "string" },
      allergens: { type: "array", items: { type: "string" } },
    },
    required: [
      "type",
      "name",
      "kcal",
      "protein_g",
      "carbs_g",
      "fat_g",
      "fiber_g",
      "notes",
      "ingredients",
      "preparation_steps",
      "prep_time_min",
      "cook_time_min",
      "servings",
      "difficulty",
      "tips",
      "allergens",
    ],
  };

  return {
    type: "json_schema",
    json_schema: {
      name: "detailed_meal_day",
      strict: true,
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          day: { type: "string", enum: [day] },
          meals: {
            type: "array",
            minItems: 4,
            maxItems: 4,
            items: mealSchema,
          },
        },
        required: ["day", "meals"],
      },
    },
  };
}

function parseAndValidateMealDay(
  content: string,
  expectedDay: string,
  profile: any,
): ParsedMealDay {
  const json = extractJson(content);
  if (!json) return { day: null, errors: ["La respuesta no contiene JSON"] };

  let day: any;
  try {
    day = JSON.parse(json);
  } catch (error) {
    return { day: null, errors: [`JSON no valido: ${String(error)}`] };
  }

  const errors = validateMealDay(day, expectedDay, profile);
  return { day: errors.length === 0 ? day : null, errors };
}

function validateMealDay(day: any, expectedDay: string, profile: any): string[] {
  const errors: string[] = [];
  if (!isRecord(day)) return ["El dia no es un objeto"];
  if (!isNonEmptyString(day.day) || normalizeDay(day.day) !== normalizeDay(expectedDay)) {
    errors.push(`day debe ser ${expectedDay}`);
  }
  if (!Array.isArray(day.meals) || day.meals.length !== MEAL_TYPES.length) {
    errors.push("meals debe contener 4 comidas");
    return errors;
  }

  const receivedMealTypes = new Set<string>();
  const blockedFoods = getBlockedFoods(profile);
  day.meals.forEach((meal: any, mealIndex: number) => {
    const path = `meals[${mealIndex}]`;
    if (!isRecord(meal)) {
      errors.push(`${path} no es un objeto`);
      return;
    }
    if (!MEAL_TYPES.includes(meal.type)) errors.push(`${path}.type no es valido`);
    else receivedMealTypes.add(meal.type);
    if (!isNonEmptyString(meal.name)) errors.push(`${path}.name es obligatorio`);
    for (const field of ["protein_g", "carbs_g", "fat_g", "fiber_g"]) {
      if (!isFiniteNumber(meal[field]) || meal[field] < 0) errors.push(`${path}.${field} no es valido`);
    }
    if (!isFiniteNumber(meal.kcal) || meal.kcal <= 0) errors.push(`${path}.kcal debe ser mayor que 0`);
    if (!Array.isArray(meal.ingredients) || meal.ingredients.length < 2) {
      errors.push(`${path}.ingredients necesita al menos 2 ingredientes`);
    } else {
      meal.ingredients.forEach((ingredient: any, ingredientIndex: number) => {
        const ingredientPath = `${path}.ingredients[${ingredientIndex}]`;
        if (!isRecord(ingredient) || !isNonEmptyString(ingredient.name)) {
          errors.push(`${ingredientPath}.name es obligatorio`);
        }
        if (!isRecord(ingredient) || !isFiniteNumber(ingredient.quantity) || ingredient.quantity <= 0) {
          errors.push(`${ingredientPath}.quantity debe ser mayor que 0`);
        }
        if (!isRecord(ingredient) || !isNonEmptyString(ingredient.unit)) {
          errors.push(`${ingredientPath}.unit es obligatorio`);
        }
      });
    }
    if (!Array.isArray(meal.preparation_steps) || meal.preparation_steps.length < 4) {
      errors.push(`${path}.preparation_steps necesita al menos 4 pasos`);
    } else if (meal.preparation_steps.some((step: unknown) => !isNonEmptyString(step) || step.trim().length < 20)) {
      errors.push(`${path}.preparation_steps contiene pasos demasiado breves`);
    }
    if (!Number.isInteger(meal.prep_time_min) || meal.prep_time_min < 0) errors.push(`${path}.prep_time_min no es valido`);
    if (!Number.isInteger(meal.cook_time_min) || meal.cook_time_min < 0) errors.push(`${path}.cook_time_min no es valido`);
    if (!Number.isInteger(meal.servings) || meal.servings < 1) errors.push(`${path}.servings no es valido`);
    if (!["facil", "media", "alta"].includes(meal.difficulty)) errors.push(`${path}.difficulty no es valido`);
    if (!Array.isArray(meal.allergens)) errors.push(`${path}.allergens debe ser una lista`);
    const mealFoods = [
      ...(Array.isArray(meal.ingredients) ? meal.ingredients.map((ingredient: any) => ingredient?.name) : []),
      ...(Array.isArray(meal.allergens) ? meal.allergens : []),
    ].filter(isNonEmptyString).map(normalizeFood);
    for (const blockedFood of blockedFoods) {
      if (mealFoods.some((food) => matchesBlockedFood(food, blockedFood))) {
        errors.push(`${path} contiene el alimento o alergeno restringido '${blockedFood}'`);
      }
    }
  });
  if (MEAL_TYPES.some((mealType) => !receivedMealTypes.has(mealType))) {
    errors.push("meals debe incluir breakfast, lunch, dinner y snack");
  }
  validateDailyTotals(day.meals, profile, errors);
  return errors.slice(0, 25);
}

function validateDailyTotals(meals: any[], profile: any, errors: string[]): void {
  const targets = [
    { field: "kcal", target: numericTarget(profile?.daily_kcal_target, 2000), tolerance: 0.2 },
    { field: "protein_g", target: numericTarget(profile?.daily_protein_g, 150), tolerance: 0.35 },
    { field: "carbs_g", target: numericTarget(profile?.daily_carbs_g, 220), tolerance: 0.35 },
    { field: "fat_g", target: numericTarget(profile?.daily_fat_g, 70), tolerance: 0.35 },
  ];
  for (const { field, target, tolerance } of targets) {
    const total = meals.reduce(
      (sum, meal) => sum + (isFiniteNumber(meal?.[field]) ? meal[field] : 0),
      0,
    );
    const minimum = target * (1 - tolerance);
    const maximum = target * (1 + tolerance);
    if (total < minimum || total > maximum) {
      errors.push(`El total diario de ${field} (${Math.round(total)}) se aleja del objetivo (${target})`);
    }
  }
}

function getBlockedFoods(profile: any): string[] {
  const rawFoods = [
    ...(Array.isArray(profile?.allergens) ? profile.allergens : []),
    ...(Array.isArray(profile?.restrictions) ? profile.restrictions : []),
  ];
  return [...new Set(rawFoods.filter(isNonEmptyString).map(normalizeFood))];
}

function matchesBlockedFood(food: string, blockedFood: string): boolean {
  const aliases = ALLERGEN_ALIASES[blockedFood] ?? [blockedFood];
  return aliases.some((alias) => food.includes(alias) || (food.length >= 4 && alias.includes(food)));
}

function buildPlanSummary(profile: any, notes?: string): string {
  const goalLabels: Record<string, string> = {
    lose_weight: "perdida de peso",
    maintain: "mantenimiento",
    gain_muscle: "ganancia muscular",
    recomposition: "recomposicion corporal",
    health: "mejora de la salud",
    performance: "rendimiento",
  };
  const goal = goalLabels[profile?.goal] ?? "tu objetivo nutricional";
  const notesSummary = notes?.trim()
    ? ` Se han tenido en cuenta tus indicaciones: ${notes.trim().slice(0, 300)}.`
    : "";
  return `Plan adaptado a ${goal}, con cantidades exactas y recetas detalladas paso a paso.${notesSummary}`;
}

function numericTarget(value: unknown, fallback: number): number {
  return isFiniteNumber(value) ? Math.round(value) : fallback;
}

function normalizeNotes(notes: unknown): string | undefined {
  if (typeof notes !== "string") return undefined;
  const normalized = notes.trim().slice(0, 2_000);
  return normalized || undefined;
}

function normalizeFood(value: string): string {
  return value.trim().toLocaleLowerCase("es-ES")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

async function readJsonBeforeDeadline(response: Response, deadlineAt: number): Promise<any> {
  const remainingMs = deadlineAt - Date.now();
  if (remainingMs <= 0) throw new Error("Se agoto el tiempo de generacion del plan");

  let timeoutId: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      void response.body?.cancel();
      reject(new Error("Se agoto el tiempo de generacion del plan"));
    }, remainingMs);
  });
  try {
    return await Promise.race([response.json(), timeout]);
  } finally {
    if (timeoutId !== undefined) clearTimeout(timeoutId);
  }
}

function extractJson(content: string): string | null {
  const trimmed = content.trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  const firstBrace = trimmed.indexOf("{");
  const lastBrace = trimmed.lastIndexOf("}");
  if (firstBrace < 0 || lastBrace <= firstBrace) return null;
  return trimmed.substring(firstBrace, lastBrace + 1);
}

function normalizeDay(value: string): string {
  return value.trim().toLocaleLowerCase("es-ES")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
