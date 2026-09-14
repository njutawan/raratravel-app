-- ============================================================================
-- 202609140003_bookings.sql
-- Langkah 6 & 7 rencana migrasi: booking pindah dari Firestore ke PostgreSQL.
--
-- Prinsip:
--   * Harga & ketersediaan kursi dihitung/diverifikasi SERVER, bukan aplikasi.
--     Aplikasi hanya mengirim pilihan; total dihitung ulang di sini.
--   * `create_booking` berjalan dalam satu transaksi:
--       idempotency check → validasi → kunci jadwal (FOR UPDATE) → cek kursi
--       → hitung harga + promo → simpan booking + kursi → potong sisa kursi.
--     Bila ada satu langkah gagal, seluruh transaksi dibatalkan (tidak ada
--     kursi "terpotong" tanpa booking).
--   * Idempotency key per pengguna membuat ulang permintaan (jaringan putus,
--     tombol ditekan dua kali) tidak menghasilkan booking ganda.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tabel promo (pengganti konstanta promoCodes di aplikasi)
-- ---------------------------------------------------------------------------
create table if not exists public.promo_codes (
  code text primary key,
  description text,
  percent integer not null check (percent > 0 and percent <= 100),
  max_discount numeric(12, 2)
    check (max_discount is null or max_discount >= 0),
  min_spend numeric(12, 2) not null default 0 check (min_spend >= 0),
  valid_from date,
  valid_until date,
  max_uses integer check (max_uses is null or max_uses > 0),
  used_count integer not null default 0 check (used_count >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until is null or valid_from is null or valid_until >= valid_from)
);

drop trigger if exists promo_codes_set_updated_at on public.promo_codes;
create trigger promo_codes_set_updated_at
  before update on public.promo_codes
  for each row execute function public.set_updated_at();

