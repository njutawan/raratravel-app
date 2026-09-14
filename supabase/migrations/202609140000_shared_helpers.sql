-- ============================================================================
-- 202609140000_shared_helpers.sql
-- Helper bersama untuk seluruh migrasi Rara Travel.
--
-- Kontrak error API (dipakai semua RPC):
--   * Kode SQLSTATE 'RA0xx'  → Edge Function memetakan ke status HTTP.
--   * Kolom DETAIL berisi JSON {"code": "...", ...} → dibaca Edge Function
--     supaya aplikasi bisa menampilkan pesan yang tepat.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Trigger updated_at
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger generik: isi kolom updated_at dengan waktu server saat baris diubah.';

-- ---------------------------------------------------------------------------
-- 2. Normalisasi nomor HP Indonesia
--    0812... / 62812... / +62812... → +62812...
-- ---------------------------------------------------------------------------
create or replace function public.normalize_phone(p_phone text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := nullif(trim(coalesce(p_phone, '')), '');
  if v is null then
    return null;
  end if;

  v := regexp_replace(v, '[\s\-.()]', '', 'g');
  if v ~ '^\+62' then
    v := '+' || substr(v, 2);
  elsif v ~ '^62' then
    v := '+' || v;
  elsif v ~ '^0' then
    v := '+62' || substr(v, 2);
  else
    v := '+62' || v;
  end if;

  -- Nomor Indonesia: +62 diikuti 8–12 digit.
  if v !~ '^\+62[0-9]{8,12}$' then
    return null;
  end if;
  return v;
end;
$$;

comment on function public.normalize_phone(text) is
  'Normalisasi nomor HP Indonesia ke format +62...; null bila tidak valid.';

-- ---------------------------------------------------------------------------
-- 3. Parser jam yang toleran
--    Aplikasi mengirim "06.00" (gaya Indonesia) atau "06:00" → time.
-- ---------------------------------------------------------------------------
create or replace function public.parse_departure_time(p_value text)
returns time
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := nullif(trim(coalesce(p_value, '')), '');
  if v is null then
    return null;
  end if;

  v := replace(v, '.', ':');
  if v ~ '^[0-9]{1,2}:[0-9]{1,2}$' then
    v := lpad(split_part(v, ':', 1), 2, '0') || ':' || split_part(v, ':', 2);
  end if;

  begin
    return v::time;
  exception when others then
    return null;
  end;
end;
$$;

comment on function public.parse_departure_time(text) is
  'Terima "06.00"/"06:00"/"6:00" → 06:00:00. Null bila tidak bisa diurai.';

-- ---------------------------------------------------------------------------
-- 4. Kode acak (kode booking, dsb.)
--    Huruf tanpa karakter ambigu (I, O, 0, 1) agar mudah dibaca pengguna.
-- ---------------------------------------------------------------------------
create or replace function public.random_code(p_length integer default 6)
returns text
language plpgsql
volatile
as $$
declare
  v_chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_out text := '';
  i integer;
begin
  if p_length is null or p_length < 1 or p_length > 24 then
    raise exception 'Panjang kode tidak wajar' using errcode = 'RA001', detail = 'validation_error';
  end if;

  for i in 1..p_length loop
    v_out := v_out || substr(v_chars, (floor(random() * length(v_chars)) + 1)::integer, 1);
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Error terstruktur
--    p_details akan tampil di kolom "details" respons PostgREST sehingga
--    Edge Function dapat meneruskannya ke aplikasi.
-- ---------------------------------------------------------------------------
create or replace function public.raise_app_error(
  p_code text,
  p_message text default null,
  p_details jsonb default null
)
returns void
language plpgsql
volatile
as $$
declare
  v_state text;
begin
  v_state := case p_code
    when 'validation_error'  then 'RA001'
    when 'price_mismatch'    then 'RA002'
    when 'seats_unavailable' then 'RA003'
    when 'not_found'         then 'RA004'
    when 'promo_invalid'     then 'RA005'
    when 'forbidden'         then 'RA006'
    when 'conflict'          then 'RA007'
    when 'payment_failed'    then 'RA008'
    else 'RA099'
  end;

  raise exception '%', coalesce(p_message, p_code)
    using
      errcode = v_state,
      detail = (jsonb_build_object('code', p_code) || coalesce(p_details, '{}'::jsonb))::text;
end;
$$;

comment on function public.raise_app_error(text, text, jsonb) is
  'Lempar error terstruktur: SQLSTATE RA0xx + DETAIL JSON {"code": ...}.';

-- ---------------------------------------------------------------------------
-- 6. Cast "aman": payload JSON dari aplikasi bisa berisi tipe apa saja.
--    Mengembalikan null (bukan error) bila nilai tidak bisa dikonversi.
-- ---------------------------------------------------------------------------
create or replace function public.try_int(p_value text)
returns integer
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::integer;
exception when others then
  return null;
end;
$$;

create or replace function public.try_numeric(p_value text)
returns numeric
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::numeric;
exception when others then
  return null;
end;
$$;

create or replace function public.try_date(p_value text)
returns date
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::date;
exception when others then
  return null;
end;
$$;

create or replace function public.try_uuid(p_value text)
returns uuid
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::uuid;
exception when others then
  return null;
end;
$$;

create or replace function public.try_timestamptz(p_value text)
returns timestamptz
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::timestamptz;
exception when others then
  return null;
end;
$$;
