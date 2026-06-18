// ============================================================
// mcp-router/memory.ts
// MCP de memoria persistente del agente (RAG + hechos)
// ============================================================

interface Context {
  userId: string;
  supabase: any;
}

// En producción, generar embeddings con un modelo (ej. OpenAI text-embedding-3-small, 1536 dim)
// o con un modelo on-device. Aquí usamos embeddings fake (todos 0) hasta fase 2.
const EMBEDDING_DIM = 1024;

export async function handleMemory(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "remember_fact":
      return await rememberFact(args, ctx);
    case "recall_facts":
      return await recallFacts(args, ctx);
    case "forget_fact":
      return await forgetFact(args, ctx);
    case "list_recent_facts":
      return await listRecentFacts(args.days ?? 7, ctx);
    case "add_memory_embedding":
      return await addMemoryEmbedding(args, ctx);
    case "search_memories":
      return await searchMemories(args, ctx);
    default:
      throw new Error(`Unknown memory method: ${method}`);
  }
}

async function rememberFact(
  args: { category: string; fact: string; confidence?: number },
  ctx: Context
) {
  const { data, error } = await ctx.supabase.from("user_facts").insert({
    user_id: ctx.userId,
    category: args.category,
    fact: args.fact,
    confidence: args.confidence ?? 1.0,
    source: "chat",
  });
  if (error) throw new Error(error.message);
  return { ok: true, fact_id: data?.[0]?.id };
}

async function recallFacts(args: { query: string; k?: number }, ctx: Context) {
  // Búsqueda por texto simple. La semántica con embeddings viene en fase 2.
  const { data, error } = await ctx.supabase
    .from("user_facts")
    .select("*")
    .eq("user_id", ctx.userId)
    .eq("is_active", true)
    .ilike("fact", `%${args.query}%`)
    .order("last_confirmed_at", { ascending: false })
    .limit(args.k ?? 10);
  if (error) throw new Error(error.message);
  return data ?? [];
}

async function forgetFact(args: { fact_id: string }, ctx: Context) {
  const { error } = await ctx.supabase
    .from("user_facts")
    .update({ is_active: false })
    .eq("id", args.fact_id)
    .eq("user_id", ctx.userId);
  if (error) throw new Error(error.message);
  return { ok: true };
}

async function listRecentFacts(days: number, ctx: Context) {
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await ctx.supabase
    .from("user_facts")
    .select("*")
    .eq("user_id", ctx.userId)
    .eq("is_active", true)
    .gte("created_at", since)
    .order("last_confirmed_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data ?? [];
}

async function addMemoryEmbedding(
  args: { content: string; source: string; source_id?: string; metadata?: any },
  ctx: Context
) {
  // Embedding fake por ahora. En fase 2 integrar modelo real.
  const embedding = new Array(EMBEDDING_DIM).fill(0);
  const { error } = await ctx.supabase.from("memory_embeddings").insert({
    user_id: ctx.userId,
    content: args.content,
    embedding: JSON.stringify(embedding),
    source: args.source,
    source_id: args.source_id,
    metadata: args.metadata ?? {},
  });
  if (error) throw new Error(error.message);
  return { ok: true };
}

async function searchMemories(args: { query_embedding: number[]; k?: number }, ctx: Context) {
  const { data, error } = await ctx.supabase.rpc("match_memories", {
    p_user_id: ctx.userId,
    p_query_embedding: args.query_embedding,
    p_match_count: args.k ?? 5,
  });
  if (error) throw new Error(error.message);
  return data ?? [];
}
