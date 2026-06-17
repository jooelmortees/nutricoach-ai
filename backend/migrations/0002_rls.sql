-- ============================================================
-- 0002_rls.sql
-- Row Level Security: cada usuario solo ve/edita sus datos
-- ============================================================

-- Habilitar RLS en todas las tablas
alter table profiles enable row level security;
alter table user_preferences enable row level security;
alter table meals enable row level security;
alter table meal_items enable row level security;
alter table recipes enable row level security;
alter table health_metrics enable row level security;
alter table user_facts enable row level security;
alter table memory_embeddings enable row level security;
alter table meal_plans enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table scheduled_nudges enable row level security;
alter table audit_log enable row level security;

-- ============================================================
-- PROFILES
-- ============================================================
create policy "profiles_select_own" on profiles
  for select using (auth.uid() = id);
create policy "profiles_insert_own" on profiles
  for insert with check (auth.uid() = id);
create policy "profiles_update_own" on profiles
  for update using (auth.uid() = id);
create policy "profiles_delete_own" on profiles
  for delete using (auth.uid() = id);

-- ============================================================
-- USER_PREFERENCES
-- ============================================================
create policy "user_prefs_all_own" on user_preferences
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- MEALS
-- ============================================================
create policy "meals_all_own" on meals
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- MEAL_ITEMS (vía join con meals)
-- ============================================================
create policy "meal_items_via_meal" on meal_items
  for all using (
    exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = auth.uid())
  ) with check (
    exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = auth.uid())
  );

-- ============================================================
-- RECIPES
-- ============================================================
create policy "recipes_select_own_or_public" on recipes
  for select using (user_id = auth.uid() or is_public = true);
create policy "recipes_insert_own" on recipes
  for insert with check (auth.uid() = user_id);
create policy "recipes_update_own" on recipes
  for update using (auth.uid() = user_id);
create policy "recipes_delete_own" on recipes
  for delete using (auth.uid() = user_id);

-- ============================================================
-- HEALTH_METRICS
-- ============================================================
create policy "health_metrics_all_own" on health_metrics
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- USER_FACTS
-- ============================================================
create policy "user_facts_all_own" on user_facts
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- MEMORY_EMBEDDINGS
-- ============================================================
create policy "memory_embeddings_all_own" on memory_embeddings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- MEAL_PLANS
-- ============================================================
create policy "meal_plans_all_own" on meal_plans
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- CONVERSATIONS
-- ============================================================
create policy "conversations_all_own" on conversations
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- MESSAGES (vía conversation)
-- ============================================================
create policy "messages_via_conversation" on messages
  for all using (
    exists (select 1 from conversations c where c.id = messages.conversation_id and c.user_id = auth.uid())
  ) with check (
    exists (select 1 from conversations c where c.id = messages.conversation_id and c.user_id = auth.uid())
  );

-- ============================================================
-- SCHEDULED_NUDGES
-- ============================================================
create policy "scheduled_nudges_all_own" on scheduled_nudges
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- AUDIT_LOG (solo lectura por el propio usuario, no inserta desde cliente)
-- ============================================================
create policy "audit_log_select_own" on audit_log
  for select using (auth.uid() = user_id);

-- ============================================================
-- HELPER: función para que service_role bypase RLS
-- (Edge Functions usan service_role para operaciones del agente)
-- ============================================================
-- Las Edge Functions usan SUPABASE_SERVICE_ROLE_KEY que bypasea RLS
-- automáticamente. El cliente iOS usa anon key que sí respeta RLS.
