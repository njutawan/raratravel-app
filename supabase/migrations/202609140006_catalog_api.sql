-- ============================================================================
-- 202609140006_catalog_api.sql
-- Langkah 5 rencana migrasi: API katalog dengan pagination.
--
-- Isi:
--   * RLS baca-publik untuk katalog (harga & jadwal memang informasi publik),
--     tulis hanya lewat service_role / Edge Function admin.
--   * search_routes()      → pencarian rute + pagination + urutan + filter kursi
--   * get_route_detail()   → detail satu rute + jadwal
--   * list_rental_packages() / list_tour_packages() → sewa mobil & paket wisata
--   * catalog_cities()     → daftar kota untuk filter di aplikasi
--
-- Catatan desain: rute menyimpan pola jam harian (`departure_times`). Bila admin
-- belum membuat baris jadwal untuk tanggal tertentu, API tetap bisa menampilkan
-- jadwal dari pola tersebut ("jadwal virtual") dengan harga dasar rute. Begitu
-- pemesanan dibuat, `resolve_schedule` membuat baris jadwal nyata sehingga sisa
-- kursi terkunci di database.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RLS: katalog boleh dibaca publik (anon), hanya baris aktif.
-- ---------------------------------------------------------------------------
alter table public.cities enable row level security;
alter table public.routes enable row level security;
alter table public.route_schedules enable row level security;
alter table public.vehicles enable row level security;
alter table public.rental_packages enable row level security;
alter table public.rental_package_prices enable row level security;
alter table public.tour_packages enable row level security;
alter table public.tour_package_prices enable row level security;

drop policy if exists cities_public_read on public.cities;
create policy cities_public_read on public.cities
  for select to anon, authenticated using (is_active);

drop policy if exists routes_public_read on public.routes;
create policy routes_public_read on public.routes
  for select to anon, authenticated using (is_active);

drop policy if exists route_schedules_public_read on public.route_schedules;
create policy route_schedules_public_read on public.route_schedules
  for select to anon, authenticated
  using (is_active and travel_date >= current_date - 1);

drop policy if exists vehicles_public_read on public.vehicles;
create policy vehicles_public_read on public.vehicles
  for select to anon, authenticated using (is_active);

drop policy if exists rental_packages_public_read on public.rental_packages;
create policy rental_packages_public_read on public.rental_packages
  for select to anon, authenticated using (is_active);

drop policy if exists rental_prices_public_read on public.rental_package_prices;
create policy rental_prices_public_read on public.rental_package_prices
  for select to anon, authenticated using (true);

drop policy if exists tour_packages_public_read on public.tour_packages;
create policy tour_packages_public_read on public.tour_packages
  for select to anon, authenticated using (is_active);

drop policy if exists tour_prices_public_read on public.tour_package_prices;
create policy tour_prices_public_read on public.tour_package_prices
  for select to anon, authenticated using (true);

grant select on public.cities, public.routes, public.route_schedules, public.vehicles,
  public.rental_packages, public.rental_package_prices,
  public.tour_packages, public.tour_package_prices
  to anon, authenticated;

