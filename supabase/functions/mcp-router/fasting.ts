// ============================================================
// mcp-router/fasting.ts
// MCP de ayuno intermitente: tracking de ventanas
// ============================================================

interface Context {
  userId: string;
  supabase: any;
}

// Estado del ayuno se guarda en user_preferences con key='fasting_session'
interface FastingSession {
  started_at: string;
  target_duration_h: number;
  ended_at?: string;
  protocol: "16:8" | "18:6" | "20:4" | "OMAD" | "custom";
}

export async function handleFasting(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "start_fasting":
      return await startFasting(args, ctx);
    case "end_fasting":
      return await endFasting(ctx);
    case "get_fasting_status":
      return await getFastingStatus(ctx);
    case "get_fasting_history":
      return await getFastingHistory(args.days ?? 30, ctx);
    default:
      throw new Error(`Unknown fasting method: ${method}`);
  }
}

async function startFasting(args: { protocol: string; target_duration_h?: number }, ctx: Context) {
  const session: FastingSession = {
    started_at: new Date().toISOString(),
    target_duration_h: args.target_duration_h ?? defaultDurationFor(args.protocol),
    protocol: args.protocol as any,
  };

  const { error } = await ctx.supabase.from("user_preferences").upsert(
    {
      user_id: ctx.userId,
      key: "fasting_session",
      value: session,
      scope: "fasting",
    },
    { onConflict: "user_id,key,scope" }
  );
  if (error) throw new Error(error.message);
  return session;
}

async function endFasting(ctx: Context) {
  const { data } = await ctx.supabase
    .from("user_preferences")
    .select("value")
    .eq("user_id", ctx.userId)
    .eq("key", "fasting_session")
    .eq("scope", "fasting")
    .single();

  if (!data?.value) return { ok: false, reason: "No active fasting session" };

  const session = data.value as FastingSession;
  session.ended_at = new Date().toISOString();

  // Guardar en historial
  await ctx.supabase.from("user_preferences").insert({
    user_id: ctx.userId,
    key: "fasting_history",
    value: session,
    scope: "fasting",
  });

  // Limpiar sesión activa
  await ctx.supabase
    .from("user_preferences")
    .delete()
    .eq("user_id", ctx.userId)
    .eq("key", "fasting_session")
    .eq("scope", "fasting");

  return { ok: true, session };
}

async function getFastingStatus(ctx: Context) {
  const { data } = await ctx.supabase
    .from("user_preferences")
    .select("value")
    .eq("user_id", ctx.userId)
    .eq("key", "fasting_session")
    .eq("scope", "fasting")
    .single();

  if (!data?.value) return { active: false };

  const session = data.value as FastingSession;
  const elapsed_ms = Date.now() - new Date(session.started_at).getTime();
  const elapsed_h = elapsed_ms / (1000 * 60 * 60);
  const target_h = session.target_duration_h;

  return {
    active: true,
    protocol: session.protocol,
    started_at: session.started_at,
    elapsed_h: Math.round(elapsed_h * 10) / 10,
    target_h,
    progress_pct: Math.min(100, Math.round((elapsed_h / target_h) * 100)),
    remaining_h: Math.max(0, Math.round((target_h - elapsed_h) * 10) / 10),
  };
}

async function getFastingHistory(days: number, ctx: Context) {
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  const { data } = await ctx.supabase
    .from("user_preferences")
    .select("value")
    .eq("user_id", ctx.userId)
    .eq("key", "fasting_history")
    .eq("scope", "fasting")
    .gte("created_at", since)
    .order("created_at", { ascending: false });
  return (data ?? []).map((d: any) => d.value);
}

function defaultDurationFor(protocol: string): number {
  switch (protocol) {
    case "16:8": return 16;
    case "18:6": return 18;
    case "20:4": return 20;
    case "OMAD": return 23;
    default: return 16;
  }
}
