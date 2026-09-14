-- ============================================================================
-- 202609140001_users_devices.sql
-- Langkah 3 & 8 rencana migrasi: lengkapi tabel `users` (jembatan Firebase UID
-- → Supabase) dan tambahkan `user_devices` (simpan token FCM per perangkat).
--
-- Catatan keamanan:
--   * Firebase Auth tetap menjadi identitas login (tidak ada Supabase Auth).
--   * Karena itu tabel ini TIDAK dapat diakses anon/authenticated. Seluruh
--     akses lewat Edge Function dengan service_role setelah Firebase ID token
--     diverifikasi. RLS aktif + tidak ada policy = default deny.
-- ============================================================================

-- Catatan: helper publik (set_updated_at, normalize_phone, parse_departure_time,
-- random_code, raise_app_error) ada di 202609140000_shared_helpers.sql.

-- ---------------------------------------------------------------------------
-- users: kolom tambahan untuk sinkronisasi profil & audit login
-- ---------------------------------------------------------------------------
alter table public.users
  add column if not exists photo_url text,
  add column if not exists is_active boolean not null default true,
  add column if not exists last_login_at timestamptz,
  add column if not exists deleted_at timestamptz,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Satu nomor HP hanya boleh dipakai satu akun (dinormalisasi +62...).
-- Index parsial: baris kosong/NULL tidak dihitung agar data lama tetap aman.
create unique index if not exists users_phone_unique_idx
  on public.users (phone)
  where phone is not null and phone <> '';

create index if not exists users_role_idx on public.users (role);
create index if not exists users_created_at_idx on public.users (created_at desc);

drop trigger if exists users_set_updated_at on public.users;
create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- user_devices: token FCM per perangkat (ganti array fcmTokens di Firestore)
-- Satu token = satu baris. Token unik global: perangkat yang berpindah akun
-- cukup di-reassign (lihat RPC register_user_device).
-- ---------------------------------------------------------------------------
create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  fcm_token text not null,
  platform text not null default 'unknown'
    check (platform in ('android', 'ios', 'web', 'unknown')),
  device_model text,
  app_version text,
  locale text,
  is_active boolean not null default true,
  failure_count integer not null default 0 check (failure_count >= 0),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists user_devices_fcm_token_idx
  on public.user_devices (fcm_token);

create index if not exists user_devices_user_idx
  on public.user_devices (user_id)
  where is_active = true;

drop trigger if exists user_devices_set_updated_at on public.user_devices;
create trigger user_devices_set_updated_at
  before update on public.user_devices
  for each row execute function public.set_updated_at();

comment on table public.user_devices is
  'Token FCM per perangkat. Dipakai Edge Function notifikasi; token basi ditandai is_active=false.';

