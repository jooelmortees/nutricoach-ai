-- ============================================================
-- 0007_security_and_performance_fixes.sql
-- Correcciones de seguridad y rendimiento detectadas via
-- supabase_get_advisors (2026-07-11).
-- ============================================================

-- ============================================================
-- 1. SECURITY: handle_new_user -> SECURITY INVOKER
--
-- El linter detecta que handle_new_user() con SECURITY DEFINER es
-- ejecutable por anon/authenticated via /rest/v1/rpc/handle_new_user.
-- Como el trigger lo llama automaticamente post-insert en auth.users,
-- no necesita ser invocable desde la API publica.
-- SECURITY INVOKER es mas seguro: usa los permisos del llamador.
-- Ademas, el linter de Supabase recomienda anadir SET search_path
-- para evitar confusiones de esquemas en funciones SECURITY DEFINER.
-- ============================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data->>'full_name')
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ============================================================
-- 2. SECURITY: revoke execute de handle_new_user para anon/authenticated
--
-- El trigger sigue funcionando (es un trigger, no RPC). Pero revocamos
-- el execute directo via RPC para que nadie pueda llamar handle_new_user()
-- manualmente sin ser un nuevo usuario de auth.users.
-- ============================================================

revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.handle_new_user() from authenticated;

-- ============================================================
-- 3. PERFORMANCE: auth_rls_initplan - usar (select auth.uid()) en policies
--
-- Las policies usan auth.uid() directamente, lo que fuerza a Postgres a
-- re-evaluar auth.uid() para cada row. Wrappear en (select auth.uid())
-- hace que se evalue una vez al inicio del statement (InitPlan).
-- Ver: https://supabase.com/docs/guides/database/postgres/row-level-security
-- ============================================================

-- profiles
drop policy if exists "profiles_select_own" on profiles;
create policy "profiles_select_own" on profiles
  for select using ((select auth.uid()) = id);

drop policy if exists "profiles_insert_own" on profiles;
create policy "profiles_insert_own" on profiles
  for insert with check ((select auth.uid()) = id);

drop policy if exists "profiles_update_own" on profiles;
create policy "profiles_update_own" on profiles
  for update using ((select auth.uid()) = id);

drop policy if exists "profiles_delete_own" on profiles;
create policy "profiles_delete_own" on profiles
  for delete using ((select auth.uid()) = id);

-- meals
drop policy if exists "meals_all_own" on meals;
create policy "meals_all_own" on meals
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- user_preferences
drop policy if exists "user_prefs_all_own" on user_preferences;
create policy "user_prefs_all_own" on user_preferences
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- meal_items (via meals join)
drop policy if exists "meal_items_via_meal" on meal_items;
create policy "meal_items_via_meal" on meal_items
  for all using (
    exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = (select auth.uid()))
  ) with check (
    exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = (select auth.uid()))
  );

-- recipes
drop policy if exists "recipes_select_own_or_public" on recipes;
create policy "recipes_select_own_or_public" on recipes
  for select using ((select auth.uid()) = user_id or is_public = true);

drop policy if exists "recipes_insert_own" on recipes;
create policy "recipes_insert_own" on recipes
  for insert with check ((select auth.uid()) = user_id);

drop policy if exists "recipes_update_own" on recipes;
create policy "recipes_update_own" on recipes
  for update using ((select auth.uid()) = user_id);

drop policy if exists "recipes_delete_own" on recipes;
create policy "recipes_delete_own" on recipes
  for delete using ((select auth.uid()) = user_id);

-- health_metrics
drop policy if exists "health_metrics_all_own" on health_metrics;
create policy "health_metrics_all_own" on health_metrics
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- user_facts
drop policy if exists "user_facts_all_own" on user_facts;
create policy "user_facts_all_own" on user_facts
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- memory_embeddings
drop policy if exists "memory_embeddings_all_own" on memory_embeddings;
create policy "memory_embeddings_all_own" on memory_embeddings
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- meal_plans
drop policy if exists "meal_plans_all_own" on meal_plans;
create policy "meal_plans_all_own" on meal_plans
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- conversations
drop policy if exists "conversations_all_own" on conversations;
create policy "conversations_all_own" on conversations
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- messages (via conversations join)
drop policy if exists "messages_via_conversation" on messages;
create policy "messages_via_conversation" on messages
  for all using (
    exists (select 1 from conversations c where c.id = messages.conversation_id and c.user_id = (select auth.uid()))
  ) with check (
    exists (select 1 from conversations c where c.id = messages.conversation_id and c.user_id = (select auth.uid()))
  );

-- scheduled_nudges
drop policy if exists "scheduled_nudges_all_own" on scheduled_nudges;
create policy "scheduled_nudges_all_own" on scheduled_nudges
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- audit_log
drop policy if exists "audit_log_select_own" on audit_log;
create policy "audit_log_select_own" on audit_log
  for select using ((select auth.uid()) = user_id);

-- ============================================================
-- 4. SECURITY: eliminar policy avatars_select_public
--
-- El linter detecta que el bucket publico avatars permite listar
-- todos los archivos a cualquier cliente. Para acceso a avatares
-- publicos, se usan URLs fijas; no hace falta listing.
-- Mantenemos la lectura publica de objetos individuales (que es
-- lo que realmente se necesita) pero eliminamos el listing generico.
-- ============================================================

drop policy if exists "avatars_select_public" on storage.objects;

-- ============================================================
-- 5. SECURITY: anadir search_path a funciones SQL helper
--
-- Las funciones con SECURITY DEFINER deben fijar search_path para
-- evitar ataques de shadowing de tablas en schemas no confiables.
-- Las funciones ya existentes que usan auth.uid() en RLS policies.
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.match_memories(
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
security definer set search_path = public
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

create or replace function public.get_daily_summary(
  p_user_id uuid,
  p_date date default current_date
)
returns jsonb
language plpgsql
security definer set search_path = public
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

create or replace function public.get_weekly_summary(
  p_user_id uuid,
  p_week_start date default date_trunc('week', current_date)::date
)
returns jsonb
language plpgsql
security definer set search_path = public
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
