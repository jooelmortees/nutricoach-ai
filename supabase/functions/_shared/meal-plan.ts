import { fetchChatCompletion } from "./llm.ts";

export type MealPlanType = "weekly" | "daily";

interface GenerateDetailedMealPlanOptions {
  apiKey: string;
  baseUrl: string;
  primaryModel: string;
  fallbackModel: string;
  /** Identificador de sesion para el proveedor (x-opencode-session). */
  sessionId?: string;
  /** Dias generados a la vez (por defecto: todos los solicitados). */
  concurrency?: number;
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

interface SkeletonMeal {
  type: string;
  name: string;
}

type WeekSkeleton = Record<string, SkeletonMeal[]>;

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
// 140s: el cliente iOS espera hasta 145s y las Edge Functions de Supabase
// cortan a los 150s. Cabe el esqueleto semanal (~30s) mas dos pasadas de
// generacion con GLM (medido 2026-10-07).
const PLAN_GENERATION_BUDGET_MS = 140_000;
const MEAL_DAY_MAX_ATTEMPTS = 3;
const MEAL_DAY_MAX_ATTEMPTS_WEEKLY = 2;
// El esqueleto tiene un unico intento: si falla, los dias se generan sin
// platos asignados (algo menos de variedad) en lugar de consumir el
// presupuesto de tiempo en otro esqueleto.
const SKELETON_MAX_ATTEMPTS = 1;
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

  // Los dias se generan en paralelo (concurrencia limitada) porque en
  // secuencial un plan semanal supera el presupuesto de tiempo: medido
  // 2026-10-07, ~72s por dia con deepseek y ~80s los 7 en paralelo.
  const concurrency = Math.min(
    Math.max(options.concurrency ?? requestedDays.length, 1),
    requestedDays.length,
  );
  let fatalErrors: string[] | null = null;
  let nextDayIndex = 0;

  // Fase previa para planes semanales: un esqueleto con los 28 platos de la
  // semana, sin repetir ninguno. Los dias se generan en paralelo y no se ven
  // entre si (medido 2026-10-07: sin esqueleto repetian la misma cena los 7
  // dias). Si el esqueleto falla, se continua sin el (menos variedad).
  let skeleton: WeekSkeleton | null = null;
  if (options.type === "weekly" && requestedDays.length > 1) {
    skeleton = await generateWeekSkeleton(options, deadlineAt);
    if (!skeleton) {
      console.warn("Esqueleto semanal no disponible: los dias se generan sin platos asignados");
    }
  }

  const generateDay = async (day: string): Promise<ParsedMealDay> => {
    const assignedMeals = skeleton?.[normalizeDay(day)] ?? null;
    const prompt = buildDetailedMealDayPrompt(
      promptOptions,
      day,
      assignedMeals ? [] : [...usedMealNames],
      assignedMeals,
    );
    let parsed: ParsedMealDay = { day: null, errors: [] };
    let lastRawContent = "";
    const maxAttempts = requestedDays.length > 1 ? MEAL_DAY_MAX_ATTEMPTS_WEEKLY : MEAL_DAY_MAX_ATTEMPTS;

    // Reintentos por dia: DeepSeek no soporta json_schema estricto
    // (verificado empiricamente 2026-10-07), asi que si el JSON no valida
    // se reintenta indicando al modelo los errores concretos (2 intentos
    // en planes semanales y 3 en diarios).
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const messages: Array<Record<string, unknown>> = [
        { role: "system", content: prompt.system },
        { role: "user", content: prompt.user },
      ];
      if (attempt > 0) {
        if (lastRawContent) {
          messages.push({ role: "assistant", content: lastRawContent.slice(0, 4_000) });
        }
        const blockedFoods = getBlockedFoods(options.profile);
        const blockedText = blockedFoods.length
          ? ` Alimentos prohibidos que NO pueden aparecer ni como ingrediente ni como alergeno: ${blockedFoods.join(", ")}.`
          : "";
        const allergenErrors = parsed.errors.filter((error) => error.includes("restringido"));
        const allergenHint = allergenErrors.length
          ? ` Sustituye las comidas que incumplen (${allergenErrors.slice(0, 3).join("; ")}) por alternativas SIN esos alimentos y devuelve el JSON completo con las comidas corregidas.`
          : "";
        messages.push({
          role: "user",
          content: `Tu respuesta anterior no cumplia el formato exigido: ${parsed.errors.slice(0, 5).join("; ")}. Devuelve SOLO el JSON corregido, completo y sin texto adicional.${blockedText}${allergenHint}`,
        });
      }

      let result: Awaited<ReturnType<typeof fetchChatCompletion>>;
      try {
        result = await fetchChatCompletion({
          apiKey: options.apiKey,
          baseUrl: options.baseUrl,
          primaryModel: options.primaryModel,
          fallbackModel: options.fallbackModel,
          preferredModel: activeModel,
          headerTimeoutMs: 20_000,
          deadlineAt,
          sessionId: options.sessionId,
          // Streaming: el plan genera respuestas largas y con stream:false
          // el primer byte puede tardar mas de lo que permite el timeout
          // de cabeceras (verificado empiricamente 2026-10-07).
          body: {
            messages,
            stream: true,
            // 16384: el razonamiento de DeepSeek consume parte del presupuesto
            // de completion y con 8192 el JSON del dia se truncaba (2026-10-07).
            max_completion_tokens: 16384,
            temperature: 0.4,
            response_format: { type: "json_object" },
            reasoning_effort: "minimal",
          },
        });
      } catch (error) {
        return { day: null, errors: [`No se pudo generar ${day}: ${String(error)}`] };
      }
      activeModel = result.model;

      if (!result.response.ok) {
        const errorBody = await result.response.text();
        return {
          day: null,
          errors: [`Modelo ${result.response.status} al generar ${day}: ${errorBody.substring(0, 300)}`],
        };
      }

      let streamed: { content: string; finishReason: string };
      try {
        streamed = await readStreamedContent(result.response, deadlineAt);
      } catch (error) {
        return { day: null, errors: [`No se pudo completar ${day}: ${String(error)}`] };
      }
      lastRawContent = streamed.content;
      if (streamed.finishReason === "length") {
        parsed = { day: null, errors: ["La respuesta se truncó por limite de tokens"] };
        continue;
      }
      parsed = parseAndValidateMealDay(lastRawContent, day, options.profile);
      if (parsed.day) break;
    }