-- ---------------------------------------------------------------------------
-- RPC: register_user_device — idempotent, token yang sama tidak dobel.
-- Dipanggil Edge Function `register-device` setelah token Firebase diverifikasi.
-- ---------------------------------------------------------------------------
create or replace function public.register_user_device(
  p_user_id uuid,
  p_fcm_token text,
  p_platform text default 'unknown',
  p_device_model text default null,
  p_app_version text default null,
  p_locale text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_device public.user_devices;
begin
  if p_user_id is null then
    raise exception 'p_user_id wajib diisi' using errcode = 'RA001', detail = 'validation_error';
  end if;
  if p_fcm_token is null or length(trim(p_fcm_token)) < 10 then
    raise exception 'Token FCM tidak valid' using errcode = 'RA001', detail = 'validation_error';
  end if;

  insert into public.user_devices as d (
    user_id, fcm_token, platform, device_model, app_version, locale,
    is_active, failure_count, last_seen_at
  )
  values (
    p_user_id, trim(p_fcm_token), coalesce(p_platform, 'unknown'),
    p_device_model, p_app_version, p_locale, true, 0, now()
  )
  on conflict (fcm_token) do update set
    user_id = excluded.user_id,          -- perangkat ganti akun → pindah pemilik
    platform = excluded.platform,
    device_model = coalesce(excluded.device_model, d.device_model),
    app_version = coalesce(excluded.app_version, d.app_version),
    locale = coalesce(excluded.locale, d.locale),
    is_active = true,
    failure_count = 0,
    last_seen_at = now()
  returning * into v_device;

  return jsonb_build_object(
    'id', v_device.id,
    'user_id', v_device.user_id,
    'platform', v_device.platform,
    'is_active', v_device.is_active,
    'last_seen_at', v_device.last_seen_at
  );
end;
$$;

-- Nonaktifkan token yang sudah tidak dipakai (logout / uninstall).
create or replace function public.unregister_user_device(
  p_user_id uuid,
  p_fcm_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  if p_user_id is null then
    raise exception 'p_user_id wajib diisi' using errcode = 'RA001', detail = 'validation_error';
  end if;

  update public.user_devices d
     set is_active = false
   where d.user_id = p_user_id
     and (p_fcm_token is null or d.fcm_token = p_fcm_token);
  get diagnostics v_count = row_count;

  return jsonb_build_object('deactivated', v_count);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: auth_user_sync — inti langkah 4 (Firebase UID → users.id)
-- Edge Function `auth-user-sync` memverifikasi ID token lalu memanggil ini.
-- ---------------------------------------------------------------------------
create or replace function public.auth_user_sync(
  p_firebase_uid text,
  p_full_name text default null,
  p_phone text default null,
  p_email text default null,
  p_photo_url text default null,
  p_platform text default null,
  p_app_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user public.users;
  v_is_new boolean := false;
  v_phone text;
begin
  if p_firebase_uid is null or length(trim(p_firebase_uid)) < 5 then
    raise exception 'firebase_uid tidak valid' using errcode = 'RA001', detail = 'validation_error';
  end if;

  -- Normalisasi nomor: 0812... / 62812... → +62812...
  v_phone := public.normalize_phone(p_phone);

  select * into v_user from public.users where firebase_uid = p_firebase_uid;

  if v_user.id is null then
    v_is_new := true;
    insert into public.users as u (
      firebase_uid, full_name, phone, email, photo_url, last_login_at
    )
    values (
      trim(p_firebase_uid),
      nullif(trim(coalesce(p_full_name, '')), ''),
      v_phone,
      nullif(lower(trim(coalesce(p_email, ''))), ''),
      nullif(trim(coalesce(p_photo_url, '')), ''),
      now()
    )
    on conflict (firebase_uid) do update set
      last_login_at = now()
    returning * into v_user;
  else
    -- Profil hanya dilengkapi, tidak ditimpa dengan nilai kosong.
    update public.users u
       set full_name = coalesce(nullif(trim(coalesce(p_full_name, '')), ''), u.full_name),
           phone = coalesce(v_phone, u.phone),
           email = coalesce(nullif(lower(trim(coalesce(p_email, ''))), ''), u.email),
           photo_url = coalesce(nullif(trim(coalesce(p_photo_url, '')), ''), u.photo_url),
           last_login_at = now(),
           is_active = true
     where u.id = v_user.id
    returning * into v_user;
  end if;

  -- Perangkat (opsional) sekaligus terdaftar bila token dikirim.
  if p_platform is not null then
    update public.user_devices d
       set last_seen_at = now(), app_version = coalesce(p_app_version, d.app_version)
     where d.user_id = v_user.id and d.is_active;
  end if;

  return jsonb_build_object(
    'user', jsonb_build_object(
      'id', v_user.id,
      'firebase_uid', v_user.firebase_uid,
      'full_name', coalesce(v_user.full_name, ''),
      'phone', coalesce(v_user.phone, ''),
      'email', coalesce(v_user.email, ''),
      'photo_url', v_user.photo_url,
      'role', v_user.role,
      'is_active', v_user.is_active,
      'created_at', v_user.created_at,
      'last_login_at', v_user.last_login_at
    ),
    'is_new', v_is_new
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: get_user_by_firebase_uid — dipakai Edge Function untuk memetakan token
-- ---------------------------------------------------------------------------
create or replace function public.get_user_by_firebase_uid(p_firebase_uid text)
returns public.users
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select * from public.users where firebase_uid = p_firebase_uid;
$$;

-- ---------------------------------------------------------------------------
-- Hak akses: hanya service_role (Edge Function) yang boleh menyentuh tabel ini.
-- ---------------------------------------------------------------------------
alter table public.users enable row level security;
alter table public.user_devices enable row level security;

revoke all on table public.users from anon, authenticated;
revoke all on table public.user_devices from anon, authenticated;

revoke all on function public.auth_user_sync(text, text, text, text, text, text, text) from public;
revoke all on function public.register_user_device(uuid, text, text, text, text, text) from public;
revoke all on function public.unregister_user_device(uuid, text) from public;
revoke all on function public.get_user_by_firebase_uid(text) from public;
