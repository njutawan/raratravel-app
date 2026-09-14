-- ============================================================================
-- 202609140002_catalog_schema.sql
-- Penyesuaian skema katalog agar siap dipakai API:
--   * `cities`         : slug + urutan tampil
--   * `routes`         : harga dasar, kapasitas default, gambar, slug, urutan
--   * `route_schedules`: kapasitas + jumlah kursi terpesan + kunci unik
--
-- Kolom harga/kapasitas di rute WAJIB ada karena server menghitung ulang total
-- pembayaran (lihat `create_booking` di migrasi berikutnya) — harga tidak lagi
-- boleh ditentukan aplikasi.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- cities
-- ---------------------------------------------------------------------------
alter table public.cities
  add column if not exists slug text,
  add column if not exists sort_order integer not null default 100,
  add column if not exists updated_at timestamptz not null default now();

-- Isi slug otomatis dari nama untuk baris lama (huruf kecil, spasi → '-').
update public.cities c
   set slug = trim(both '-' from regexp_replace(lower(c.name), '[^a-z0-9]+', '-', 'g'))
 where c.slug is null;

create unique index if not exists cities_slug_unique_idx
  on public.cities (slug)
  where slug is not null;

drop trigger if exists cities_set_updated_at on public.cities;
create trigger cities_set_updated_at
  before update on public.cities
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- routes
-- ---------------------------------------------------------------------------
alter table public.routes
  add column if not exists base_price numeric(12, 2)
    check (base_price is null or base_price >= 0),
  add column if not exists default_capacity integer not null default 14
    check (default_capacity > 0 and default_capacity <= 60),
  add column if not exists image_path text,
  add column if not exists slug text,
  add column if not exists sort_order integer not null default 100,
  add column if not exists is_popular boolean not null default false,
  -- Pola jam keberangkatan harian, mis. '{06.00,19.00}'. Dipakai `search_routes`
  -- untuk menampilkan jadwal walau admin belum membuat baris jadwal manual.
  add column if not exists departure_times text[] not null default '{}',
  add column if not exists via text,
  add column if not exists facilities text[] not null default '{}',
  add column if not exists vehicle_names text[] not null default '{}',
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists routes_slug_unique_idx
  on public.routes (slug)
  where slug is not null;

-- Satu pasangan kota hanya boleh punya satu rute aktif (mencegah harga ganda).
create unique index if not exists routes_pair_unique_idx
  on public.routes (origin_city_id, destination_city_id)
  where is_active = true;

-- Kunci alami: nama armada unik (dipakai impor katalog berulang).
create unique index if not exists vehicles_name_unique_idx
  on public.vehicles (lower(name));

drop trigger if exists routes_set_updated_at on public.routes;
create trigger routes_set_updated_at
  before update on public.routes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- rental_packages & tour_packages: kolom gambar untuk tampilan aplikasi
-- ---------------------------------------------------------------------------
alter table public.rental_packages
  add column if not exists image_path text,
  add column if not exists sort_order integer not null default 100,
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists rental_packages_set_updated_at on public.rental_packages;
create trigger rental_packages_set_updated_at
  before update on public.rental_packages
  for each row execute function public.set_updated_at();

alter table public.tour_packages
  add column if not exists sort_order integer not null default 100,
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists tour_packages_set_updated_at on public.tour_packages;
create trigger tour_packages_set_updated_at
  before update on public.tour_packages
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- route_schedules
--   available_seats tetap menjadi sumber kebenaran sisa kursi.
--   capacity          = total kursi armada pada jadwal tsb.
--   booked_seats      = jumlah kursi terjual (pending + confirmed).
--   Kunci unik (rute, tanggal, jam) membuat `insert ... on conflict` aman
--   sekaligus mencegah jadwal ganda saat dua permintaan datang bersamaan.
-- ---------------------------------------------------------------------------
alter table public.route_schedules
  add column if not exists capacity integer
    check (capacity is null or (capacity > 0 and capacity <= 60)),
  add column if not exists booked_seats integer not null default 0
    check (booked_seats >= 0),
  add column if not exists vehicle_id uuid references public.vehicles(id),
  add column if not exists updated_at timestamptz not null default now();

-- Rapikan baris lama: kapasitas = sisa kursi yang tercatat.
update public.route_schedules s
   set capacity = greatest(s.available_seats, 1)
 where s.capacity is null;