-- ===========================================================================
-- RPC: search_routes — inti layar "Cari Travel"
-- ===========================================================================
create or replace function public.search_routes(
  p_origin text default null,
  p_destination text default null,
  p_date date default null,
  p_passengers integer default 1,
  p_q text default null,
  p_sort text default 'popular',
  p_limit integer default 10,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_passengers integer := least(greatest(coalesce(p_passengers, 1), 1), 20);
  v_sort text := lower(coalesce(nullif(trim(coalesce(p_sort, '')), ''), 'popular'));
  v_date date := p_date;
  v_q text := nullif(trim(coalesce(p_q, '')), '');
  v_origin public.cities;
  v_destination public.cities;
  v_items jsonb;
  v_total integer;
begin
  if v_sort not in ('popular', 'price_asc', 'price_desc', 'duration_asc', 'departure') then
    v_sort := 'popular';
  end if;

  v_origin := public.resolve_city(p_origin);
  v_destination := public.resolve_city(p_destination);

  if nullif(trim(coalesce(p_origin, '')), '') is not null and v_origin.id is null then
    return jsonb_build_object('items', '[]'::jsonb, 'total', 0, 'limit', v_limit,
                              'offset', v_offset, 'has_more', false, 'reason', 'origin_not_found');
  end if;
  if nullif(trim(coalesce(p_destination, '')), '') is not null and v_destination.id is null then
    return jsonb_build_object('items', '[]'::jsonb, 'total', 0, 'limit', v_limit,
                              'offset', v_offset, 'has_more', false, 'reason', 'destination_not_found');
  end if;

  with dasar as (
    select r.id, r.slug, r.duration_minutes, r.description, r.via, r.facilities,
           r.vehicle_names, r.image_path, r.is_popular, r.sort_order, r.base_price,
           r.default_capacity, r.departure_times,
           oc.name as origin_name, dc.name as destination_name,
           v.name as vehicle_name, v.seat_capacity as vehicle_capacity
      from public.routes r
      join public.cities oc on oc.id = r.origin_city_id
      join public.cities dc on dc.id = r.destination_city_id
      left join public.vehicles v on v.id = r.vehicle_id
     where r.is_active
       and oc.is_active
       and dc.is_active
       and (v_origin.id is null or r.origin_city_id = v_origin.id)
       and (v_destination.id is null or r.destination_city_id = v_destination.id)
       and (v_q is null
            or r.description ilike '%' || v_q || '%'
            or r.via ilike '%' || v_q || '%'
            or oc.name ilike '%' || v_q || '%'
            or dc.name ilike '%' || v_q || '%')
  ),
  dijadwalkan as (
    select d.*, sch.schedules, sch.price_from, sch.jam_pertama
      from dasar d
      cross join lateral (
        select jsonb_agg(
                 jsonb_build_object(
                   'schedule_id', t.schedule_id,
                   'travel_date', to_char(t.travel_date, 'YYYY-MM-DD'),
                   'departure_time', to_char(t.departure_time, 'HH24:MI'),
                   'departure_time_label', replace(to_char(t.departure_time, 'HH24:MI'), ':', '.'),
                   'price', t.price,
                   'available_seats', t.available_seats,
                   'capacity', t.capacity,
                   'is_virtual', t.schedule_id is null
                 ) order by t.departure_time
               ) as schedules,
               min(t.price) as price_from,
               min(t.departure_time) as jam_pertama
          from (
            -- (1) jadwal nyata: pada tanggal yang dicari, atau (tanpa tanggal)
            --     satu jadwal terdekat per jam agar daftar tetap ringkas.
            select *
              from (
                select distinct on (n.departure_time)
                       n.schedule_id, n.travel_date, n.departure_time,
                       n.price, n.available_seats, n.capacity
                  from (
                    select s.id as schedule_id, s.travel_date, s.departure_time, s.price,
                           s.available_seats,
                           coalesce(s.capacity, d.default_capacity, 14) as capacity
                      from public.route_schedules s
                     where s.route_id = d.id
                       and s.is_active
                       and (
                         (v_date is not null and s.travel_date = v_date)
                         or (v_date is null and s.travel_date >= current_date)
                       )
                  ) n
                 order by n.departure_time, n.travel_date
              ) nyata
            union all
            -- (2) jadwal virtual dari pola jam rute (admin belum membuat
            --     baris jadwal untuk jam tersebut)
            select null,
                   coalesce(v_date, current_date),
                   public.parse_departure_time(dt),
                   coalesce(d.base_price, 0),
                   coalesce(d.default_capacity, 14),
                   coalesce(d.default_capacity, 14)
              from unnest(coalesce(d.departure_times, '{}'::text[])) as dt
             where public.parse_departure_time(dt) is not null
               and not exists (
                 select 1
                   from public.route_schedules s2
                  where s2.route_id = d.id
                    and s2.is_active
                    and s2.departure_time = public.parse_departure_time(dt)
                    and (
                      (v_date is not null and s2.travel_date = v_date)
                      or (v_date is null and s2.travel_date >= current_date)
                    )
               )
          ) t
         where t.available_seats >= v_passengers
      ) sch
     where sch.schedules is not null
  ),
  halaman as (
    select d.*,
           row_number() over (
             order by
               case v_sort when 'price_asc'  then d.price_from end asc nulls last,
               case v_sort when 'price_desc' then d.price_from end desc nulls last,
               case v_sort when 'duration_asc' then d.duration_minutes end asc nulls last,
               case v_sort when 'departure' then d.jam_pertama end asc nulls last,
               d.is_popular desc,
               d.sort_order asc,
               d.price_from asc
           ) as rn
      from dijadwalkan d
     order by
       case v_sort when 'price_asc'  then d.price_from end asc nulls last,
       case v_sort when 'price_desc' then d.price_from end desc nulls last,
       case v_sort when 'duration_asc' then d.duration_minutes end asc nulls last,
       case v_sort when 'departure' then d.jam_pertama end asc nulls last,
       d.is_popular desc,
       d.sort_order asc,
       d.price_from asc
     limit v_limit offset v_offset
  )
  select
    coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'route_id', h.id,
                 'slug', h.slug,
                 'origin', h.origin_name,
                 'destination', h.destination_name,
                 'title', h.origin_name || ' – ' || h.destination_name,
                 'price_from', h.price_from,
                 'duration_minutes', h.duration_minutes,
                 'via', h.via,
                 'description', h.description,
                 'image_path', h.image_path,
                 'is_popular', h.is_popular,
                 'facilities', to_jsonb(h.facilities),
                 'vehicle_names', to_jsonb(h.vehicle_names),
                 'vehicle_name', h.vehicle_name,
                 'capacity', coalesce(h.vehicle_capacity, h.default_capacity, 14),
                 'seats_left', (
                   select max((s->>'available_seats')::integer)
                     from jsonb_array_elements(h.schedules) s
                 ),
                 'schedules', h.schedules
               ) order by h.rn)
        from halaman h
    ), '[]'::jsonb),
    (select count(*)::integer from dijadwalkan)
    into v_items, v_total;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'total', coalesce(v_total, 0),
    'limit', v_limit,
    'offset', v_offset,
    'has_more', (v_offset + jsonb_array_length(coalesce(v_items, '[]'::jsonb))) < coalesce(v_total, 0),
    'query', jsonb_build_object(
      'origin', v_origin.name,
      'destination', v_destination.name,
      'date', case when v_date is null then null else to_char(v_date, 'YYYY-MM-DD') end,
      'passengers', v_passengers,
      'sort', v_sort
    )
  );
