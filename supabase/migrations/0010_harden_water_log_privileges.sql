-- ============================================================
-- 0010_harden_water_log_privileges.sql
-- Elimina privilegios heredados que no necesita el cliente
-- ============================================================

revoke all on table public.water_logs from anon;
revoke all on table public.water_logs from authenticated;
grant select, insert, delete on table public.water_logs to authenticated;
