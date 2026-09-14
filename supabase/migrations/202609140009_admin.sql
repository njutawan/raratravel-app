-- ============================================================================
-- 202609140009_admin.sql
-- Langkah 6 & 11 rencana migrasi:
--   * import_legacy_bookings() → pindahkan riwayat booking Firestore ke PostgreSQL
--   * admin_set_booking_status() → operator mengubah status pesanan
--   * admin_list_bookings() / admin_stats() → daftar & ringkasan untuk admin
--   * admin_import_catalog() → impor/ubah katalog massal (JSON dari admin)
--
-- Semua fungsi memverifikasi peran pemanggil di server (role diambil dari tabel
-- users, bukan dari kiriman aplikasi).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helper: pastikan pemanggil berperan admin/operator
-- ---------------------------------------------------------------------------
create or replace function public.require_staff(
  p_user_id uuid,
  p_roles text[] default array['operator', 'finance', 'admin', 'super_admin']
)
returns public.users
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_user public.users;
begin
  if p_user_id is null then
    perform public.raise_app_error('forbidden', 'Sesi tidak dikenali');
  end if;

  select * into v_user from public.users u where u.id = p_user_id and u.deleted_at is null;
  if v_user.id is null then
    perform public.raise_app_error('forbidden', 'Akun tidak ditemukan');
  end if;
  if not (v_user.role = any (p_roles)) then
    perform public.raise_app_error(
      'forbidden',
      'Akun ini tidak punya akses admin',
      jsonb_build_object('role', v_user.role, 'dibutuhkan', to_jsonb(p_roles))
    );
  end if;

  return v_user;
end;
$$;

