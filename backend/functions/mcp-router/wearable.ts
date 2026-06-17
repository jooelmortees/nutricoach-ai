// ============================================================
// mcp-router/wearable.ts
// MCP de salud wearable: lee de health_metrics y agrega resúmenes
// ============================================================

interface Context {
  userId: string;
  supabase: any;
}

export async function handleWearable(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "get_health_summary":
      return await getHealthSummary(args.range ?? "today", ctx);
    case "get_sleep_last_night":
      return await getSleepLastNight(ctx);
    case "get_heart_rate_summary":
      return await getHeartRateSummary(args.range ?? "today", ctx);
    case "get_recent_workouts":
      return await getRecentWorkouts(args.days ?? 7, ctx);
    case "analyze_health_pattern":
      return await analyzeHealthPattern(args.days ?? 30, ctx);
    default:
      throw new Error(`Unknown wearable method: ${method}`);
  }
}

function rangeStart(range: string): Date {
  const now = new Date();
  if (range === "today") {
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }
  if (range === "week") {
    return new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  }
  if (range === "month") {
    return new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  }
  return new Date(0);
}

async function getHealthSummary(range: string, ctx: Context) {
  const since = rangeStart(range).toISOString();
  const { data, error } = await ctx.supabase
    .from("health_metrics")
    .select("type, value, unit, recorded_at")
    .eq("user_id", ctx.userId)
    .gte("recorded_at", since);

  if (error) throw new Error(error.message);

  // Agrupar por tipo y agregar
  const byType: Record<string, { total: number; unit: string; samples: number; latest: number }> = {};
  for (const m of data ?? []) {
    if (!byType[m.type]) byType[m.type] = { total: 0, unit: m.unit, samples: 0, latest: m.value };
    byType[m.type].total += m.value;
    byType[m.type].samples += 1;
    if (new Date(m.recorded_at) > new Date(byType[m.type].latest)) {
      byType[m.type].latest = m.value;
    }
  }

  return byType;
}

async function getSleepLastNight(ctx: Context) {
  const since = rangeStart("today").toISOString();
  const { data, error } = await ctx.supabase
    .from("health_metrics")
    .select("type, value, unit, recorded_at")
    .eq("user_id", ctx.userId)
    .eq("type", "sleep_minutes")
    .gte("recorded_at", since)
    .order("recorded_at", { ascending: false })
    .limit(1);
  if (error) throw new Error(error.message);
  return data?.[0] ?? null;
}

async function getHeartRateSummary(range: string, ctx: Context) {
  const since = rangeStart(range).toISOString();
  const { data, error } = await ctx.supabase
    .from("health_metrics")
    .select("value, recorded_at")
    .eq("user_id", ctx.userId)
    .eq("type", "heart_rate")
    .gte("recorded_at", since);
  if (error) throw new Error(error.message);

  if (!data || data.length === 0) return { avg: null, min: null, max: null, samples: 0 };

  const values = data.map((d: any) => d.value);
  return {
    avg: Math.round(values.reduce((a: number, b: number) => a + b, 0) / values.length),
    min: Math.min(...values),
    max: Math.max(...values),
    samples: values.length,
  };
}

async function getRecentWorkouts(days: number, ctx: Context) {
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
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

async function analyzeHealthPattern(days: number, ctx: Context) {
  // Detección de patrones simple: sueño promedio, FC en reposo promedio,
  // correlación con entrenamientos
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await ctx.supabase
    .from("health_metrics")
    .select("type, value, recorded_at")
    .eq("user_id", ctx.userId)
    .in("type", ["sleep_minutes", "resting_heart_rate", "steps", "workout"])
    .gte("recorded_at", since);
  if (error) throw new Error(error.message);

  const grouped: Record<string, number[]> = {};
  for (const m of data ?? []) {
    if (!grouped[m.type]) grouped[m.type] = [];
    grouped[m.type].push(m.value);
  }

  const avg = (arr: number[]) =>
    arr.length ? Math.round(arr.reduce((a, b) => a + b, 0) / arr.length) : null;

  return {
    period_days: days,
    avg_sleep_min: avg(grouped.sleep_minutes ?? []),
    avg_resting_hr: avg(grouped.resting_heart_rate ?? []),
    avg_daily_steps: avg(grouped.steps ?? []),
    workouts_count: grouped.workout?.length ?? 0,
  };
}
