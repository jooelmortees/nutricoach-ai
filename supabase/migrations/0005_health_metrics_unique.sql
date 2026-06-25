-- 0005 - Unique constraint en health_metrics(user_id, type, recorded_at)
--
-- El upsert de hk-sync usa onConflict: "user_id,type,recorded_at" pero solo
-- habia un index non-unique. Sin unique constraint, Postgres no puede resolver
-- el conflicto eficientemente -> seq scan -> CPU alta -> 546 WORKER_RESOURCE_LIMIT.
--
-- Reemplazamos el index non-unique por un UNIQUE INDEX (ya aplicado al remote
-- via supabase_apply_migration el 2026-06-25; este file lo refleja en el repo).

drop index if exists health_metrics_user_type_recorded_idx;

create unique index health_metrics_user_type_recorded_idx
  on health_metrics(user_id, type, recorded_at desc);