-- Promo yang sudah dipakai aplikasi sejak awal (10%, maksimal Rp50.000).
insert into public.promo_codes (code, description, percent, max_discount, is_active)
values ('RARAHEMAT', 'Promo hemat 10% (maks Rp50.000)', 10, 50000, true)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Tabel bookings
-- ---------------------------------------------------------------------------
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  kode text not null unique,
  user_id uuid not null references public.users(id) on delete cascade,
  service_type text not null default 'travel'
    check (service_type in ('travel', 'rental', 'tour', 'cargo')),
  status text not null default 'pending'
    constraint bookings_status_check
    check (status in ('pending', 'confirmed', 'completed', 'cancelled', 'expired')),

  -- Relasi katalog (disimpan sebagai snapshot nama juga, agar riwayat tetap
  -- terbaca walau nama kota/rute diubah admin di kemudian hari).
  route_id uuid references public.routes(id) on delete set null,
  schedule_id uuid references public.route_schedules(id) on delete set null,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  origin_city_id uuid references public.cities(id) on delete set null,
  destination_city_id uuid references public.cities(id) on delete set null,
  origin_name text not null,
  destination_name text not null,
  travel_date date not null,
  departure_time time,

  -- Uang: seluruh nilai dihitung server (lihat create_booking).
  seats integer not null check (seats > 0 and seats <= 20),
  price_per_seat numeric(12, 2) not null check (price_per_seat >= 0),
  subtotal numeric(12, 2) not null check (subtotal >= 0),
  discount numeric(12, 2) not null default 0 check (discount >= 0),
  total numeric(12, 2) not null check (total >= 0),
  currency text not null default 'IDR' check (char_length(currency) = 3),
  promo_code text references public.promo_codes(code) on delete set null,
  payment_method text,
  payment_status text not null default 'unpaid'
    constraint bookings_payment_status_check
    check (payment_status in ('unpaid', 'pending', 'partial', 'paid', 'failed', 'expired', 'refunded')),

  -- Kontak & lokasi jemput-antar (door-to-door).
  contact_name text not null,
  contact_phone text not null,
  contact_email text,
  pickup_address text,
  dropoff_address text,
  notes text,

  -- Operasional
  source text not null default 'app'
    check (source in ('app', 'admin', 'wa', 'import', 'webhook')),
  idempotency_key text,
  expires_at timestamptz,
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_reason text,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists bookings_idempotency_unique_idx
  on public.bookings (user_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists bookings_user_created_idx
  on public.bookings (user_id, created_at desc);

create index if not exists bookings_status_idx
  on public.bookings (status, travel_date);

create index if not exists bookings_travel_date_idx
  on public.bookings (travel_date, departure_time);

create index if not exists bookings_schedule_idx
  on public.bookings (schedule_id)
  where schedule_id is not null;

drop trigger if exists bookings_set_updated_at on public.bookings;
create trigger bookings_set_updated_at
  before update on public.bookings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Nomor kursi per booking (opsional, tapi mencegah dua orang dapat kursi sama)
-- ---------------------------------------------------------------------------
create table if not exists public.booking_seats (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  schedule_id uuid references public.route_schedules(id) on delete set null,
  travel_date date not null,
  seat_no integer not null check (seat_no > 0),
  seat_label text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Kursi yang dibatalkan (is_active = false) otomatis bebas dipesan lagi.
create unique index if not exists booking_seats_slot_unique_idx
  on public.booking_seats (schedule_id, travel_date, seat_no)
  where is_active = true and schedule_id is not null;

create index if not exists booking_seats_booking_idx
  on public.booking_seats (booking_id);

drop trigger if exists booking_seats_set_updated_at on public.booking_seats;
create trigger booking_seats_set_updated_at
  before update on public.booking_seats
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Riwayat perubahan status (audit + bahan notifikasi)
-- ---------------------------------------------------------------------------
create table if not exists public.booking_status_history (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  from_status text,
  to_status text not null,
  changed_by uuid references public.users(id) on delete set null,
  actor_role text not null default 'system',
  note text,
  created_at timestamptz not null default now()
);

create index if not exists booking_status_history_booking_idx
  on public.booking_status_history (booking_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Trigger: catat setiap perubahan status ke riwayat.
-- Pelaku diisi RPC lewat set_config('app.actor_user_id'/'app.actor_role',
-- ..., true) sehingga audit trail tahu siapa yang mengubah.
-- ---------------------------------------------------------------------------
create or replace function public.log_booking_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_role text;
  v_note text;
begin
  v_actor := public.try_uuid(current_setting('app.actor_user_id', true));
  v_role := coalesce(nullif(current_setting('app.actor_role', true), ''), 'system');
  v_note := nullif(current_setting('app.actor_note', true), '');

  if tg_op = 'INSERT' then
    insert into public.booking_status_history (booking_id, from_status, to_status, changed_by, actor_role, note)
    values (new.id, null, new.status, v_actor, v_role, coalesce(v_note, 'booking dibuat'));
    return null;
  end if;

  if new.status is distinct from old.status then
    insert into public.booking_status_history (booking_id, from_status, to_status, changed_by, actor_role, note)
    values (new.id, old.status, new.status, v_actor, v_role, v_note);
  end if;

  return null;
end;
$$;

drop trigger if exists bookings_log_status_change on public.bookings;
create trigger bookings_log_status_change
  after insert or update of status on public.bookings
  for each row execute function public.log_booking_status_change();

-- ---------------------------------------------------------------------------
-- Label status untuk UI (bahasa Indonesia) — dipakai booking_json().
-- ---------------------------------------------------------------------------
create or replace function public.booking_status_label(p_status text)
returns text
language sql
immutable
as $$
  select case p_status
    when 'pending'   then 'Menunggu Konfirmasi'
    when 'confirmed' then 'Dikonfirmasi'
    when 'completed' then 'Selesai'
    when 'cancelled' then 'Dibatalkan'
    when 'expired'   then 'Kedaluwarsa'
    else coalesce(p_status, '-')
  end;
$$;

comment on function public.booking_status_label(text) is
  'Kode status server → label yang ditampilkan aplikasi (kompatibel data lama).';

-- Kebalikannya: label/data lama → kode server (dipakai impor data Firestore).
create or replace function public.booking_status_code(p_label text)
returns text
language sql
immutable
as $$
  select case
    when p_label is null then 'pending'
    when lower(p_label) in ('pending', 'menunggu konfirmasi', 'menunggu', 'baru', 'unpaid') then 'pending'
    when lower(p_label) in ('confirmed', 'dikonfirmasi', 'terkonfirmasi', 'lunas', 'paid', 'sukses', 'berhasil') then 'confirmed'
    when lower(p_label) in ('completed', 'selesai', 'done', 'tuntas') then 'completed'
    when lower(p_label) in ('cancelled', 'canceled', 'dibatalkan', 'batal') then 'cancelled'
    when lower(p_label) in ('expired', 'kedaluwarsa', 'hangus') then 'expired'
    else 'pending'
  end;
$$;

-- ---------------------------------------------------------------------------
-- booking_json: bentuk balasan standar untuk aplikasi.
-- Dipakai semua RPC (create/cancel/list/import) agar klien hanya punya
-- satu cara membaca data.
-- ---------------------------------------------------------------------------
create or replace function public.booking_json(p_booking public.bookings)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id', b.id,
    'kode', b.kode,
    'status', b.status,
    'status_label', public.booking_status_label(b.status),
    'service_type', b.service_type,
    'user_id', b.user_id,
    'origin', b.origin_name,
    'destination', b.destination_name,
    'origin_city_id', b.origin_city_id,
    'destination_city_id', b.destination_city_id,
    'route_id', b.route_id,
    'schedule_id', b.schedule_id,
    'travel_date', to_char(b.travel_date, 'YYYY-MM-DD'),
    'departure_time', case when b.departure_time is null then null
                           else to_char(b.departure_time, 'HH24:MI') end,
    'seats', b.seats,
    'price_per_seat', b.price_per_seat,
    'subtotal', b.subtotal,
    'discount', b.discount,
    'total', b.total,
    'currency', b.currency,
    'promo_code', b.promo_code,
    'payment_method', b.payment_method,
    'payment_status', b.payment_status,
    'contact_name', b.contact_name,
    'contact_phone', b.contact_phone,
    'contact_email', b.contact_email,
    'pickup_address', b.pickup_address,
    'dropoff_address', b.dropoff_address,
    'notes', b.notes,
    'source', b.source,
    'idempotency_key', b.idempotency_key,
    'expires_at', b.expires_at,
    'confirmed_at', b.confirmed_at,
    'cancelled_at', b.cancelled_at,
    'cancelled_reason', b.cancelled_reason,
    'completed_at', b.completed_at,
    'created_at', b.created_at,
    'updated_at', b.updated_at,
    'seat_numbers', coalesce(
      (select jsonb_agg(bs.seat_no order by bs.seat_no)
         from public.booking_seats bs
        where bs.booking_id = b.id and bs.is_active),
      '[]'::jsonb
    )
  )
  from public.bookings b
  where b.id = p_booking.id;
$$;

-- ---------------------------------------------------------------------------
-- resolve_promo: validasi kode promo (server satu-satunya yang boleh menilai)
-- ---------------------------------------------------------------------------
create or replace function public.resolve_promo(p_code text, p_subtotal numeric)
returns public.promo_codes
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_promo public.promo_codes;
  v_code text;
begin
  v_code := upper(nullif(trim(coalesce(p_code, '')), ''));
  if v_code is null then
    return v_promo;
  end if;

  select * into v_promo from public.promo_codes p where p.code = v_code;

  if v_promo.code is null or not v_promo.is_active then
    perform public.raise_app_error('promo_invalid', 'Kode promo tidak dikenal', jsonb_build_object('promo_code', v_code));
  end if;
  if v_promo.valid_from is not null and current_date < v_promo.valid_from then
    perform public.raise_app_error('promo_invalid', 'Kode promo belum berlaku', jsonb_build_object('promo_code', v_code));
  end if;
  if v_promo.valid_until is not null and current_date > v_promo.valid_until then
    perform public.raise_app_error('promo_invalid', 'Kode promo sudah kedaluwarsa', jsonb_build_object('promo_code', v_code));
  end if;
  if v_promo.max_uses is not null and v_promo.used_count >= v_promo.max_uses then
    perform public.raise_app_error('promo_invalid', 'Kuota kode promo sudah habis', jsonb_build_object('promo_code', v_code));
  end if;
  if p_subtotal is not null and p_subtotal < v_promo.min_spend then
    perform public.raise_app_error('promo_invalid', 'Belum memenuhi syarat minimum belanja promo', jsonb_build_object('promo_code', v_code, 'min_spend', v_promo.min_spend));
  end if;

  return v_promo;
end;
$$;

-- ---------------------------------------------------------------------------
-- hitung_promo: besar potongan dibatasi plafon + tidak melebihi subtotal
-- ---------------------------------------------------------------------------
create or replace function public.hitung_diskon(
  p_percent integer,
  p_max_discount numeric,
  p_subtotal numeric
)
returns numeric
language sql
immutable
as $$
  select least(
    round(coalesce(p_subtotal, 0) * coalesce(p_percent, 0) / 100.0, 2),
    coalesce(p_max_discount, coalesce(p_subtotal, 0)),
    coalesce(p_subtotal, 0)
  );
$$;

-- ===========================================================================
-- RPC UTAMA: create_booking
-- ===========================================================================
create or replace function public.create_booking(
  p_user_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_booking public.bookings;
  v_existing public.bookings;
  v_route public.routes;
  v_schedule public.route_schedules;
  v_origin public.cities;
  v_destination public.cities;
  v_promo public.promo_codes;

  v_idempotency text;
  v_kode text;
  v_seats integer;
  v_travel_date date;
  v_departure_time time;
  v_price numeric(12, 2);
  v_subtotal numeric(12, 2);
  v_discount numeric(12, 2) := 0;
  v_total numeric(12, 2);
  v_client_total numeric(12, 2);
  v_promo_code text;
  v_name text;
  v_phone text;
  v_attempt integer;
  v_seat_no integer;
  v_seat_label text;
  v_route_id uuid;
begin
  -- ---------------------------------------------------------------------
  -- 1) Pemanggil harus user sah (Edge Function sudah verifikasi Firebase token)
  -- ---------------------------------------------------------------------
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;
  if not exists (select 1 from public.users u where u.id = p_user_id and u.deleted_at is null) then
    perform public.raise_app_error('not_found', 'Akun tidak ditemukan — coba login ulang');
  end if;

  perform set_config('app.actor_user_id', p_user_id::text, true);
  perform set_config('app.actor_role', 'customer', true);
  perform set_config('app.actor_note', 'booking dibuat dari aplikasi', true);

  -- ---------------------------------------------------------------------
  -- 2) Idempotency: permintaan ulang mengembalikan booking yang sama
  -- ---------------------------------------------------------------------
  v_idempotency := nullif(trim(coalesce(v_payload->>'idempotency_key', '')), '');
  if v_idempotency is not null then
    select * into v_existing
      from public.bookings b
     where b.user_id = p_user_id and b.idempotency_key = v_idempotency;
    if v_existing.id is not null then
      return jsonb_build_object(
        'booking', public.booking_json(v_existing),
        'idempotent', true
      );
    end if;
  end if;

  -- ---------------------------------------------------------------------
  -- 3) Validasi input dasar
  -- ---------------------------------------------------------------------
  v_seats := coalesce(public.try_int(v_payload->>'seats'), 1);
  if v_seats < 1 or v_seats > 20 then
    perform public.raise_app_error('validation_error', 'Jumlah kursi tidak wajar (1–20)', jsonb_build_object('seats', v_seats));
  end if;

  v_travel_date := public.try_date(v_payload->>'travel_date');
  if v_travel_date is null then
    perform public.raise_app_error('validation_error', 'Tanggal keberangkatan tidak valid');
  end if;
  if v_travel_date < current_date then
    perform public.raise_app_error('validation_error', 'Tanggal keberangkatan sudah lewat', jsonb_build_object('travel_date', v_travel_date));
  end if;
  if v_travel_date > current_date + interval '180 days' then
    perform public.raise_app_error('validation_error', 'Tanggal keberangkatan terlalu jauh (maks 180 hari)');
  end if;

  v_departure_time := public.parse_departure_time(coalesce(v_payload->>'departure_time', v_payload->>'jam'));
  if v_departure_time is null then
    perform public.raise_app_error('validation_error', 'Jam keberangkatan tidak valid');
  end if;

  v_name := nullif(trim(coalesce(v_payload->>'contact_name', v_payload->>'nama', '')), '');
  if v_name is null or char_length(v_name) < 2 then
    perform public.raise_app_error('validation_error', 'Nama pemesan wajib diisi');
  end if;
  if char_length(v_name) > 80 then
    v_name := left(v_name, 80);
  end if;

  v_phone := public.normalize_phone(coalesce(v_payload->>'contact_phone', v_payload->>'wa'));
  if v_phone is null then
    perform public.raise_app_error('validation_error', 'Nomor WhatsApp tidak valid', jsonb_build_object('contact_phone', v_payload->>'contact_phone'));
  end if;

  -- ---------------------------------------------------------------------
  -- 4) Tentukan rute (id rute, atau pasangan kota asal–tujuan)
  -- ---------------------------------------------------------------------
  v_route_id := public.try_uuid(v_payload->>'route_id');
  if v_route_id is not null then
    select * into v_route from public.routes r where r.id = v_route_id and r.is_active;
  end if;

  if v_route.id is null then
    v_origin := public.resolve_city(coalesce(v_payload->>'origin', v_payload->>'asal'));
    v_destination := public.resolve_city(coalesce(v_payload->>'destination', v_payload->>'tujuan'));

    if v_origin.id is null then
      perform public.raise_app_error('not_found', 'Kota asal tidak dikenali', jsonb_build_object('origin', v_payload->>'origin'));
    end if;
    if v_destination.id is null then
      perform public.raise_app_error('not_found', 'Kota tujuan tidak dikenali', jsonb_build_object('destination', v_payload->>'destination'));
    end if;

    select * into v_route
      from public.routes r
     where r.origin_city_id = v_origin.id
       and r.destination_city_id = v_destination.id
       and r.is_active
     limit 1;
  end if;

  if v_route.id is null then
    perform public.raise_app_error(
      'not_found',
      'Rute belum tersedia. Hubungi admin via WhatsApp.',
      jsonb_build_object('origin', v_payload->>'origin', 'destination', v_payload->>'destination')
    );
  end if;

  select * into v_origin from public.cities c where c.id = v_route.origin_city_id;
  select * into v_destination from public.cities c where c.id = v_route.destination_city_id;

  -- ---------------------------------------------------------------------
  -- 5) Jadwal + KUNCI baris: dua permintaan bersamaan diantre di sini,
  --    sehingga sisa kursi tidak bisa "kebobolan" (race condition).
  -- ---------------------------------------------------------------------
  v_schedule := public.resolve_schedule(v_route.id, v_travel_date, v_departure_time);

  select * into v_schedule
    from public.route_schedules s
   where s.id = v_schedule.id
     for update;

  if v_schedule.available_seats < v_seats then
    perform public.raise_app_error(
      'seats_unavailable',
      case when v_schedule.available_seats <= 0
           then 'Maaf, kursi untuk jadwal ini sudah habis'
           else format('Sisa kursi tinggal %s dari %s yang diminta', v_schedule.available_seats, v_seats)
      end,
      jsonb_build_object('available', v_schedule.available_seats, 'requested', v_seats)
    );
  end if;

  -- ---------------------------------------------------------------------
  -- 6) Harga dihitung server (bukan dari aplikasi)
  -- ---------------------------------------------------------------------
  v_price := coalesce(v_schedule.price, v_route.base_price);
  if v_price is null or v_price <= 0 then
    perform public.raise_app_error('not_found', 'Harga rute belum diatur. Hubungi admin.');
  end if;

  v_subtotal := v_price * v_seats;
  v_promo_code := upper(nullif(trim(coalesce(v_payload->>'promo_code', v_payload->>'promo', '')), ''));

  if v_promo_code is not null then
    v_promo := public.resolve_promo(v_promo_code, v_subtotal);
    v_discount := public.hitung_diskon(v_promo.percent, v_promo.max_discount, v_subtotal);
  end if;

  v_total := v_subtotal - v_discount;

  -- Aplikasi boleh mengirim total yang dilihat pengguna. Bila beda (harga
  -- sudah diubah admin / promo berubah), tolak agar pengguna tidak terkejut
  -- dengan nilai tagihan yang berbeda.
  v_client_total := public.try_numeric(coalesce(v_payload->>'client_total', v_payload->>'total'));
  if v_client_total is not null and abs(v_client_total - v_total) > 0.5 then
    perform public.raise_app_error(
      'price_mismatch',
      'Harga berubah sejak form dibuka. Mohon periksa kembali total pembayaran.',
      jsonb_build_object(
        'client_total', v_client_total,
        'expected_total', v_total,
        'price_per_seat', v_price,
        'subtotal', v_subtotal,
        'discount', v_discount,
        'seats', v_seats,
        'promo_code', v_promo_code
      )
    );
  end if;

  -- ---------------------------------------------------------------------
  -- 7) Kode booking: pakai kiriman klien bila ada (idempoten), else generate
  -- ---------------------------------------------------------------------
  v_kode := upper(nullif(trim(coalesce(v_payload->>'kode', '')), ''));
  if v_kode is not null then
    if v_kode !~ '^RARA-[A-Z0-9]{4,12}$' then
      perform public.raise_app_error('validation_error', 'Format kode booking tidak dikenal');
    end if;
    if exists (select 1 from public.bookings b where b.kode = v_kode and b.user_id <> p_user_id) then
      perform public.raise_app_error('conflict', 'Kode booking sudah dipakai', jsonb_build_object('kode', v_kode));
    end if;
    if exists (select 1 from public.bookings b where b.kode = v_kode and b.user_id = p_user_id) then
      select * into v_existing from public.bookings b where b.kode = v_kode;
      return jsonb_build_object('booking', public.booking_json(v_existing), 'idempotent', true);
    end if;
  else
    v_kode := 'RARA-' || public.random_code(6);
    v_attempt := 0;
    loop
      exit when not exists (select 1 from public.bookings b where b.kode = v_kode);
      v_attempt := v_attempt + 1;
      if v_attempt >= 10 then
        perform public.raise_app_error('conflict', 'Gagal membuat kode booking unik, coba lagi');
      end if;
      v_kode := 'RARA-' || public.random_code(6);
    end loop;
  end if;

  -- ---------------------------------------------------------------------
  -- 8) Simpan booking
  -- ---------------------------------------------------------------------
  insert into public.bookings (
    kode, user_id, service_type, status,
    route_id, schedule_id, vehicle_id,
    origin_city_id, destination_city_id, origin_name, destination_name,
    travel_date, departure_time, seats,
    price_per_seat, subtotal, discount, total, currency, promo_code,
    payment_method, payment_status,
    contact_name, contact_phone, contact_email,
    pickup_address, dropoff_address, notes,
    source, idempotency_key
  )
  values (
    v_kode, p_user_id, coalesce(nullif(v_payload->>'service_type', ''), 'travel'), 'pending',
    v_route.id, v_schedule.id, coalesce(v_schedule.vehicle_id, v_route.vehicle_id),
    v_route.origin_city_id, v_route.destination_city_id,
    coalesce(v_origin.name, v_payload->>'origin', 'Asal'),
    coalesce(v_destination.name, v_payload->>'destination', 'Tujuan'),
    v_travel_date, v_departure_time, v_seats,
    v_price, v_subtotal, v_discount, v_total, 'IDR', nullif(v_promo_code, ''),
    nullif(trim(coalesce(v_payload->>'payment_method', v_payload->>'metodeBayar', '')), ''),
    'unpaid',
    v_name, v_phone, nullif(lower(trim(coalesce(v_payload->>'contact_email', ''))), ''),
    nullif(trim(coalesce(v_payload->>'pickup_address', v_payload->>'jemput', '')), ''),
    nullif(trim(coalesce(v_payload->>'dropoff_address', v_payload->>'antar', '')), ''),
    nullif(trim(coalesce(v_payload->>'notes', v_payload->>'catatan', '')), ''),
    coalesce(nullif(v_payload->>'source', ''), 'app'),
    v_idempotency
  )
  returning * into v_booking;

  -- ---------------------------------------------------------------------
  -- 9) Nomor kursi (bila dikirim aplikasi) — anti dobel di level index unik
  -- ---------------------------------------------------------------------
  if jsonb_typeof(v_payload->'seat_numbers') = 'array' then
    for v_seat_label in select jsonb_array_elements_text(v_payload->'seat_numbers') loop
      v_seat_no := public.try_int(v_seat_label);
      if v_seat_no is null or v_seat_no < 1 or v_seat_no > coalesce(v_schedule.capacity, 60) then
        perform public.raise_app_error('validation_error', 'Nomor kursi tidak valid', jsonb_build_object('seat_no', v_seat_label));
      end if;
      begin
        insert into public.booking_seats (booking_id, schedule_id, travel_date, seat_no, seat_label)
        values (v_booking.id, v_schedule.id, v_travel_date, v_seat_no, 'Kursi ' || v_seat_no);
      exception when unique_violation then
        perform public.raise_app_error(
          'seats_unavailable',
          format('Kursi %s baru saja dipesan orang lain', v_seat_no),
          jsonb_build_object('seat_no', v_seat_no)
        );
      end;
    end loop;
  end if;

  -- ---------------------------------------------------------------------
  -- 10) Potong sisa kursi + catat pemakaian promo
  --     (constraint available_seats >= 0 adalah jaring pengaman terakhir)
  -- ---------------------------------------------------------------------
  update public.route_schedules s
     set available_seats = s.available_seats - v_seats,
         booked_seats = s.booked_seats + v_seats
   where s.id = v_schedule.id;

  if v_promo_code is not null and v_promo.code is not null then
    update public.promo_codes p
       set used_count = p.used_count + 1
     where p.code = v_promo.code;
  end if;

  return jsonb_build_object(
    'booking', public.booking_json(v_booking),
    'idempotent', false,
    'pricing', jsonb_build_object(
      'seats', v_seats,
      'price_per_seat', v_price,
      'subtotal', v_subtotal,
      'discount', v_discount,
      'total', v_total,
      'currency', 'IDR',
      'promo_code', v_promo_code,
      'remaining_seats', v_schedule.available_seats - v_seats
    )
  );
