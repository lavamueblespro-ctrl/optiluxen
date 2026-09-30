/* ============================================================
   Optiluxen - Identidad del negocio (logo + nombre de la óptica)
   Ejecutar en: Dashboard → SQL Editor → Run
   ============================================================ */

-- 1. Guardar el logo y el nombre de la óptica en el perfil
alter table public.profiles
  add column if not exists logo_path text;

-- 2. Bucket privado para el logo de cada negocio
--    Ruta: <user_id>/logo.png
insert into storage.buckets (id, name, public)
values ('branding', 'branding', false)
on conflict (id) do nothing;

-- 3. Cada usuario solo puede leer/escribir su propio logo
drop policy if exists "branding own folder" on storage.objects;
create policy "branding own folder" on storage.objects
  for all to authenticated
  using (bucket_id = 'branding' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'branding' and (storage.foldername(name))[1] = auth.uid()::text);
