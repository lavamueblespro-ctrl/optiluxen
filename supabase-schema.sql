/* ============================================================
   Optiluxen — Esquema de base de datos (Supabase)
   Ejecútalo en: Dashboard → SQL Editor → New query → Run
   ============================================================ */

create extension if not exists "pgcrypto";

/* ------------------------------------------------------------
   1. PERFILES  (estado de la suscripción por usuario)
   ------------------------------------------------------------ */
create table if not exists public.profiles (
  id               uuid primary key references auth.users on delete cascade,
  full_name        text,
  plan_status      text not null default 'active',   -- 'active' | 'overdue'
  plan_next_charge date,
  created_at       timestamptz not null default now()
);

-- Se crea un perfil automáticamente al registrarse cada usuario
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, plan_next_charge)
  values (new.id, new.raw_user_meta_data->>'full_name', current_date + 30)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

/* ------------------------------------------------------------
   2. CLIENTES
   ------------------------------------------------------------ */
create table if not exists public.clients (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users on delete cascade,
  nombre     text not null,
  tel        text default '',
  correo     text default '',
  fecha      date,                       -- próxima revisión ('' -> null)
  etapa      text not null default 'Nuevo',
  created_at timestamptz not null default now()
);

create index if not exists clients_owner_idx on public.clients (owner_id);

/* ------------------------------------------------------------
   3. HISTORIAL DE FÓRMULAS (recetas)
   ------------------------------------------------------------ */
create table if not exists public.prescriptions (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users on delete cascade,
  date       date not null default current_date,
  od_esf text, od_cil text, od_eje text, od_add text,
  oi_esf text, oi_cil text, oi_eje text, oi_add text,
  dp       text,
  tipo     text,
  note     text,
  img_path text,                 -- ruta dentro del bucket 'rx'
  created_at timestamptz not null default now()
);

create index if not exists prescriptions_client_idx on public.prescriptions (client_id);

/* ------------------------------------------------------------
   4. VENTAS / COBROS
   ------------------------------------------------------------ */
create table if not exists public.sales (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users on delete cascade,
  date       date not null default current_date,
  discount   numeric not null default 0,
  discount_type text not null default '%',   -- '%' porcentaje · '$' valor fijo
  total      numeric not null default 0,
  invoice_no integer,
  created_at timestamptz not null default now()
);

create index if not exists sales_client_idx on public.sales (client_id);

-- Compatibilidad con instalaciones ya creadas: se puede elegir descuento en % o en $
alter table public.sales
  add column if not exists discount_type text not null default '%';

create table if not exists public.sale_items (
  id        uuid primary key default gen_random_uuid(),
  sale_id   uuid not null references public.sales on delete cascade,
  owner_id  uuid not null default auth.uid() references auth.users on delete cascade,
  descripcion text default '',
  lente       text default '',
  trat        text default '',
  precio      numeric not null default 0
);

create index if not exists sale_items_sale_idx on public.sale_items (sale_id);

/* ------------------------------------------------------------
   5. CONFIGURACIÓN DE RECORDATORIOS
   ------------------------------------------------------------ */
create table if not exists public.reminder_settings (
  user_id     uuid primary key references auth.users on delete cascade,
  wa          boolean not null default true,
  email       boolean not null default true,
  sms         boolean not null default false,
  days        integer not null default 15,
  msg         text,
  renewal_msg text,
  updated_at  timestamptz not null default now()
);

create table if not exists public.reminder_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  canal      text,
  nombre     text,
  date       date not null default current_date,
  created_at timestamptz not null default now()
);

create index if not exists reminder_log_user_idx on public.reminder_log (user_id);

/* ------------------------------------------------------------
   6. CONTADOR DE FACTURAS (FAC-00001, FAC-00002 …) por usuario
   ------------------------------------------------------------ */
create table if not exists public.counters (
  owner_id     uuid primary key references auth.users on delete cascade,
  invoice_seq  integer not null default 1
);

create or replace function public.next_invoice_no()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  insert into public.counters (owner_id)
  values (auth.uid())
  on conflict (owner_id) do nothing;

  update public.counters
     set invoice_seq = invoice_seq + 1
   where owner_id = auth.uid()
  returning invoice_seq into n;

  return n;
end;
$$;

revoke execute on function public.next_invoice_no() from public, anon;
grant  execute on function public.next_invoice_no() to authenticated;

/* ------------------------------------------------------------
   7. SEGURIDAD — Row Level Security
   Cada usuario SOLO ve y edita sus propios datos.
   ------------------------------------------------------------ */
alter table public.profiles          enable row level security;
alter table public.clients           enable row level security;
alter table public.prescriptions     enable row level security;
alter table public.sales             enable row level security;
alter table public.sale_items        enable row level security;
alter table public.reminder_settings enable row level security;
alter table public.reminder_log      enable row level security;
alter table public.counters          enable row level security;

-- profiles
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- clients
drop policy if exists "own clients" on public.clients;
create policy "own clients" on public.clients
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- prescriptions
drop policy if exists "own prescriptions" on public.prescriptions;
create policy "own prescriptions" on public.prescriptions
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- sales
drop policy if exists "own sales" on public.sales;
create policy "own sales" on public.sales
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- sale_items
drop policy if exists "own sale items" on public.sale_items;
create policy "own sale items" on public.sale_items
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- reminder_settings
drop policy if exists "own reminder settings" on public.reminder_settings;
create policy "own reminder settings" on public.reminder_settings
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- reminder_log
drop policy if exists "own reminder log" on public.reminder_log;
create policy "own reminder log" on public.reminder_log
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- counters
drop policy if exists "own counters" on public.counters;
create policy "own counters" on public.counters
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

/* ------------------------------------------------------------
   8. STORAGE — bucket privado para fotos de fórmulas
   Ruta: <user_id>/<client_id>/<timestamp>.jpg
   ------------------------------------------------------------ */
insert into storage.buckets (id, name, public)
values ('rx', 'rx', false)
on conflict (id) do nothing;

drop policy if exists "rx own folder" on storage.objects;
create policy "rx own folder" on storage.objects
  for all to authenticated
  using (bucket_id = 'rx' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'rx' and (storage.foldername(name))[1] = auth.uid()::text);

/* ------------------------------------------------------------
   9. PERMISOS EXPLÍCITOS (por si las credenciales del proyecto
      no incluyen los grants por defecto del esquema public)
   ------------------------------------------------------------ */
do $$
declare t text;
begin
  foreach t in array array['profiles','clients','prescriptions','sales',
                           'sale_items','reminder_settings','reminder_log','counters']
  loop
    execute format('grant all on public.%I to authenticated', t);
    execute format('grant usage, select on sequence public.%I_id_seq to authenticated', t);
  end loop;
exception when others then
  -- los UUIDs con default gen_random_uuid() no crean secuencia: se ignora
  null;
end $$;

grant usage on schema public to authenticated;