end;
$$;

-- ===========================================================================
-- RPC: cancel_booking — pemilik membatalkan pesanannya, kursi dikembalikan
-- ===========================================================================
create or replace function public.cancel_booking(
  p_user_id uuid,
  p_kode text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_kode text;
  v_schedule public.route_schedules;
begin
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;

  v_kode := upper(nullif(trim(coalesce(p_kode, '')), ''));
  if v_kode is null then
    perform public.raise_app_error('validation_error', 'Kode booking wajib diisi');
  end if;

  select * into v_booking
    from public.bookings b
   where b.kode = v_kode and b.user_id = p_user_id
     for update;

  if v_booking.id is null then
    perform public.raise_app_error('not_found', 'Pesanan tidak ditemukan', jsonb_build_object('kode', v_kode));
  end if;

  if v_booking.status in ('cancelled', 'expired') then
    return jsonb_build_object('booking', public.booking_json(v_booking), 'changed', false);
  end if;
  if v_booking.status = 'completed' or v_booking.payment_status = 'paid' then
    perform public.raise_app_error(
      'conflict',
      'Pesanan yang sudah dibayar/lunas tidak bisa dibatalkan sendiri. Hubungi admin.',
      jsonb_build_object('kode', v_kode, 'status', v_booking.status, 'payment_status', v_booking.payment_status)
    );
  end if;

  perform set_config('app.actor_user_id', p_user_id::text, true);
  perform set_config('app.actor_role', 'customer', true);
  perform set_config('app.actor_note', coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'dibatalkan pengguna'), true);

  update public.bookings b
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_reason = nullif(trim(coalesce(p_reason, '')), ''),
         expires_at = null
   where b.id = v_booking.id
  returning * into v_booking;

  -- Kembalikan kursi ke jadwal.
  if v_booking.schedule_id is not null then
    select * into v_schedule from public.route_schedules s where s.id = v_booking.schedule_id for update;
    if v_schedule.id is not null then
      update public.route_schedules s
         set available_seats = least(s.available_seats + v_booking.seats, coalesce(s.capacity, s.available_seats + v_booking.seats)),
             booked_seats = greatest(s.booked_seats - v_booking.seats, 0)
       where s.id = v_schedule.id;
    end if;
  end if;

  update public.booking_seats bs
     set is_active = false
   where bs.booking_id = v_booking.id and bs.is_active;

  return jsonb_build_object(
    'booking', public.booking_json(v_booking),
    'changed', true,
    'released_seats', v_booking.seats
  );
