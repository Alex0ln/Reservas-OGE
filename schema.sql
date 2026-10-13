-- OGE: ejecuta TODO este archivo en Supabase > SQL Editor > New query
-- (borra la tabla de reservas de prueba anterior, si existía)

drop table if exists public.reservas cascade;
drop function if exists public.horarios_ocupados(timestamptz, timestamptz);

-- 1. GRUPOS: una cuenta por grupo estudiantil, creada por su coordinador
create table if not exists public.grupos (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null unique check (char_length(nombre) between 2 and 80),
  coordinador text not null check (char_length(coordinador) between 2 and 100),
  telefono text,
  aprobado boolean not null default false,   -- la OGE lo activa a mano
  creado_en timestamptz not null default now()
);
alter table public.grupos enable row level security;
drop policy if exists "ver mi grupo" on public.grupos;
create policy "ver mi grupo" on public.grupos for select to authenticated using (id = auth.uid());

-- Al crear la cuenta, se crea el grupo con los datos del formulario
create or replace function public.nuevo_grupo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into grupos (id, nombre, coordinador, telefono)
  values (new.id, trim(new.raw_user_meta_data->>'nombre'),
          trim(new.raw_user_meta_data->>'coordinador'), new.raw_user_meta_data->>'telefono');
  return new;
end $$;
drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function public.nuevo_grupo();

create or replace function public.grupo_aprobado() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from grupos where id = auth.uid() and aprobado);
$$;

create or replace function public.poner_nombre_grupo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select nombre into new.grupo_nombre from grupos where id = new.grupo_id;
  return new;
end $$;

-- 2. PIZARRÓN: noticias y eventos (lectura pública, escriben grupos aprobados)
create table if not exists public.noticias (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  grupo_nombre text not null default '',
  tipo text not null check (tipo in ('noticia','evento')),
  titulo text not null check (char_length(titulo) between 3 and 120),
  cuerpo text not null check (char_length(cuerpo) between 3 and 600),
  fecha_evento date,
  creada_en timestamptz not null default now()
);
alter table public.noticias enable row level security;
drop trigger if exists nombre_noticia on public.noticias;
create trigger nombre_noticia before insert on public.noticias
  for each row execute function public.poner_nombre_grupo();
drop policy if exists "leer pizarron" on public.noticias;
drop policy if exists "publicar" on public.noticias;
drop policy if exists "borrar la mia" on public.noticias;
create policy "leer pizarron" on public.noticias for select to anon, authenticated using (true);
create policy "publicar" on public.noticias for insert to authenticated
  with check (grupo_id = auth.uid() and public.grupo_aprobado());
create policy "borrar la mia" on public.noticias for delete to authenticated using (grupo_id = auth.uid());

-- 3. RESERVAS del espacio de la OGE
create table public.reservas (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  grupo_nombre text not null default '',
  inicio timestamptz not null,
  fin timestamptz not null,
  motivo text not null check (char_length(motivo) between 3 and 200),
  responsable text not null check (char_length(responsable) between 2 and 100),
  encargado text not null check (char_length(encargado) between 2 and 100),
  estado text not null default 'confirmada' check (estado in ('confirmada','cancelada')),
  creada_en timestamptz not null default now(),
  check (fin > inicio and fin <= inicio + interval '12 hours'),
  -- Imposible que dos reservas activas se solapen
  constraint sin_solapes exclude using gist (tstzrange(inicio, fin) with &&)
    where (estado <> 'cancelada')
);
alter table public.reservas enable row level security;
create trigger nombre_reserva before insert on public.reservas
  for each row execute function public.poner_nombre_grupo();
create policy "ver mis reservas" on public.reservas for select to authenticated using (grupo_id = auth.uid());
create policy "reservar" on public.reservas for insert to authenticated
  with check (grupo_id = auth.uid() and public.grupo_aprobado() and estado = 'confirmada' and inicio > now());
create policy "cancelar la mia" on public.reservas for update to authenticated
  using (grupo_id = auth.uid()) with check (grupo_id = auth.uid());
revoke update on public.reservas from authenticated;
grant update (estado) on public.reservas to authenticated;   -- solo puede cancelar

-- Agenda pública: grupo, horario y motivo (sin datos personales)
create or replace function public.agenda(p_desde timestamptz, p_hasta timestamptz)
returns table (grupo_nombre text, inicio timestamptz, fin timestamptz, motivo text)
language sql security definer set search_path = public as $$
  select r.grupo_nombre, r.inicio, r.fin, r.motivo from reservas r
  where r.estado <> 'cancelada' and r.fin > p_desde and r.inicio < p_hasta
  order by r.inicio;
$$;
grant execute on function public.agenda(timestamptz, timestamptz) to anon, authenticated;