alter table public.route_schedules
  alter column capacity set default 14;

create unique index if not exists route_schedules_slot_unique_idx
  on public.route_schedules (route_id, travel_date, departure_time);

drop trigger if exists route_schedules_set_updated_at on public.route_schedules;
create trigger route_schedules_set_updated_at
  before update on public.route_schedules
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RPC: isi slug otomatis saat admin menambah kota/rute tanpa slug
-- ---------------------------------------------------------------------------
create or replace function public.slugify(p_text text)
returns text
language sql
immutable
as $$
  select trim(both '-' from regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g'));
$$;

-- ---------------------------------------------------------------------------
-- RPC: resolve_schedule — cari jadwal (rute, tanggal, jam) atau buat baru.
-- Dipakai `create_booking` supaya pengguna bisa memesan tanggal apa pun
-- tanpa admin membuat jadwal manual lebih dulu.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_schedule(
  p_route_id uuid,
  p_travel_date date,
  p_departure_time time
)
returns public.route_schedules
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_schedule public.route_schedules;
  v_capacity integer;
  v_price numeric(12, 2);
  v_vehicle uuid;
begin
  select * into v_schedule
    from public.route_schedules s
   where s.route_id = p_route_id
     and s.travel_date = p_travel_date
     and s.departure_time = p_departure_time
   limit 1;

  if v_schedule.id is not null then
    return v_schedule;
  end if;

  select coalesce(r.default_capacity, v.seat_capacity, 14), coalesce(r.base_price, 0), r.vehicle_id
    into v_capacity, v_price, v_vehicle
    from public.routes r
    left join public.vehicles v on v.id = r.vehicle_id
   where r.id = p_route_id;

  if v_capacity is null then
    perform public.raise_app_error('not_found', 'Rute tidak ditemukan');
  end if;

  insert into public.route_schedules (
    route_id, travel_date, departure_time, available_seats, price,
    capacity, booked_seats, vehicle_id, is_active
  )
  values (
    p_route_id, p_travel_date, p_departure_time, greatest(v_capacity, 1),
    coalesce(v_price, 0), greatest(v_capacity, 1), 0, v_vehicle, true
  )
  on conflict (route_id, travel_date, departure_time) do update
    set is_active = true,
        updated_at = now()
  returning * into v_schedule;

  return v_schedule;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: resolve_city — terima id, slug, atau nama kota (toleran huruf besar/kecil)
-- ---------------------------------------------------------------------------
create or replace function public.resolve_city(p_key text)
returns public.cities
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_city public.cities;
  v_key text;
  v_slug text;
  v_uuid uuid;
begin
  v_key := nullif(trim(coalesce(p_key, '')), '');
  if v_key is null then
    return v_city;
  end if;

  v_uuid := public.try_uuid(v_key);
  if v_uuid is not null then
    select * into v_city from public.cities c where c.id = v_uuid;
    if v_city.id is not null then
      return v_city;
    end if;
  end if;

  v_slug := public.slugify(v_key);

  select * into v_city
    from public.cities c
   where lower(c.name) = lower(v_key)
      or c.slug = v_slug
   order by c.is_active desc
   limit 1;

  if v_city.id is not null then
    return v_city;
  end if;

  -- Toleran terhadap tambahan di nama, mis. "Denpasar (Bali)" vs "Denpasar".
  select * into v_city
    from public.cities c
   where lower(c.name) like '%' || lower(v_key) || '%'
      or lower(v_key) like '%' || lower(c.name) || '%'
   order by length(c.name)
   limit 1;

  return v_city;
end;
$$;

revoke all on function public.resolve_schedule(uuid, date, time) from public;
revoke all on function public.resolve_city(text) from public;

-- ---------------------------------------------------------------------------
-- Kunci alami paket sewa & wisata (impor katalog berulang jadi idempoten)
-- ---------------------------------------------------------------------------
create unique index if not exists rental_packages_natural_key_idx
  on public.rental_packages (city_id, lower(name))
  where is_active = true;

create unique index if not exists tour_packages_natural_key_idx
  on public.tour_packages (lower(name))
  where is_active = true;

create index if not exists tour_packages_destination_idx
  on public.tour_packages (lower(destination))
  where is_active = true;
