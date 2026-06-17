-- ============================================================
-- 0001_init.sql
-- Schema inicial: tablas principales, enums, índices
-- ============================================================

-- Extensión pgvector para embeddings (memoria semántica)
create extension if not exists vector;

-- Extensión pg_trgm para búsqueda fuzzy
create extension if not exists pg_trgm;

-- Extensión uuid-ossp para IDs
create extension if not exists "uuid-ossp";

-- ============================================================
-- ENUMS
-- ============================================================

create type sex_t as enum ('male', 'female', 'other');
create type activity_level_t as enum (
  'sedentary', 'lightly_active', 'moderately_active',
  'very_active', 'extremely_active'
);
create type goal_t as enum (
  'lose_weight', 'maintain', 'gain_muscle',
  'recomposition', 'health', 'performance'
);
create type meal_source_t as enum (
  'manual', 'barcode', 'vision_photo', 'vision_video',
  'recipe', 'ai_suggestion'
);
create type fact_category_t as enum (
  'preference', 'intolerance', 'allergy', 'goal', 'context',
  'medical', 'family', 'habit', 'feedback', 'observation'
);
create type memory_source_t as enum (
  'chat', 'meal_log', 'health_data', 'fact', 'recipe', 'plan'
);
create type plan_status_t as enum ('draft', 'active', 'completed', 'archived');
create type nudge_kind_t as enum (
  'meal_reminder', 'hydration', 'training_prep',
  'recovery', 'motivation', 'sleep_wind_down', 'check_in'
);
create type sync_source_t as enum (
  'apple_health', 'huawei_via_health_sync', 'manual', 'wearable_other'
);

-- ============================================================
-- PERFILES
-- ============================================================

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text,
  birth_date date,
  sex sex_t,
  height_cm numeric(5,1),
  weight_kg numeric(5,1),
  target_weight_kg numeric(5,1),
  activity_level activity_level_t default 'moderately_active',
  goal goal_t default 'maintain',
  daily_kcal_target integer,
  daily_protein_g integer,
  daily_carbs_g integer,
  daily_fat_g integer,
  dietary_style text[] default '{}',
  allergens text[] default '{}',
  restrictions text[] default '{}',
  medical_conditions text[] default '{}',
  medications text[] default '{}',
  household_context text,
  cooking_skill text check (cooking_skill in ('none', 'basic', 'intermediate', 'advanced')),
  budget_eur_per_week numeric(6,2),
  locale text default 'es-ES',
  timezone text default 'Europe/Madrid',
  onboarded_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index profiles_id_idx on profiles(id);

-- ============================================================
-- PREFERENCIAS ULTRA-CONFIGURABLES
-- ============================================================

create table user_preferences (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  key text not null,
  value jsonb not null,
  scope text not null default 'general',
  updated_at timestamptz default now(),
  unique (user_id, key, scope)
);

create index user_preferences_user_idx on user_preferences(user_id);
create index user_preferences_key_idx on user_preferences(user_id, key);

-- ============================================================
-- COMIDAS Y ALIMENTOS
-- ============================================================

create table meals (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  logged_at timestamptz not null default now(),
  meal_type text check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack', 'other')),
  name text,
  notes text,
  photo_urls text[] default '{}',
  video_url text,
  source meal_source_t default 'manual',
  total_kcal numeric(8,2),
  total_protein_g numeric(7,2),
  total_carbs_g numeric(7,2),
  total_fat_g numeric(7,2),
  total_fiber_g numeric(7,2),
  ai_analysis jsonb,
  location text,
  created_at timestamptz default now()
);

create index meals_user_logged_idx on meals(user_id, logged_at desc);
create index meals_user_date_idx on meals(user_id, (date_trunc('day', logged_at at time zone 'UTC')));

create table meal_items (
  id uuid primary key default uuid_generate_v4(),
  meal_id uuid not null references meals on delete cascade,
  name text not null,
  quantity_g numeric(7,1),
  kcal numeric(7,2),
  protein_g numeric(6,2),
  carbs_g numeric(6,2),
  fat_g numeric(6,2),
  fiber_g numeric(5,2),
  source meal_source_t default 'manual',
  external_id text,    -- ID en USDA FDC u Open Food Facts
  external_source text, -- 'usda_fdc' | 'open_food_facts' | 'wger'
  confidence numeric(3,2),
  created_at timestamptz default now()
);

create index meal_items_meal_idx on meal_items(meal_id);
create index meal_items_external_idx on meal_items(external_source, external_id);

-- ============================================================
-- RECETAS
-- ============================================================