    if (!parsed.day) {
      return {
        day: null,
        errors: parsed.errors.map((error) => `${day}: ${error}`),
      };
    }

    return parsed;
  };

  // Pool de trabajadores: cada uno toma el siguiente dia pendiente hasta
  // agotar la lista o encontrar un fallo definitivo.
  const runWorker = async () => {
    while (!fatalErrors) {
      const index = nextDayIndex++;
      if (index >= requestedDays.length) return;
      const day = requestedDays[index];
      const parsed = await generateDay(day);
      if (!parsed.day) {
        fatalErrors = parsed.errors;
        return;
      }
      generatedDays[index] = parsed.day;
      usedMealNames.push(...parsed.day.meals.map((meal: any) => meal.name));
    }
  };
  await Promise.all(
    Array.from({ length: concurrency }, () => runWorker()),
  );

  if (fatalErrors) {
    return { plan: null, errors: fatalErrors };
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

export function buildDetailedMealDayPrompt(
  options: GenerateDetailedMealPlanOptions,
  day: string,
  usedMealNames: string[],
  assignedMeals?: SkeletonMeal[] | null,
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
  const assignedMealsText = assignedMeals?.length
    ? `\n\nPLATOS ASIGNADOS PARA ESTE DIA (desarrollalos con detalle y conserva sus nombres):\n${assignedMeals.map((meal) => `- ${meal.type}: ${meal.name}`).join("\n")}`
    : "";
  // Las restricciones alimentarias van tambien al final del prompt: los
  // modelos atienden mejor a las instrucciones criticas situadas al cierre.
  const blockedFoods = getBlockedFoods(profile);
  const blockedFoodsText = blockedFoods.length
    ? `\n\nRESTRICCIONES ABSOLUTAS (alergias e intolerancias del usuario): NO incluyas NUNCA estos alimentos ni sus derivados: ${blockedFoods.join(", ")}. Revisa cada ingrediente de cada comida antes de responder.`
    : "";

  const system = `Eres NutriCoach, un dietista-nutricionista espanol experto y cocinero didactico. Genera exclusivamente las cuatro comidas de ${day}.

${profileText}${factsText}${mealsText}${notesText}${usedMealsText}${assignedMealsText}

REGLAS NUTRICIONALES:
1. Adapta las comidas al perfil, preferencias, habilidad culinaria y presupuesto.
2. La suma del dia debe aproximarse al objetivo calorico y de macros.
3. Nunca incluyas un alergeno o alimento restringido por el usuario.
4. Usa ingredientes faciles de encontrar en Espana y cantidades realistas.
5. Incluye exactamente breakfast, lunch, dinner y snack, sin repetir tipos.
6. Prioriza la variedad: evita platos o combinaciones casi identicas a las de otros dias de la semana.

DETALLE OBLIGATORIO DE CADA COMIDA:
1. ingredients incluye TODOS los ingredientes utilizados, incluidos aceite, salsas, especias y guarniciones. Cada uno lleva name, quantity numerica exacta y unit.
2. preparation_steps contiene entre 4 y 8 pasos, en orden, muy detallados y accionables.
3. Explica preparacion previa, cortes o mezclas, utensilios, orden de incorporacion, potencia o temperatura, tiempos, punto de coccion, emplatado y conservacion cuando aplique.
4. Repite en los pasos las cantidades relevantes para poder seguir la receta sin volver continuamente a la lista.
5. No uses frases vagas como "cocinar hasta que este listo"; describe senales observables del punto correcto.
6. Incluso un desayuno o snack sin coccion debe explicar montaje, orden, textura y servicio en al menos 4 pasos.
7. Los tiempos y raciones deben concordar con la receta. allergens lleva solo alergenos presentes.

Devuelve exclusivamente un JSON valido, sin markdown ni texto adicional, con esta forma exacta:
{
  "day": "${day}",
  "meals": [
    {
      "type": "breakfast | lunch | dinner | snack",
      "name": "string",
      "kcal": numero,
      "protein_g": numero,
      "carbs_g": numero,
      "fat_g": numero,
      "fiber_g": numero,
      "notes": "string",
      "ingredients": [{ "name": "string", "quantity": numero mayor que 0, "unit": "string" }],
      "preparation_steps": ["paso detallado de al menos 20 caracteres", "..."],
      "prep_time_min": entero,
      "cook_time_min": entero,
      "servings": entero mayor o igual que 1,
      "difficulty": "facil | media | alta",
      "tips": "string",
      "allergens": ["string"]
    }
  ]
}
Restricciones del formato: exactamente 4 comidas (una de cada type), minimo 2 ingredientes por comida, entre 4 y 8 pasos por comida, y ninguna propiedad adicional fuera de las indicadas.${blockedFoodsText}`;
  const user = assignedMeals?.length
    ? `Desarrolla las cuatro comidas asignadas de ${day} con recetas de 4 a 8 pasos suficientemente detalladas para una persona sin experiencia: ${assignedMeals.map((meal) => `${meal.type} "${meal.name}"`).join("; ")}.`
    : `Genera ${day} con cuatro comidas distintas y recetas de 4 a 8 pasos suficientemente detalladas para una persona sin experiencia.`;
  return { system, user };
}

/** Disena el esqueleto del plan semanal: 28 platos unicos (4 por dia). */
async function generateWeekSkeleton(
  options: GenerateDetailedMealPlanOptions,
  deadlineAt: number,
): Promise<WeekSkeleton | null> {
  const profile = options.profile;
  const targetKcal = numericTarget(profile?.daily_kcal_target, 2000);
  const targetProtein = numericTarget(profile?.daily_protein_g, 150);
  const blockedFoods = getBlockedFoods(profile);
  const factsText = options.facts?.length
    ? `\nHECHOS DEL USUARIO:\n${options.facts.map((fact: any) => `- [${fact.category}] ${fact.fact}`).join("\n")}`
    : "";
  const notesText = options.notes?.trim() ? `\nNOTAS DEL USUARIO: ${options.notes.trim()}` : "";
  const blockedText = blockedFoods.length
    ? `\n- NO incluyas NUNCA estos alimentos ni sus derivados: ${blockedFoods.join(", ")}.`
    : "";

  const system = `Eres un dietista-nutricionista espanol. Disena SOLO los nombres de los platos de una semana completa (lunes a domingo), con 4 comidas por dia: breakfast, lunch, dinner y snack.
REGLAS:
1. Ningun plato puede repetirse en toda la semana: 28 nombres distintos, sin variantes casi identicas.
2. Cocina espanola variada y realista, con ingredientes faciles de encontrar en Espana.
3. Cada dia debe aproximarse a ${targetKcal} kcal y ${targetProtein} g de proteina en total.
4. Desayunos y snacks variados entre si (no el mismo esquema todos los dias).${blockedText}${factsText}${notesText}

Devuelve exclusivamente un JSON valido con esta forma exacta, sin texto adicional:
{"days":[{"day":"lunes","meals":[{"type":"breakfast","name":"..."},{"type":"lunch","name":"..."},{"type":"dinner","name":"..."},{"type":"snack","name":"..."}]},{"day":"martes","meals":[...]}, ... hasta domingo]}`;

  for (let attempt = 0; attempt < SKELETON_MAX_ATTEMPTS; attempt++) {
    const messages: Array<Record<string, unknown>> = [
      { role: "system", content: system },
      { role: "user", content: "Disena el esqueleto semanal completo (7 dias, 28 platos unicos)." },
    ];
    if (attempt > 0) {
      messages.push({
        role: "user",
        content: "El esqueleto anterior no era valido: habia platos repetidos o el formato era incorrecto. Devuelve SOLO el JSON corregido con 28 platos unicos.",
      });
    }

    let result: Awaited<ReturnType<typeof fetchChatCompletion>>;
    try {
      result = await fetchChatCompletion({
        apiKey: options.apiKey,
        baseUrl: options.baseUrl,
        primaryModel: options.primaryModel,
        fallbackModel: options.fallbackModel,
        headerTimeoutMs: 20_000,
        deadlineAt,
        sessionId: options.sessionId,
        body: {
          messages,
          stream: true,
          max_completion_tokens: 4096,
          temperature: 0.6,
          response_format: { type: "json_object" },
          reasoning_effort: "minimal",
        },
      });
    } catch (error) {
      console.warn(`Esqueleto semanal: fallo de red (${String(error)})`);
      return null;
    }
    if (!result.response.ok) {
      console.warn(`Esqueleto semanal: HTTP ${result.response.status}`);
      return null;
    }

    let streamed: { content: string; finishReason: string };
    try {
      streamed = await readStreamedContent(result.response, deadlineAt);
    } catch (error) {
      console.warn(`Esqueleto semanal: ${String(error)}`);
      return null;
    }

    const skeleton = parseSkeleton(streamed.content);
    if (!skeleton) continue;
    const errors = validateSkeleton(skeleton, profile);
    if (errors.length === 0) return skeleton;
    console.warn(`Esqueleto semanal invalido: ${errors.slice(0, 5).join("; ")}`);
  }
  return null;
}

function parseSkeleton(content: string): WeekSkeleton | null {
  const json = extractJson(content);
  if (!json) return null;
  try {
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed?.days)) return null;
    const skeleton: WeekSkeleton = {};
    for (const dayEntry of parsed.days) {
      if (!isRecord(dayEntry) || !isNonEmptyString(dayEntry.day)) return null;
      const dayKey = normalizeDay(dayEntry.day);
      if (!WEEK_DAYS.includes(dayKey)) continue;
      if (!Array.isArray(dayEntry.meals) || dayEntry.meals.length !== MEAL_TYPES.length) return null;
      const meals: SkeletonMeal[] = [];
      for (const meal of dayEntry.meals) {
        if (!isRecord(meal) || !MEAL_TYPES.includes(meal.type) || !isNonEmptyString(meal.name)) return null;
        meals.push({ type: meal.type, name: meal.name.trim() });
      }
      skeleton[dayKey] = meals;
    }
    if (Object.keys(skeleton).length !== WEEK_DAYS.length) return null;
    return skeleton;
  } catch {
    return null;
  }
}

