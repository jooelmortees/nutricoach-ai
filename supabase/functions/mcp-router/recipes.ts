// ============================================================
// mcp-router/recipes.ts
// MCP de recetas: CRUD sobre la tabla recipes
// ============================================================

interface Context {
  userId: string;
  supabase: any;
}

export async function handleRecipes(
  method: string,
  args: Record<string, any>,
  ctx: Context
): Promise<any> {
  switch (method) {
    case "list_recipes":
      return await listRecipes(args, ctx);
    case "get_recipe":
      return await getRecipe(args.recipe_id, ctx);
    case "create_recipe":
      return await createRecipe(args, ctx);
    case "update_recipe":
      return await updateRecipe(args, ctx);
    case "delete_recipe":
      return await deleteRecipe(args.recipe_id, ctx);
    case "search_recipes":
      return await searchRecipes(args, ctx);
    default:
      throw new Error(`Unknown recipes method: ${method}`);
  }
}

async function listRecipes(args: { limit?: number; only_mine?: boolean }, ctx: Context) {
  let query = ctx.supabase
    .from("recipes")
    .select("*")
    .order("updated_at", { ascending: false })
    .limit(args.limit ?? 50);

  if (args.only_mine) {
    query = query.eq("user_id", ctx.userId);
  } else {
    query = query.or(`user_id.eq.${ctx.userId},is_public.eq.true`);
  }

  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data ?? [];
}

async function getRecipe(recipeId: string, ctx: Context) {
  const { data, error } = await ctx.supabase
    .from("recipes")
    .select("*")
    .eq("id", recipeId)
    .or(`user_id.eq.${ctx.userId},is_public.eq.true`)
    .single();
  if (error) throw new Error(error.message);
  return data;
}

async function createRecipe(args: any, ctx: Context) {
  const row = {
    user_id: ctx.userId,
    name: args.name,
    description: args.description,
    ingredients: args.ingredients ?? [],
    steps: args.steps ?? [],
    servings: args.servings ?? 1,
    prep_time_min: args.prep_time_min,
    cook_time_min: args.cook_time_min,
    total_kcal: args.total_kcal,
    total_protein_g: args.total_protein_g,
    total_carbs_g: args.total_carbs_g,
    total_fat_g: args.total_fat_g,
    per_serving_kcal: args.per_serving_kcal,
    per_serving_protein_g: args.per_serving_protein_g,
    per_serving_carbs_g: args.per_serving_carbs_g,
    per_serving_fat_g: args.per_serving_fat_g,
    tags: args.tags ?? [],
    source: args.source ?? "ai",
  };
  const { data, error } = await ctx.supabase.from("recipes").insert(row);
  if (error) throw new Error(error.message);
  return data?.[0];
}

async function updateRecipe(args: any, ctx: Context) {
  const { recipe_id, ...updates } = args;
  const { data, error } = await ctx.supabase
    .from("recipes")
    .update(updates)
    .eq("id", recipe_id)
    .eq("user_id", ctx.userId);
  if (error) throw new Error(error.message);
  return { ok: true };
}

async function deleteRecipe(recipeId: string, ctx: Context) {
  const { error } = await ctx.supabase
    .from("recipes")
    .delete()
    .eq("id", recipeId)
    .eq("user_id", ctx.userId);
  if (error) throw new Error(error.message);
  return { ok: true };
}

async function searchRecipes(args: { query: string }, ctx: Context) {
  const { data, error } = await ctx.supabase
    .from("recipes")
    .select("*")
    .or(`user_id.eq.${ctx.userId},is_public.eq.true`)
    .ilike("name", `%${args.query}%`)
    .limit(20);
  if (error) throw new Error(error.message);
  return data ?? [];
}