-- ---------------------------------------------------------------------------
-- Helper: kota pada riwayat lama mungkin belum ada di katalog.
-- Dibuat baru, tapi rute historisnya TIDAK ditampilkan di pencarian.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_city(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_city public.cities;
  v_name text := nullif(trim(coalesce(p_name, '')), '');
begin
  if v_name is null then
    return null;
  end if;

  v_city := public.resolve_city(v_name);
  if v_city.id is not null then
    return v_city.id;
  end if;

  insert into public.cities (name, slug, is_active, sort_order)
  values (v_name, public.slugify(v_name), true, 900)
  on conflict (lower(name)) do update set name = excluded.name
  returning * into v_city;

  return v_city.id;
end;
$$;

-- ===========================================================================
-- RPC: import_legacy_bookings — migrasi data Firestore → PostgreSQL
--
-- p_batch: array dokumen booking gaya Firestore, contoh:
--   [{"kode":"RARA-9X2K7Q","userId":"<firebase uid>","asal":"Surabaya",
--     "tujuan":"Jakarta","tanggal":"2026-09-12","jam":"06.00","nama":"Budi",
--     "wa":"0812...","jemput":"...","antar":"...","kursi":2,
--     "totalHarga":850000,"metodeBayar":"Transfer Bank","catatan":"",
--     "status":"Menunggu Konfirmasi","createdAt":"2026-09-10T03:00:00.000Z",
--     "promo":"RARAHEMAT","diskon":50000}]
--
-- Sifat:
--   * Idempoten: kode yang sudah ada dilewati (tidak menimpa data baru).
--   * Kursi hanya dipotong untuk keberangkatan hari ini / ke depan.
--   * p_dry_run = true → hanya melaporkan, tidak menulis apa pun.
-- ===========================================================================
create or replace function public.import_legacy_bookings(
  p_batch jsonb,
  p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item jsonb;
  v_kode text;
  v_uid text;
  v_user public.users;
  v_booking public.bookings;
  v_schedule public.route_schedules;
  v_route_id uuid;
  v_origin uuid;
  v_destination uuid;
  v_seats integer;
  v_price numeric(12, 2);
  v_total numeric(12, 2);
  v_subtotal numeric(12, 2);
  v_discount numeric(12, 2);
  v_travel_date date;
  v_time time;
  v_status text;
  v_created timestamptz;
  v_inserted integer := 0;
  v_skipped integer := 0;
  v_failed integer := 0;
  v_errors jsonb := '[]'::jsonb;
begin
  if p_batch is null or jsonb_typeof(p_batch) <> 'array' then
    perform public.raise_app_error('validation_error', 'p_batch harus array dokumen booking');
  end if;

  for v_item in select jsonb_array_elements(p_batch) loop
    v_kode := upper(nullif(trim(coalesce(v_item->>'kode', v_item->>'kodeBooking', '')), ''));

    begin
      if v_kode is null then
        raise exception 'kode booking kosong';
      end if;

      if exists (select 1 from public.bookings b where b.kode = v_kode) then
        v_skipped := v_skipped + 1;
        continue;
      end if;

      -- 1) Pemilik: petakan firebase uid → users.id (buat akun placeholder bila perlu)
      v_uid := nullif(trim(coalesce(v_item->>'userId', v_item->>'uid', '')), '');
      v_user := null;
      if v_uid is not null then
        select * into v_user from public.users u where u.firebase_uid = v_uid;
        if v_user.id is null and not p_dry_run then
          insert into public.users (firebase_uid, full_name, phone, metadata)
          values (
            v_uid,
            nullif(trim(coalesce(v_item->>'nama', '')), ''),
            public.normalize_phone(v_item->>'wa'),
            jsonb_build_object('imported_from', 'firestore')
          )
          on conflict (firebase_uid) do update set firebase_uid = excluded.firebase_uid
          returning * into v_user;
        end if;
      end if;

      if v_user.id is null and not p_dry_run then
        raise exception 'pemilik pesanan tidak bisa dipetakan (uid: %)', coalesce(v_uid, 'kosong');
      end if;

      -- 2) Nilai dasar
      v_seats := greatest(coalesce(public.try_int(v_item->>'kursi'), 1), 1);
      v_total := coalesce(public.try_numeric(coalesce(v_item->>'totalHarga', v_item->>'total')), 0);
      v_discount := greatest(coalesce(public.try_numeric(v_item->>'diskon'), 0), 0);
      v_subtotal := v_total + v_discount;
      v_price := case when v_seats > 0 then round(v_subtotal / v_seats, 2) else v_subtotal end;
      v_travel_date := coalesce(
        public.try_date(v_item->>'tanggal'),
        public.try_date(v_item->>'travel_date'),
        current_date);
      v_time := coalesce(
        public.parse_departure_time(v_item->>'jam'),
        public.parse_departure_time(v_item->>'departure_time'),
        '06:00'::time);
      v_status := public.booking_status_code(v_item->>'status');
      v_created := coalesce(public.try_timestamptz(v_item->>'createdAt'), now());

      -- 3) Kota & rute historis (is_active = false → tidak tampil di pencarian,
      --    tapi riwayat pengguna tetap utuh dan bisa dibaca admin).
      v_origin := public.ensure_city(coalesce(v_item->>'asal', v_item->>'origin'));
      v_destination := public.ensure_city(coalesce(v_item->>'tujuan', v_item->>'destination'));

      v_route_id := null;
      if v_origin is not null and v_destination is not null and v_origin <> v_destination then
        select r.id into v_route_id
          from public.routes r
         where r.origin_city_id = v_origin and r.destination_city_id = v_destination
         order by r.is_active desc
         limit 1;

        if v_route_id is null and not p_dry_run then
          insert into public.routes (
            origin_city_id, destination_city_id, base_price, default_capacity,
            is_active, description
          )
          values (
            v_origin, v_destination, v_price, greatest(v_seats, 14), false,
            'Rute historis dari impor Firestore (tidak tampil di pencarian).'
          )
          returning id into v_route_id;
        end if;
      end if;

      if p_dry_run then
        v_inserted := v_inserted + 1;
        continue;
      end if;

      -- 4) Jadwal: hanya untuk keberangkatan hari ini/ke depan supaya sisa
      --    kursi ikut terpotong dengan benar.
      v_schedule := null;
      if v_route_id is not null and v_travel_date >= current_date then
        v_schedule := public.resolve_schedule(v_route_id, v_travel_date, v_time);
        if v_schedule.available_seats < v_seats then
          update public.route_schedules s
             set available_seats = greatest(s.available_seats, 0),
                 capacity = greatest(s.capacity, s.booked_seats + v_seats)
           where s.id = v_schedule.id
          returning * into v_schedule;
        end if;
        if v_status in ('pending', 'confirmed') then
          update public.route_schedules s
             set available_seats = s.available_seats - v_seats,
                 booked_seats = s.booked_seats + v_seats
           where s.id = v_schedule.id
          returning * into v_schedule;
        end if;
      end if;

      perform set_config('app.actor_role', 'import', true);
      perform set_config('app.actor_note', 'impor riwayat dari Firestore', true);
      perform set_config('app.actor_user_id', v_user.id::text, true);

      insert into public.bookings (
        kode, user_id, service_type, status,
        route_id, schedule_id, origin_city_id, destination_city_id,
        origin_name, destination_name, travel_date, departure_time,
        seats, price_per_seat, subtotal, discount, total, promo_code,
        payment_method, payment_status,
        contact_name, contact_phone, pickup_address, dropoff_address, notes,
        source, idempotency_key, metadata, created_at
      )
      values (
        v_kode, v_user.id, 'travel', v_status,
        v_route_id, v_schedule.id, v_origin, v_destination,
        coalesce((select c.name from public.cities c where c.id = v_origin), coalesce(v_item->>'asal', '-')),
        coalesce((select c.name from public.cities c where c.id = v_destination), coalesce(v_item->>'tujuan', '-')),
        v_travel_date, v_time,
        v_seats, v_price, v_subtotal, v_discount, v_total,
        nullif(upper(trim(coalesce(v_item->>'promo', ''))), ''),
        nullif(trim(coalesce(v_item->>'metodeBayar', v_item->>'payment_method', '')), ''),
        case when v_status = 'confirmed' then 'paid' else 'unpaid' end,
        coalesce(nullif(trim(coalesce(v_item->>'nama', '')), ''), 'Pelanggan'),
        coalesce(public.normalize_phone(v_item->>'wa'), '+62'),
        nullif(trim(coalesce(v_item->>'jemput', v_item->>'pickup_address', '')), ''),
        nullif(trim(coalesce(v_item->>'antar', v_item->>'dropoff_address', '')), ''),
        nullif(trim(coalesce(v_item->>'catatan', '')), ''),
        'import',
        'legacy:' || v_kode,
        jsonb_build_object('imported_from', 'firestore', 'raw', v_item - 'userId'),
        v_created
      )
      returning * into v_booking;

      v_inserted := v_inserted + 1;
    exception when others then
      v_failed := v_failed + 1;
      v_errors := v_errors || jsonb_build_object(
        'kode', coalesce(v_kode, '-'),
        'error', left(sqlerrm, 300)
      );
    end;
  end loop;

  return jsonb_build_object(
    'dry_run', coalesce(p_dry_run, false),
    'total', jsonb_array_length(p_batch),
    'inserted', v_inserted,
    'skipped', v_skipped,
    'failed', v_failed,
    'errors', v_errors
  );