end;
$$;

-- ===========================================================================
-- RPC: list_my_bookings — riwayat pesanan pengguna dengan pagination
-- ===========================================================================
create or replace function public.list_my_bookings(
  p_user_id uuid,
  p_limit integer default 20,
  p_offset integer default 0,
  p_status text default null
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
  v_status text := nullif(lower(trim(coalesce(p_status, ''))), '');
  v_items jsonb;
  v_total integer;
begin
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;

  v_status := case when v_status is null then null else public.booking_status_code(v_status) end;
  if v_status is not null and v_status not in ('pending', 'confirmed', 'completed', 'cancelled', 'expired') then
    v_status := null;
  end if;

  select count(*)::integer into v_total
    from public.bookings b
   where b.user_id = p_user_id
     and (v_status is null or b.status = v_status);

  select coalesce(jsonb_agg(public.booking_json(b) order by b.created_at desc), '[]'::jsonb)
    into v_items
    from (
      select *
        from public.bookings b
       where b.user_id = p_user_id
         and (v_status is null or b.status = v_status)
       order by b.created_at desc
       limit v_limit offset v_offset
    ) b;

  return jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', (v_offset + jsonb_array_length(v_items)) < v_total
  );
end;
$$;

-- ===========================================================================
-- RPC: find_booking — satu pesanan milik pengguna
-- ===========================================================================
create or replace function public.find_booking(p_user_id uuid, p_kode text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
begin
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;

  select * into v_booking
    from public.bookings b
   where b.kode = upper(trim(coalesce(p_kode, ''))) and b.user_id = p_user_id;

  if v_booking.id is null then
    return null;
  end if;
  return public.booking_json(v_booking);
end;
$$;

-- ---------------------------------------------------------------------------
-- Keamanan: data booking tidak boleh disentuh anon/authenticated.
-- Semua akses lewat Edge Function (service_role) setelah verifikasi token.
-- ---------------------------------------------------------------------------
alter table public.bookings enable row level security;
alter table public.booking_seats enable row level security;
alter table public.booking_status_history enable row level security;
alter table public.promo_codes enable row level security;

revoke all on table public.bookings from anon, authenticated;
revoke all on table public.booking_seats from anon, authenticated;
revoke all on table public.booking_status_history from anon, authenticated;
revoke all on table public.promo_codes from anon, authenticated;

revoke all on function public.create_booking(uuid, jsonb) from public;
revoke all on function public.cancel_booking(uuid, text, text) from public;
revoke all on function public.list_my_bookings(uuid, integer, integer, text) from public;
revoke all on function public.find_booking(uuid, text) from public;
revoke all on function public.resolve_promo(text, numeric) from public;
