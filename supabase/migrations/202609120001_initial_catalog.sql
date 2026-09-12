create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  firebase_uid text not null unique,
  full_name text,
  phone text,
  email text,
  role text not null default 'customer'
    check (role in ('customer', 'operator', 'finance', 'admin', 'super_admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  province text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index if not exists cities_name_lower_idx
  on public.cities (lower(name));

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  vehicle_type text,
  seat_capacity integer not null default 1 check (seat_capacity > 0),
  image_path text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.routes (
  id uuid primary key default gen_random_uuid(),
  origin_city_id uuid not null references public.cities(id),
  destination_city_id uuid not null references public.cities(id),
  vehicle_id uuid references public.vehicles(id),
  duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (origin_city_id <> destination_city_id)
);

create index if not exists routes_origin_destination_idx
  on public.routes (origin_city_id, destination_city_id)
  where is_active = true;

create table if not exists public.route_schedules (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id) on delete cascade,
  travel_date date not null,
  departure_time time not null,
  available_seats integer not null check (available_seats >= 0),
  price numeric(12,2) not null check (price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists route_schedules_search_idx
  on public.route_schedules (route_id, travel_date, departure_time)
  where is_active = true;

create table if not exists public.rental_packages (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id),
  vehicle_id uuid references public.vehicles(id),
  name text not null,
  package_type text not null,
  duration_days integer not null default 1 check (duration_days > 0),
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists rental_packages_city_idx
  on public.rental_packages (city_id)
  where is_active = true;

create table if not exists public.rental_package_prices (
  id uuid primary key default gen_random_uuid(),
  rental_package_id uuid not null references public.rental_packages(id) on delete cascade,
  price numeric(12,2) not null check (price >= 0),
  valid_from date not null default current_date,
  valid_until date,
  check (valid_until is null or valid_until >= valid_from)
);

create table if not exists public.tour_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  destination text,
  description text,
  image_path text,
  duration_days integer not null default 1 check (duration_days > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.tour_package_prices (
  id uuid primary key default gen_random_uuid(),
  tour_package_id uuid not null references public.tour_packages(id) on delete cascade,
  price numeric(12,2) not null check (price >= 0),
  valid_from date not null default current_date,
  valid_until date,
  check (valid_until is null or valid_until >= valid_from)
);

alter table public.users enable row level security;
alter table public.cities enable row level security;
alter table public.vehicles enable row level security;
alter table public.routes enable row level security;
alter table public.route_schedules enable row level security;
alter table public.rental_packages enable row level security;
alter table public.rental_package_prices enable row level security;
alter table public.tour_packages enable row level security;
alter table public.tour_package_prices enable row level security;

-- Catalog reads are opened only after the API/auth integration is configured.
-- Writes must be performed by protected Edge Functions/admin tooling.