end;
$$;

-- ===========================================================================
-- RPC: get_route_detail — detail satu rute (layar Detail Rute)
-- ===========================================================================
create or replace function public.get_route_detail(
  p_key text,
  p_date date default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_route public.routes;
  v_result jsonb;
begin
  v_route := null;

  if public.try_uuid(p_key) is not null then
    select * into v_route from public.routes r where r.id = public.try_uuid(p_key);
  end if;
  if v_route.id is null then
    select * into v_route
      from public.routes r
     where r.slug = public.slugify(p_key)
     limit 1;
  end if;
  if v_route.id is null then
    -- Dukungan tautan lama: "surabaya-jakarta" → pasangan kota.
    select * into v_route
      from public.routes r
      join public.cities oc on oc.id = r.origin_city_id
      join public.cities dc on dc.id = r.destination_city_id
     where oc.name ilike '%' || split_part(p_key, '-', 1) || '%'
       and dc.name ilike '%' || split_part(p_key, '-', 2) || '%'
     limit 1;
  end if;

  if v_route.id is null then
    return null;
  end if;

  select jsonb_build_object(
           'route_id', r.id,
           'slug', r.slug,
           'origin', oc.name,
           'destination', dc.name,
           'title', oc.name || ' – ' || dc.name,
           'description', r.description,
           'via', r.via,
           'facilities', to_jsonb(r.facilities),
           'vehicle_names', to_jsonb(r.vehicle_names),
           'duration_minutes', r.duration_minutes,
           'base_price', r.base_price,
           'default_capacity', r.default_capacity,
           'departure_times', to_jsonb(r.departure_times),
           'image_path', r.image_path,
           'is_popular', r.is_popular,
           'schedules', coalesce(
             (select jsonb_agg(jsonb_build_object(
                       'schedule_id', s.id,
                       'travel_date', to_char(s.travel_date, 'YYYY-MM-DD'),
                       'departure_time', to_char(s.departure_time, 'HH24:MI'),
                       'departure_time_label', replace(to_char(s.departure_time, 'HH24:MI'), ':', '.'),
                       'price', s.price,
                       'available_seats', s.available_seats,
                       'capacity', coalesce(s.capacity, r.default_capacity)
                     ) order by s.travel_date, s.departure_time)
                from public.route_schedules s
               where s.route_id = r.id
                 and s.is_active
                 and (p_date is null or s.travel_date = p_date)
                 and (p_date is not null or s.travel_date >= current_date)),
             '[]'::jsonb)
         )
    into v_result
    from public.routes r
    join public.cities oc on oc.id = r.origin_city_id
    join public.cities dc on dc.id = r.destination_city_id
   where r.id = v_route.id;

  return v_result;
end;
$$;

-- ===========================================================================
-- RPC: catalog_cities — daftar kota aktif (dropdown asal/tujuan)
-- ===========================================================================
create or replace function public.catalog_cities(p_q text default null)
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'slug', c.slug, 'province', c.province
         ) order by c.sort_order, c.name), '[]'::jsonb)
    from public.cities c
   where c.is_active
     and (nullif(trim(coalesce(p_q, '')), '') is null
          or c.name ilike '%' || p_q || '%');
