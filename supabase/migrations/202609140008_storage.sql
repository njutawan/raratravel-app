-- ============================================================================
-- 202609140008_storage.sql
-- Langkah 11 rencana migrasi: Supabase Storage untuk gambar katalog, avatar,
-- dan bukti transfer.
--
-- Konsekuensi penting: login memakai Firebase, BUKAN Supabase Auth. Karena itu
-- `auth.uid()` tidak bisa dipakai untuk menentukan pemilik berkas di Storage.
-- Aturan yang dipakai:
--   * Berkas publik (gambar katalog/avatar) boleh dibaca siapa saja.
--   * TIDAK ADA izin tulis dari anon/authenticated — unggah/unduh berkas
--     privat dilakukan aplikasi lewat Edge Function `storage-sign` yang
--     memverifikasi Firebase ID token lalu membuat signed URL.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Bucket
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'public-assets', 'public-assets', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Bukti transfer/pembayaran: privat, hanya lewat signed URL.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'payment-proofs', 'payment-proofs', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Kebijakan akses objek
-- ---------------------------------------------------------------------------
drop policy if exists public_assets_read on storage.objects;
create policy public_assets_read on storage.objects
  for select to anon, authenticated
  using (bucket_id in ('public-assets', 'avatars'));

-- payment-proofs sengaja TIDAK punya policy baca: satu-satunya jalan adalah
-- Edge Function (service_role) yang memeriksa pemilik pesanan.

-- ---------------------------------------------------------------------------
-- Catatan berkas: memudahkan admin menelusuri asal setiap unggahan.
-- ---------------------------------------------------------------------------
create table if not exists public.media_assets (
  id uuid primary key default gen_random_uuid(),
  bucket text not null,
  path text not null,
  kind text not null
    constraint media_assets_kind_check
    check (kind in ('route', 'tour', 'rental', 'vehicle', 'avatar', 'payment_proof', 'other')),
  mime_type text,
  file_size bigint check (file_size is null or file_size >= 0),
  is_public boolean not null default true,
  owner_user_id uuid references public.users(id) on delete set null,
  booking_id uuid references public.bookings(id) on delete set null,
  uploaded_by uuid references public.users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bucket, path)
);

create index if not exists media_assets_kind_idx
  on public.media_assets (kind, created_at desc);

create index if not exists media_assets_booking_idx
  on public.media_assets (booking_id)
  where booking_id is not null;

drop trigger if exists media_assets_set_updated_at on public.media_assets;
create trigger media_assets_set_updated_at
  before update on public.media_assets
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RPC: record_media_asset — dicatat Edge Function setelah unggahan berhasil
-- ---------------------------------------------------------------------------
create or replace function public.record_media_asset(
  p_bucket text,
  p_path text,
  p_kind text default 'other',
  p_owner_user_id uuid default null,
  p_booking_id uuid default null,
  p_uploaded_by uuid default null,
  p_mime_type text default null,
  p_file_size bigint default null,
  p_is_public boolean default true,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_asset public.media_assets;
begin
  if nullif(trim(coalesce(p_bucket, '')), '') is null
     or nullif(trim(coalesce(p_path, '')), '') is null then
    perform public.raise_app_error('validation_error', 'bucket & path berkas wajib diisi');
  end if;
  if p_kind not in ('route', 'tour', 'rental', 'vehicle', 'avatar', 'payment_proof', 'other') then
    perform public.raise_app_error('validation_error', 'Jenis berkas tidak dikenal', jsonb_build_object('kind', p_kind));
  end if;

  insert into public.media_assets as m (
    bucket, path, kind, mime_type, file_size, is_public,
    owner_user_id, booking_id, uploaded_by, metadata
  )
  values (
    trim(p_bucket), trim(p_path), p_kind, p_mime_type, p_file_size, coalesce(p_is_public, true),
    p_owner_user_id, p_booking_id, p_uploaded_by, coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (bucket, path) do update
    set kind = excluded.kind,
        mime_type = coalesce(excluded.mime_type, m.mime_type),
        file_size = coalesce(excluded.file_size, m.file_size),
        is_public = excluded.is_public,
        owner_user_id = coalesce(excluded.owner_user_id, m.owner_user_id),
        booking_id = coalesce(excluded.booking_id, m.booking_id),
        metadata = m.metadata || excluded.metadata
  returning * into v_asset;

  return jsonb_build_object(
    'id', v_asset.id,
    'bucket', v_asset.bucket,
    'path', v_asset.path,
    'kind', v_asset.kind,
    'is_public', v_asset.is_public,
    'created_at', v_asset.created_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: media_asset_for_user — cek hak akses sebelum membuat signed URL
-- ---------------------------------------------------------------------------
create or replace function public.media_asset_for_user(p_path text, p_user_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_asset public.media_assets;
begin
  select * into v_asset
    from public.media_assets m
   where m.path = trim(coalesce(p_path, ''))
   order by m.created_at desc
   limit 1;

  if v_asset.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'id', v_asset.id,
    'bucket', v_asset.bucket,
    'path', v_asset.path,
    'kind', v_asset.kind,
    'is_public', v_asset.is_public,
    'owner_user_id', v_asset.owner_user_id,
    'booking_id', v_asset.booking_id,
    'allowed', v_asset.is_public or (p_user_id is not null and v_asset.owner_user_id = p_user_id)
  );
end;
$$;

alter table public.media_assets enable row level security;
revoke all on table public.media_assets from anon, authenticated;
revoke all on function public.record_media_asset(text, text, text, uuid, uuid, uuid, text, bigint, boolean, jsonb) from public;
revoke all on function public.media_asset_for_user(text, uuid) from public;
