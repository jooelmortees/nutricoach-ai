-- ============================================================
-- 0008_chat_attachments.sql
-- Adjuntos privados de chat e indice del historial reciente
-- ============================================================

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'chat-attachments',
  'chat-attachments',
  false,
  8 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'audio/wav']::text[]
)
on conflict (id) do update set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "chat_attachments_select_own" on storage.objects;
create policy "chat_attachments_select_own" on storage.objects
  for select to authenticated using (
    bucket_id = 'chat-attachments'
    and lower((storage.foldername(name))[1]) = lower((select auth.uid())::text)
    and exists (
      select 1 from public.conversations c
      where lower(c.id::text) = lower((storage.foldername(name))[2])
        and c.user_id = (select auth.uid())
    )
  );

drop policy if exists "chat_attachments_insert_own" on storage.objects;
create policy "chat_attachments_insert_own" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'chat-attachments'
    and lower((storage.foldername(name))[1]) = lower((select auth.uid())::text)
    and exists (
      select 1 from public.conversations c
      where lower(c.id::text) = lower((storage.foldername(name))[2])
        and c.user_id = (select auth.uid())
    )
  );

drop policy if exists "chat_attachments_update_own" on storage.objects;
create policy "chat_attachments_update_own" on storage.objects
  for update to authenticated using (
    bucket_id = 'chat-attachments'
    and lower((storage.foldername(name))[1]) = lower((select auth.uid())::text)
    and exists (
      select 1 from public.conversations c
      where lower(c.id::text) = lower((storage.foldername(name))[2])
        and c.user_id = (select auth.uid())
    )
  ) with check (
    bucket_id = 'chat-attachments'
    and lower((storage.foldername(name))[1]) = lower((select auth.uid())::text)
    and exists (
      select 1 from public.conversations c
      where lower(c.id::text) = lower((storage.foldername(name))[2])
        and c.user_id = (select auth.uid())
    )
  );

drop policy if exists "chat_attachments_delete_own" on storage.objects;
create policy "chat_attachments_delete_own" on storage.objects
  for delete to authenticated using (
    bucket_id = 'chat-attachments'
    and lower((storage.foldername(name))[1]) = lower((select auth.uid())::text)
    and exists (
      select 1 from public.conversations c
      where lower(c.id::text) = lower((storage.foldername(name))[2])
        and c.user_id = (select auth.uid())
    )
  );

update public.messages
set attachments = '[]'::jsonb
where attachments is null or jsonb_typeof(attachments) <> 'array';

alter table public.messages
  alter column attachments set default '[]'::jsonb,
  alter column attachments set not null;

alter table public.messages
  drop constraint if exists messages_attachments_array_check;
alter table public.messages
  add constraint messages_attachments_array_check
  check (jsonb_typeof(attachments) = 'array');

create index if not exists messages_conversation_created_id_idx
  on public.messages (conversation_id, created_at desc, id desc);
