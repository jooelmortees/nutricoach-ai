-- ============================================================
-- 0004_storage.sql
-- Buckets de Storage y políticas de acceso
-- ============================================================

-- Bucket privado para fotos de comidas
insert into storage.buckets (id, name, public)
values ('meal-photos', 'meal-photos', false)
on conflict (id) do nothing;

-- Bucket privado para vídeos cortos de comida/recetas
insert into storage.buckets (id, name, public)
values ('meal-videos', 'meal-videos', false)
on conflict (id) do nothing;

-- Bucket para avatares (futuro)
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- ============================================================
-- POLÍTICAS DE STORAGE
-- ============================================================

-- meal-photos: solo el dueño puede leer/escribir
create policy "meal_photos_select_own" on storage.objects
  for select using (
    bucket_id = 'meal-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_photos_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'meal-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_photos_update_own" on storage.objects
  for update using (
    bucket_id = 'meal-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_photos_delete_own" on storage.objects
  for delete using (
    bucket_id = 'meal-photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- meal-videos: mismas reglas
create policy "meal_videos_select_own" on storage.objects
  for select using (
    bucket_id = 'meal-videos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_videos_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'meal-videos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_videos_update_own" on storage.objects
  for update using (
    bucket_id = 'meal-videos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "meal_videos_delete_own" on storage.objects
  for delete using (
    bucket_id = 'meal-videos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- avatars: lectura pública, escritura del dueño
create policy "avatars_select_public" on storage.objects
  for select using (bucket_id = 'avatars');

create policy "avatars_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "avatars_update_own" on storage.objects
  for update using (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "avatars_delete_own" on storage.objects
  for delete using (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- ============================================================
-- REALTIME: habilitar para tablas que el cliente escucha
-- ============================================================
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table meals;
alter publication supabase_realtime add table health_metrics;
alter publication supabase_realtime add table scheduled_nudges;
