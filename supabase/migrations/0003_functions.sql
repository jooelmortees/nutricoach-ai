-- ============================================================
-- 0003_functions.sql
-- Funciones SQL helper: búsqueda semántica, resúmenes
-- ============================================================

-- ============================================================
-- match_memories: búsqueda semántica de memorias del usuario
-- ============================================================
create or replace function match_memories(
  p_user_id uuid,
  p_query_embedding vector(1024),
  p_match_threshold float default 0.7,
  p_match_count int default 10,
  p_source_filter memory_source_t[] default null
)
returns table (
  id uuid,
  content text,
  source memory_source_t,
  source_id uuid,
  metadata jsonb,
  similarity float,
  created_at timestamptz
)
language plpgsql
as $$
begin
  return query
  select
    me.id,
    me.content,
    me.source,
    me.source_id,
    me.metadata,
    1 - (me.embedding <=> p_query_embedding) as similarity,
    me.created_at
  from memory_embeddings me
  where me.user_id = p_user_id
    and (p_source_filter is null or me.source = any(p_source_filter))
    and 1 - (me.embedding <=> p_query_embedding) > p_match_threshold
  order by me.embedding <=> p_query_embedding
  limit p_match_count;
end;
$$;

-- ============================================================
-- get_daily_summary: resumen nutricional del día
-- ============================================================
create or replace function get_daily_summary(
  p_user_id uuid,
  p_date date default current_date
)
returns jsonb
language plpgsql
as $$
declare
  v_kcal numeric := 0;
  v_protein numeric := 0;
  v_carbs numeric := 0;
  v_fat numeric := 0;
  v_fiber numeric := 0;
  v_meal_count int := 0;
begin
  select
    coalesce(sum(m.total_kcal), 0),
    coalesce(sum(m.total_protein_g), 0),
    coalesce(sum(m.total_carbs_g), 0),
    coalesce(sum(m.total_fat_g), 0),
    coalesce(sum(m.total_fiber_g), 0),
    count(*)
  into v_kcal, v_protein, v_carbs, v_fat, v_fiber, v_meal_count
  from meals m
  where m.user_id = p_user_id
    and date_trunc('day', m.logged_at at time zone 'UTC') = p_date;

  return jsonb_build_object(
    'date', p_date,
    'kcal', v_kcal,
    'protein_g', v_protein,
    'carbs_g', v_carbs,
    'fat_g', v_fat,
    'fiber_g', v_fiber,
    'meal_count', v_meal_count
  );
end;
$$;

-- ============================================================
-- get_weekly_summary: resumen semanal
-- ============================================================
create or replace function get_weekly_summary(
  p_user_id uuid,
  p_week_start date default date_trunc('week', current_date)::date
)
returns jsonb
language plpgsql
as $$
declare
  v_days jsonb := '[]';
  v_day date;
  v_day_data jsonb;
begin
  for i in 0..6 loop
    v_day := p_week_start + i;
    v_day_data := get_daily_summary(p_user_id, v_day);
    v_days := v_days || jsonb_build_array(v_day_data);
  end loop;

  return jsonb_build_object(
    'week_start', p_week_start,
    'days', v_days
  );
end;
$$;

-- ============================================================
-- search_food: búsqueda en Open Food Facts + USDA FDC
-- Wrapper para el agente. Devuelve JSON con resultados unificados.
-- ============================================================
create or replace function search_food_cached(
  p_query text,
  p_limit int default 10
)
returns table (
  source text,
  external_id text,
  name text,
  brand text,
  kcal_per_100g numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  fiber_g numeric
)
language sql
as $$
  -- Aquí en producción consultarías OFF y USDA. Por ahora devolvemos
  -- una vista unificada si tuviéramos una tabla foods_cache.
  -- Se deja preparado para cuando se implemente el cache.
  select
    'placeholder'::text as source,
    ''::text as external_id,
    p_query as name,
    ''::text as brand,
    0::numeric as kcal_per_100g,
    0::numeric as protein_g,
    0::numeric as carbs_g,
    0::numeric as fat_g,
    0::numeric as fiber_g
  where false;
$$;
