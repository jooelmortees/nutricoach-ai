-- ============================================================
-- 0009_water_tracking.sql
-- Seguimiento diario de agua para app, widgets y agente
-- ============================================================

alter table public.profiles
  add column daily_water_target_ml integer not null default 2000,
  add constraint profiles_daily_water_target_ml_check
    check (daily_water_target_ml between 250 and 10000);

create table public.water_logs (
  id uuid primary key default extensions.uuid_generate_v4(),
  user_id uuid not null references auth.users on delete cascade,
  amount_ml integer not null check (amount_ml between 1 and 5000),
  logged_at timestamptz not null default now(),
  source text not null default 'app'
    check (source in ('app', 'widget', 'agent', 'healthkit')),
  client_event_id text not null default extensions.uuid_generate_v4()::text
    check (char_length(client_event_id) between 1 and 128),
  created_at timestamptz not null default now(),
  unique (user_id, client_event_id)
);

create index water_logs_user_logged_idx
  on public.water_logs (user_id, logged_at desc);

alter table public.water_logs enable row level security;

revoke all on table public.water_logs from anon;
revoke all on table public.water_logs from authenticated;
grant select, insert, delete on table public.water_logs to authenticated;

create policy "water_logs_select_own" on public.water_logs
  for select to authenticated
  using (
    (select auth.uid()) is not null
    and (select auth.uid()) = user_id
  );

create policy "water_logs_insert_own" on public.water_logs
  for insert to authenticated
  with check (
    (select auth.uid()) is not null
    and (select auth.uid()) = user_id
  );

create policy "water_logs_delete_own" on public.water_logs
  for delete to authenticated
  using (
    (select auth.uid()) is not null
    and (select auth.uid()) = user_id
  );

comment on table public.water_logs is
  'Ingestas individuales de agua registradas por la app, los widgets o el agente.';
