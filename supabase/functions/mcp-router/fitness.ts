// ============================================================
// mcp-router/fitness.ts
// MCP de fitness: wger (open source fitness database)
// ============================================================

const WGER_BASE = "https://wger.de/api/v2";

interface Context {
  userId: string;
  supabase: any;
}

export async function handleFitness(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "search_exercise":
      return await searchExercise(args.query, args.limit ?? 10);
    case "get_exercise_info":
      return await getExerciseInfo(args.exercise_id);
    case "log_workout":
      return await logWorkout(args, ctx);
    case "get_workout_history":
      return await getWorkoutHistory(args, ctx);
    default:
      throw new Error(`Unknown fitness method: ${method}`);
  }
}

async function searchExercise(query: string, limit: number) {
  const url = new URL(`${WGER_BASE}/exercise/search/`);
  url.searchParams.set("term", query);
  url.searchParams.set("language", "es"); // Español si está disponible
  url.searchParams.set("limit", String(limit));

  const resp = await fetch(url.toString());
  if (!resp.ok) return { error: `wger error: ${resp.status}` };
  const data = await resp.json();
  return data.suggestions ?? [];
}

async function getExerciseInfo(exerciseId: number) {
  const resp = await fetch(`${WGER_BASE}/exerciseinfo/${exerciseId}/`);
  if (!resp.ok) return { error: `wger error: ${resp.status}` };
  return await resp.json();
}

async function logWorkout(args: any, ctx: Context) {
  // Por ahora guardamos en health_metrics con type 'workout'
  const row = {
    user_id: ctx.userId,
    type: "workout",
    value: args.duration_min ?? 0,
    unit: "minutes",
    recorded_at: new Date().toISOString(),
    payload: {
      activity: args.activity,
      intensity: args.intensity,
      kcal: args.kcal,
      notes: args.notes,
    },
  };
  const { data, error } = await ctx.supabase.from("health_metrics").insert(row);
  if (error) throw new Error(error.message);
  return data;
}

async function getWorkoutHistory(args: { days: number }, ctx: Context) {
  const since = new Date(Date.now() - args.days * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await ctx.supabase
    .from("health_metrics")
    .select("*")
    .eq("user_id", ctx.userId)
    .eq("type", "workout")
    .gte("recorded_at", since)
    .order("recorded_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data ?? [];
}