$$;

-- ===========================================================================
-- RPC: list_rental_packages — sewa mobil dengan pagination
-- ===========================================================================
create or replace function public.list_rental_packages(
  p_city text default null,
  p_q text default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_city public.cities := public.resolve_city(p_city);
  v_q text := nullif(trim(coalesce(p_q, '')), '');
  v_items jsonb;
  v_total integer;
begin
  with dasar as (
    select p.id, p.name, p.package_type, p.duration_days, p.description,
           p.image_path, c.name as city_name, v.name as vehicle_name,
           v.vehicle_type, v.seat_capacity,
           coalesce(
             (select min(pr.price)
                from public.rental_package_prices pr
               where pr.rental_package_id = p.id
                 and pr.valid_from <= current_date
                 and (pr.valid_until is null or pr.valid_until >= current_date)),
             0
           ) as price
      from public.rental_packages p
      join public.cities c on c.id = p.city_id
      left join public.vehicles v on v.id = p.vehicle_id
     where p.is_active
       and (v_city.id is null or p.city_id = v_city.id)
       and (v_q is null or p.name ilike '%' || v_q || '%' or p.description ilike '%' || v_q || '%')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'name', d.name, 'package_type', d.package_type,
           'duration_days', d.duration_days, 'description', d.description,
           'image_path', d.image_path, 'city', d.city_name,
           'vehicle_name', d.vehicle_name, 'vehicle_type', d.vehicle_type,
           'seat_capacity', d.seat_capacity, 'price_from', d.price
         ) order by d.price, d.name), '[]'::jsonb),
         (select count(*)::integer from dasar)
    into v_items, v_total
    from (select * from dasar order by price, name limit v_limit offset v_offset) d;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'total', coalesce(v_total, 0),
    'limit', v_limit,
    'offset', v_offset,
    'has_more', (v_offset + jsonb_array_length(coalesce(v_items, '[]'::jsonb))) < coalesce(v_total, 0)
  );
end;
$$;

-- ===========================================================================
-- RPC: list_tour_packages — paket wisata dengan pagination
-- ===========================================================================
create or replace function public.list_tour_packages(
  p_q text default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(trim(coalesce(p_q, '')), '');
  v_items jsonb;
  v_total integer;
begin
  with dasar as (
    select p.id, p.name, p.destination, p.description, p.image_path, p.duration_days,
           coalesce(
             (select min(pr.price)
                from public.tour_package_prices pr
               where pr.tour_package_id = p.id
                 and pr.valid_from <= current_date
                 and (pr.valid_until is null or pr.valid_until >= current_date)),
             0
           ) as price
      from public.tour_packages p
     where p.is_active
       and (v_q is null or p.name ilike '%' || v_q || '%'
            or p.destination ilike '%' || v_q || '%'
            or p.description ilike '%' || v_q || '%')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'name', d.name, 'destination', d.destination,
           'description', d.description, 'image_path', d.image_path,
           'duration_days', d.duration_days, 'price_from', d.price
         ) order by d.price, d.name), '[]'::jsonb),
         (select count(*)::integer from dasar)
    into v_items, v_total
    from (select * from dasar order by price, name limit v_limit offset v_offset) d;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'total', coalesce(v_total, 0),
    'limit', v_limit,
    'offset', v_offset,
    'has_more', (v_offset + jsonb_array_length(coalesce(v_items, '[]'::jsonb))) < coalesce(v_total, 0)
  );
end;
$$;

-- ===========================================================================
-- RPC: list_vehicles — armada (bagian "Armada" di beranda)
-- ===========================================================================
create or replace function public.list_vehicles()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'name', v.name, 'vehicle_type', v.vehicle_type,
           'seat_capacity', v.seat_capacity, 'image_path', v.image_path
         ) order by v.seat_capacity, v.name), '[]'::jsonb)
    from public.vehicles v
   where v.is_active;
$$;

-- ---------------------------------------------------------------------------
-- Hak eksekusi: RPC katalog boleh dipanggil anon (data publik) — kecuali
-- pencarian tetap dijaga parameter (read-only, tanpa data pribadi).
-- ---------------------------------------------------------------------------
grant execute on function public.search_routes(text, text, date, integer, text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_route_detail(text, date) to anon, authenticated;
grant execute on function public.catalog_cities(text) to anon, authenticated;
grant execute on function public.list_rental_packages(text, text, integer, integer) to anon, authenticated;
grant execute on function public.list_tour_packages(text, integer, integer) to anon, authenticated;
grant execute on function public.list_vehicles() to anon, authenticated;