end;
$$;

-- ===========================================================================
-- RPC: admin_set_booking_status — ubah status + kelola kursi
-- ===========================================================================
create or replace function public.admin_set_booking_status(
  p_admin_user_id uuid,
  p_kode text,
  p_status text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin public.users;
  v_booking public.bookings;
  v_status text := public.booking_status_code(p_status);
  v_schedule public.route_schedules;
  v_bebas boolean := false;
begin
  v_admin := public.require_staff(p_admin_user_id);

  select * into v_booking
    from public.bookings b
   where b.kode = upper(trim(coalesce(p_kode, '')))
     for update;

  if v_booking.id is null then
    perform public.raise_app_error('not_found', 'Pesanan tidak ditemukan', jsonb_build_object('kode', p_kode));
  end if;
  if v_booking.status = v_status then
    return jsonb_build_object('booking', public.booking_json(v_booking), 'changed', false);
  end if;
  if v_booking.status in ('completed', 'cancelled', 'expired')
     and v_status = 'pending' then
    perform public.raise_app_error(
      'conflict',
      'Pesanan yang sudah selesai/dibatalkan tidak bisa dikembalikan ke menunggu',
      jsonb_build_object('status', v_booking.status)
    );
  end if;

  perform set_config('app.actor_user_id', v_admin.id::text, true);
  perform set_config('app.actor_role', v_admin.role, true);
  perform set_config('app.actor_note', coalesce(nullif(trim(coalesce(p_note, '')), ''), 'diubah admin'), true);

  -- Kursi dilepas bila pesanan dihentikan (kursi hanya boleh dipegang
  -- pesanan yang masih berjalan).
  v_bebas := (v_status in ('cancelled', 'expired') and v_booking.status in ('pending', 'confirmed'));

  update public.bookings b
     set status = v_status,
         confirmed_at = case when v_status = 'confirmed' and b.confirmed_at is null then now() else b.confirmed_at end,
         cancelled_at = case when v_status = 'cancelled' then now() else b.cancelled_at end,
         cancelled_reason = case when v_status = 'cancelled'
                                 then coalesce(nullif(trim(coalesce(p_note, '')), ''), b.cancelled_reason) else b.cancelled_reason end,
         completed_at = case when v_status = 'completed' then now() else b.completed_at end
   where b.id = v_booking.id
  returning * into v_booking;

  if v_bebas and v_booking.schedule_id is not null then
    select * into v_schedule from public.route_schedules s where s.id = v_booking.schedule_id for update;
    if v_schedule.id is not null then
      update public.route_schedules s
         set available_seats = least(s.available_seats + v_booking.seats, coalesce(s.capacity, s.available_seats + v_booking.seats)),
             booked_seats = greatest(s.booked_seats - v_booking.seats, 0)
       where s.id = v_schedule.id;
    end if;
    update public.booking_seats bs
       set is_active = false
     where bs.booking_id = v_booking.id and bs.is_active;
  end if;

  return jsonb_build_object(
    'booking', public.booking_json(v_booking),
    'changed', true,
    'released_seats', case when v_bebas then v_booking.seats else 0 end
  );
end;
$$;

-- ===========================================================================
-- RPC: admin_list_bookings — daftar pesanan untuk operator
-- ===========================================================================
create or replace function public.admin_list_bookings(
  p_admin_user_id uuid,
  p_status text default null,
  p_q text default null,
  p_date date default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_status text := nullif(lower(trim(coalesce(p_status, ''))), '');
  v_q text := nullif(trim(coalesce(p_q, '')), '');
  v_items jsonb;
  v_total integer;
begin
  perform public.require_staff(p_admin_user_id);

  if v_status is not null then
    v_status := public.booking_status_code(v_status);
  end if;

  with dasar as (
    select b.*
      from public.bookings b
     where (v_status is null or b.status = v_status)
       and (p_date is null or b.travel_date = p_date)
       and (v_q is null
            or b.kode ilike '%' || v_q || '%'
            or b.contact_name ilike '%' || v_q || '%'
            or b.contact_phone ilike '%' || v_q || '%')
  )
  select coalesce(jsonb_agg(public.booking_json(d) order by d.created_at desc), '[]'::jsonb),
         (select count(*)::integer from dasar)
    into v_items, v_total
    from (select * from dasar order by created_at desc limit v_limit offset v_offset) d;

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
-- RPC: admin_stats — ringkasan untuk dasbor admin
-- ===========================================================================
create or replace function public.admin_stats(p_admin_user_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_hasil jsonb;
begin
  perform public.require_staff(p_admin_user_id);

  select jsonb_build_object(
    'bookings_total', count(*),
    'bookings_pending', count(*) filter (where status = 'pending'),
    'bookings_confirmed', count(*) filter (where status = 'confirmed'),
    'bookings_cancelled', count(*) filter (where status in ('cancelled', 'expired')),
    'bookings_today', count(*) filter (where travel_date = current_date),
    'seats_today', coalesce(sum(seats) filter (where travel_date = current_date and status in ('pending', 'confirmed')), 0),
    'revenue_paid', coalesce(sum(total) filter (where payment_status in ('paid', 'partial')), 0),
    'revenue_pending', coalesce(sum(total) filter (where status in ('pending', 'confirmed') and payment_status not in ('paid', 'refunded')), 0),
    'users_total', (select count(*) from public.users u where u.deleted_at is null),
    'devices_active', (select count(*) from public.user_devices d where d.is_active)
  )
  into v_hasil
  from public.bookings;

  return v_hasil || jsonb_build_object(
    'notifications', public.notification_queue_summary(),
    'generated_at', now()
  );
end;
$$;

-- ===========================================================================
-- RPC: admin_import_catalog — impor/ubah katalog massal dari JSON admin
--
-- Contoh payload:
--   {"cities":[{"name":"Surabaya"}],
--    "vehicles":[{"name":"Hiace","seat_capacity":12,"vehicle_type":"Van"}],
--    "routes":[{"origin":"Surabaya","destination":"Jakarta","base_price":450000,
--               "departure_times":["06.00","19.00"],"duration_minutes":660}],
--    "schedules":[{"route_slug":"surabaya-jakarta","travel_date":"2026-10-01",
--                  "departure_time":"06.00","price":450000,"capacity":14}],
--    "rental_packages":[{"city":"Jember","name":"Hiace + Sopir 12 jam","price":1400000}],
--    "tour_packages":[{"name":"Bromo Sunrise","destination":"Gunung Bromo",
--                      "price":350000,"duration_days":1}]}
-- ===========================================================================
create or replace function public.admin_import_catalog(
  p_admin_user_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin public.users;
  v_item jsonb;
  v_city_id uuid;
  v_vehicle_id uuid;
  v_route public.routes;
  v_package_id uuid;
  v_counts jsonb := jsonb_build_object(
    'cities', 0, 'vehicles', 0, 'routes', 0,
    'schedules', 0, 'rental_packages', 0, 'tour_packages', 0
  );
begin
  v_admin := public.require_staff(p_admin_user_id, array['admin', 'super_admin']);

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform public.raise_app_error('validation_error', 'Payload impor harus objek JSON');
  end if;

  perform set_config('app.actor_user_id', v_admin.id::text, true);
  perform set_config('app.actor_role', v_admin.role, true);

  -- ---------------- Kota ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'cities', '[]'::jsonb)) loop
    insert into public.cities (name, province, slug, sort_order, is_active)
    values (
      trim(v_item->>'name'),
      nullif(trim(coalesce(v_item->>'province', '')), ''),
      coalesce(nullif(trim(coalesce(v_item->>'slug', '')), ''), public.slugify(v_item->>'name')),
      coalesce(public.try_int(v_item->>'sort_order'), 100),
      coalesce((v_item->>'is_active')::boolean, true)
    )
    on conflict (lower(name)) do update
      set province = coalesce(excluded.province, public.cities.province),
          slug = coalesce(excluded.slug, public.cities.slug),
          sort_order = excluded.sort_order,
          is_active = excluded.is_active;
    v_counts := jsonb_set(v_counts, '{cities}', to_jsonb((v_counts->>'cities')::integer + 1));
  end loop;

  -- ---------------- Armada ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'vehicles', '[]'::jsonb)) loop
    insert into public.vehicles (name, vehicle_type, seat_capacity, image_path, is_active)
    values (
      trim(v_item->>'name'),
      nullif(trim(coalesce(v_item->>'vehicle_type', '')), ''),
      greatest(coalesce(public.try_int(v_item->>'seat_capacity'), 1), 1),
      nullif(trim(coalesce(v_item->>'image_path', '')), ''),
      coalesce((v_item->>'is_active')::boolean, true)
    )
    on conflict (lower(name)) do update
      set vehicle_type = coalesce(excluded.vehicle_type, public.vehicles.vehicle_type),
          seat_capacity = excluded.seat_capacity,
          image_path = coalesce(excluded.image_path, public.vehicles.image_path),
          is_active = excluded.is_active;
    v_counts := jsonb_set(v_counts, '{vehicles}', to_jsonb((v_counts->>'vehicles')::integer + 1));
  end loop;

  -- ---------------- Rute ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'routes', '[]'::jsonb)) loop
    v_city_id := public.ensure_city(coalesce(v_item->>'origin', v_item->>'asal'));
    v_vehicle_id := null;
    if nullif(trim(coalesce(v_item->>'vehicle', '')), '') is not null then
      select v.id into v_vehicle_id from public.vehicles v
       where lower(v.name) = lower(trim(v_item->>'vehicle')) limit 1;
    end if;

    if v_city_id is null then
      v_counts := jsonb_set(v_counts, '{routes}', to_jsonb((v_counts->>'routes')::integer + 0));
      continue;
    end if;

    select * into v_route
      from public.routes r
     where r.origin_city_id = v_city_id
       and r.destination_city_id = public.ensure_city(coalesce(v_item->>'destination', v_item->>'tujuan'))
       and r.is_active
     limit 1;

    if v_route.id is null and v_item->>'destination' is not null then
      insert into public.routes (
        origin_city_id, destination_city_id, vehicle_id, base_price, default_capacity,
        duration_minutes, via, departure_times, description, image_path, is_active
      )
      values (
        v_city_id,
        public.ensure_city(coalesce(v_item->>'destination', v_item->>'tujuan')),
        v_vehicle_id,
        coalesce(public.try_numeric(v_item->>'base_price'), 0),
        greatest(coalesce(public.try_int(v_item->>'default_capacity'), 14), 1),
        public.try_int(v_item->>'duration_minutes'),
        nullif(trim(coalesce(v_item->>'via', '')), ''),
        coalesce(
          (select array_agg(value) from jsonb_array_elements_text(coalesce(v_item->'departure_times', '[]'::jsonb)) as value),
          '{}'::text[]
        ),
        nullif(trim(coalesce(v_item->>'description', '')), ''),
        nullif(trim(coalesce(v_item->>'image_path', '')), ''),
        coalesce((v_item->>'is_active')::boolean, true)
      )
      returning * into v_route;
    elsif v_route.id is not null then
      update public.routes r
         set vehicle_id = coalesce(v_vehicle_id, r.vehicle_id),
             base_price = coalesce(public.try_numeric(v_item->>'base_price'), r.base_price),
             default_capacity = coalesce(public.try_int(v_item->>'default_capacity'), r.default_capacity),
             duration_minutes = coalesce(public.try_int(v_item->>'duration_minutes'), r.duration_minutes),
             via = coalesce(nullif(trim(coalesce(v_item->>'via', '')), ''), r.via),
             departure_times = case
               when jsonb_typeof(v_item->'departure_times') = 'array'
                 then (select array_agg(value) from jsonb_array_elements_text(v_item->'departure_times') as value)
               else r.departure_times end,
             description = coalesce(nullif(trim(coalesce(v_item->>'description', '')), ''), r.description),
             image_path = coalesce(nullif(trim(coalesce(v_item->>'image_path', '')), ''), r.image_path),
             is_active = coalesce((v_item->>'is_active')::boolean, r.is_active)
       where r.id = v_route.id
      returning * into v_route;
    end if;

    if v_route.id is not null then
      v_counts := jsonb_set(v_counts, '{routes}', to_jsonb((v_counts->>'routes')::integer + 1));
    end if;
  end loop;

  -- ---------------- Jadwal ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'schedules', '[]'::jsonb)) loop
    v_route := null;
    if nullif(trim(coalesce(v_item->>'route_slug', '')), '') is not null then
      select * into v_route from public.routes r where r.slug = public.slugify(v_item->>'route_slug') limit 1;
    end if;
    if v_route.id is null and v_item->>'origin' is not null then
      select * into v_route
        from public.routes r
       where r.origin_city_id = public.ensure_city(v_item->>'origin')
         and r.destination_city_id = public.ensure_city(v_item->>'destination')
       limit 1;
    end if;
    if v_route.id is null then
      continue;
    end if;

    insert into public.route_schedules (
      route_id, travel_date, departure_time, price, capacity, available_seats, is_active
    )
    values (
      v_route.id,
      coalesce(public.try_date(v_item->>'travel_date'), current_date),
      coalesce(public.parse_departure_time(v_item->>'departure_time'), '06:00'::time),
      coalesce(public.try_numeric(v_item->>'price'), v_route.base_price, 0),
      greatest(coalesce(public.try_int(v_item->>'capacity'), v_route.default_capacity), 1),
      greatest(coalesce(public.try_int(v_item->>'available_seats'),
                       coalesce(public.try_int(v_item->>'capacity'), v_route.default_capacity)), 0),
      coalesce((v_item->>'is_active')::boolean, true)
    )
    on conflict (route_id, travel_date, departure_time) do update
      set price = excluded.price,
          capacity = excluded.capacity,
          available_seats = least(excluded.available_seats, excluded.capacity),
          is_active = excluded.is_active;
    v_counts := jsonb_set(v_counts, '{schedules}', to_jsonb((v_counts->>'schedules')::integer + 1));
  end loop;

  -- ---------------- Sewa mobil ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'rental_packages', '[]'::jsonb)) loop
    v_city_id := public.ensure_city(coalesce(v_item->>'city', 'Jember'));
    v_vehicle_id := null;
    if nullif(trim(coalesce(v_item->>'vehicle', '')), '') is not null then
      select v.id into v_vehicle_id from public.vehicles v
       where lower(v.name) = lower(trim(v_item->>'vehicle')) limit 1;
    end if;
    if v_city_id is null then
      continue;
    end if;

    insert into public.rental_packages (
      city_id, vehicle_id, name, package_type, duration_days, description, image_path, is_active
    )
    values (
      v_city_id, v_vehicle_id, trim(v_item->>'name'),
      coalesce(nullif(trim(coalesce(v_item->>'package_type', '')), ''), 'Sewa + Sopir'),
      greatest(coalesce(public.try_int(v_item->>'duration_days'), 1), 1),
      nullif(trim(coalesce(v_item->>'description', '')), ''),
      nullif(trim(coalesce(v_item->>'image_path', '')), ''),
      coalesce((v_item->>'is_active')::boolean, true)
    )
    on conflict (city_id, lower(name)) where is_active do update
      set vehicle_id = coalesce(excluded.vehicle_id, public.rental_packages.vehicle_id),
          package_type = excluded.package_type,
          duration_days = excluded.duration_days,
          description = coalesce(excluded.description, public.rental_packages.description),
          image_path = coalesce(excluded.image_path, public.rental_packages.image_path)
    returning id into v_package_id;

    if v_package_id is not null and public.try_numeric(v_item->>'price') is not null then
      if not exists (
        select 1 from public.rental_package_prices pr
         where pr.rental_package_id = v_package_id and pr.valid_from = current_date
      ) then
        insert into public.rental_package_prices (rental_package_id, price, valid_from)
        values (v_package_id, public.try_numeric(v_item->>'price'), current_date);
      else
        update public.rental_package_prices pr
           set price = public.try_numeric(v_item->>'price')
         where pr.rental_package_id = v_package_id and pr.valid_from = current_date;
      end if;
    end if;
    v_counts := jsonb_set(v_counts, '{rental_packages}', to_jsonb((v_counts->>'rental_packages')::integer + 1));
  end loop;

  -- ---------------- Paket wisata ----------------
  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'tour_packages', '[]'::jsonb)) loop
    insert into public.tour_packages (
      name, destination, description, image_path, duration_days, is_active
    )
    values (
      trim(v_item->>'name'),
      nullif(trim(coalesce(v_item->>'destination', '')), ''),
      nullif(trim(coalesce(v_item->>'description', '')), ''),
      nullif(trim(coalesce(v_item->>'image_path', '')), ''),
      greatest(coalesce(public.try_int(v_item->>'duration_days'), 1), 1),
      coalesce((v_item->>'is_active')::boolean, true)
    )
    on conflict (lower(name)) where is_active do update
      set destination = coalesce(excluded.destination, public.tour_packages.destination),
          description = coalesce(excluded.description, public.tour_packages.description),
          image_path = coalesce(excluded.image_path, public.tour_packages.image_path),
          duration_days = excluded.duration_days
    returning id into v_package_id;

    if v_package_id is not null and public.try_numeric(v_item->>'price') is not null then
      if not exists (
        select 1 from public.tour_package_prices pr
         where pr.tour_package_id = v_package_id and pr.valid_from = current_date
      ) then
        insert into public.tour_package_prices (tour_package_id, price, valid_from)
        values (v_package_id, public.try_numeric(v_item->>'price'), current_date);
      else
        update public.tour_package_prices pr
           set price = public.try_numeric(v_item->>'price')
         where pr.tour_package_id = v_package_id and pr.valid_from = current_date;
      end if;
    end if;
    v_counts := jsonb_set(v_counts, '{tour_packages}', to_jsonb((v_counts->>'tour_packages')::integer + 1));
  end loop;

  return jsonb_build_object('ok', true, 'counts', v_counts);