function validateSkeleton(skeleton: WeekSkeleton, profile: any): string[] {
  const errors: string[] = [];
  const seen = new Set<string>();
  const blockedFoods = getBlockedFoods(profile);
  for (const day of WEEK_DAYS) {
    const meals = skeleton[day];
    if (!meals) {
      errors.push(`falta el dia ${day}`);
      continue;
    }
    for (const meal of meals) {
      const name = normalizeFood(meal.name);
      if (seen.has(name)) errors.push(`plato repetido: ${meal.name}`);
      seen.add(name);
      for (const blockedFood of blockedFoods) {
        if (matchesBlockedFood(name, blockedFood)) {
          errors.push(`plato con alimento restringido '${blockedFood}': ${meal.name}`);
        }
      }
    }
  }
  return errors;
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

/** Lee un stream SSE de chat/completions y acumula el contenido y el finish_reason. */
async function readStreamedContent(
  response: Response,
  deadlineAt: number,
): Promise<{ content: string; finishReason: string }> {
  const remainingMs = deadlineAt - Date.now();
  if (remainingMs <= 0) throw new Error("Se agoto el tiempo de generacion del plan");

  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let content = "";
  let finishReason = "stop";
  let timedOut = false;

  const timeoutId = setTimeout(() => {
    timedOut = true;
    void reader.cancel().catch(() => {});
  }, remainingMs);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const payload = trimmed.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        try {
          const chunk = JSON.parse(payload);
          const choice = chunk.choices?.[0];
          if (!choice) continue;
          if (typeof choice.finish_reason === "string" && choice.finish_reason) {
            finishReason = choice.finish_reason;
          }
          if (typeof choice.delta?.content === "string") {
            content += choice.delta.content;
          }
        } catch {
          // chunk parcial: ignorar
        }
      }
    }
  } finally {
    clearTimeout(timeoutId);
  }
  if (timedOut) throw new Error("Se agoto el tiempo de generacion del plan");
  return { content, finishReason };
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