create table recipes (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users on delete cascade,
  name text not null,
  description text,
  ingredients jsonb not null default '[]',
  steps jsonb not null default '[]',
  servings integer default 1,
  prep_time_min integer,
  cook_time_min integer,
  total_kcal numeric(7,2),
  total_protein_g numeric(6,2),
  total_carbs_g numeric(6,2),
  total_fat_g numeric(6,2),
  per_serving_kcal numeric(7,2),
  per_serving_protein_g numeric(6,2),
  per_serving_carbs_g numeric(6,2),
  per_serving_fat_g numeric(6,2),
  tags text[] default '{}',
  is_public boolean default false,
  times_cooked integer default 0,
  source text default 'user', -- 'user' | 'ai' | 'web'
  source_url text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index recipes_user_idx on recipes(user_id);
create index recipes_public_idx on recipes(is_public) where is_public = true;
create index recipes_tags_idx on recipes using gin(tags);

-- ============================================================
-- DATOS DE SALUD (HealthKit sync)
-- ============================================================

create table health_metrics (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  type text not null,
  value numeric not null,
  unit text not null,
  source sync_source_t default 'apple_health',
  recorded_at timestamptz not null,
  payload jsonb,
  created_at timestamptz default now()
);

create index health_metrics_user_type_recorded_idx
  on health_metrics(user_id, type, recorded_at desc);

-- Tipos más comunes: heart_rate, resting_heart_rate, hrv, steps,
-- distance, active_energy, basal_energy, sleep_minutes, sleep_deep,
-- sleep_rem, sleep_core, sleep_awake, vo2max, body_weight, body_fat,
-- blood_oxygen, body_temperature, respiratory_rate, mindful_minutes,
-- workout_*

-- ============================================================
-- MEMORIA DEL AGENTE
-- ============================================================

-- Hechos estructurados
create table user_facts (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  category fact_category_t not null,
  fact text not null,
  confidence numeric(3,2) default 1.0 check (confidence between 0 and 1),
  source memory_source_t default 'chat',
  is_active boolean default true,
  created_at timestamptz default now(),
  last_confirmed_at timestamptz default now()
);

create index user_facts_user_idx on user_facts(user_id, is_active);
create index user_facts_category_idx on user_facts(user_id, category) where is_active = true;

-- Memoria semántica (embeddings vectoriales)
create table memory_embeddings (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  content text not null,
  embedding vector(1024),  -- Ajustar dimensión según modelo embeddings
  source memory_source_t not null,
  source_id uuid,
  metadata jsonb default '{}',
  created_at timestamptz default now()
);

create index memory_embeddings_user_idx on memory_embeddings(user_id);
create index memory_embeddings_vector_idx
  on memory_embeddings using hnsw (embedding vector_cosine_ops)
  where embedding is not null;

-- ============================================================
-- PLANES DE DIETA
-- ============================================================

create table meal_plans (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  week_start date not null,
  plan jsonb not null,
  generated_by text default 'agent',
  status plan_status_t default 'draft',
  notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index meal_plans_user_week_idx on meal_plans(user_id, week_start desc);

-- ============================================================
-- CONVERSACIONES
-- ============================================================

create table conversations (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  title text,
  summary text,
  started_at timestamptz default now(),
  last_message_at timestamptz default now()
);

create index conversations_user_idx on conversations(user_id, last_message_at desc);

create table messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid not null references conversations on delete cascade,
  role text not null check (role in ('user', 'assistant', 'system', 'tool')),
  content text,
  thinking text,
  tool_calls jsonb,
  tool_results jsonb,
  attachments jsonb default '[]',
  tokens_input integer,
  tokens_output integer,
  created_at timestamptz default now()
);

create index messages_conv_idx on messages(conversation_id, created_at);

-- ============================================================
-- NUDGES / RECORDATORIOS
-- ============================================================

create table scheduled_nudges (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  kind nudge_kind_t not null,
  title text not null,
  body text not null,
  trigger_at timestamptz not null,
  sent_at timestamptz,
  payload jsonb default '{}',
  created_at timestamptz default now()
);

create index scheduled_nudges_user_trigger_idx
  on scheduled_nudges(user_id, trigger_at)
  where sent_at is null;

-- ============================================================
-- AUDITORÍA
-- ============================================================

create table audit_log (
  id bigserial primary key,
  user_id uuid references auth.users on delete set null,
  action text not null,
  resource_type text,
  resource_id text,
  metadata jsonb default '{}',
  created_at timestamptz default now()
);

create index audit_log_user_idx on audit_log(user_id, created_at desc);
create index audit_log_action_idx on audit_log(action, created_at desc);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Auto-update updated_at
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger profiles_updated_at
  before update on profiles
  for each row execute function set_updated_at();

create trigger recipes_updated_at
  before update on recipes
  for each row execute function set_updated_at();

create trigger meal_plans_updated_at
  before update on meal_plans
  for each row execute function set_updated_at();

create trigger user_preferences_updated_at
  before update on user_preferences
  for each row execute function set_updated_at();