end;
$$;

-- ---------------------------------------------------------------------------
-- Keamanan: fungsi admin hanya untuk service_role (Edge Function memeriksa
-- Firebase token lalu memanggilnya dengan identitas pengguna yang sah).
-- ---------------------------------------------------------------------------
revoke all on function public.import_legacy_bookings(jsonb, boolean) from public;
revoke all on function public.admin_set_booking_status(uuid, text, text, text) from public;
revoke all on function public.admin_list_bookings(uuid, text, text, date, integer, integer) from public;
revoke all on function public.admin_stats(uuid) from public;
revoke all on function public.admin_import_catalog(uuid, jsonb) from public;
revoke all on function public.require_staff(uuid, text[]) from public;
revoke all on function public.ensure_city(text) from public;

-- ---------------------------------------------------------------------------
-- RPC: staff_role — kembalikan peran bila pemanggil memang staf, else null.
-- Dipakai Edge Function untuk menggerbangi aksi yang tidak lewat RPC admin
-- (mis. menandai pembayaran transfer manual sudah diterima).
-- ---------------------------------------------------------------------------
create or replace function public.staff_role(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select u.role
    from public.users u
   where u.id = p_user_id
     and u.deleted_at is null
     and u.role in ('operator', 'finance', 'admin', 'super_admin');
$$;

revoke all on function public.staff_role(uuid) from public;

-- ---------------------------------------------------------------------------
-- RPC: admin_create_payment — staf membuat tagihan untuk pesanan pelanggan
-- (mis. mencatat transfer manual yang sudah masuk). Memakai ulang
-- `create_payment` supaya aturan nominal/sisa tagihan tetap satu sumber.
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_payment(
  p_admin_user_id uuid,
  p_kode text,
  p_provider text default 'manual',
  p_method text default null,
  p_amount numeric default null,
  p_provider_reference text default null,
  p_checkout_url text default null,
  p_expires_at timestamptz default null,
  p_raw_response jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin public.users;
  v_owner uuid;
begin
  v_admin := public.require_staff(p_admin_user_id, array['operator', 'finance', 'admin', 'super_admin']);

  select b.user_id into v_owner
    from public.bookings b
   where b.kode = upper(trim(coalesce(p_kode, '')));

  if v_owner is null then
    perform public.raise_app_error('not_found', 'Pesanan tidak ditemukan', jsonb_build_object('kode', p_kode));
  end if;

  perform set_config('app.actor_user_id', v_admin.id::text, true);
  perform set_config('app.actor_role', v_admin.role, true);
  perform set_config('app.actor_note', 'tagihan dibuat staf', true);

  return public.create_payment(
    v_owner,
    p_kode,
    coalesce(nullif(trim(coalesce(p_provider, '')), ''), 'manual'),
    p_method,
    p_amount,
    p_provider_reference,
    p_checkout_url,
    p_expires_at,
    coalesce(p_raw_response, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.admin_create_payment(uuid, text, text, text, numeric, text, text, timestamptz, jsonb) from public;
