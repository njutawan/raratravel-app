-- ============================================================================
-- 202609140010_purge_user.sql
-- Hapus-permanen data pribadi pengguna dari Supabase (hak subjek data:
-- "right to erasure" — melengkapi tombol "Hapus Akun" di Profil).
--
-- Kenapa perlu: tombol Hapus Akun di aplikasi menghapus akun Firebase +
-- membatalkan perangkat, tetapi TIDAK menyentuh data di Supabase (profil,
-- pesanan, pembayaran, antrean notifikasi, berkas bukti transfer). Tanpa RPC
-- ini, jejak pribadi tetap ada di backend baru setelah pengguna menekan
-- "hapus akun permanen".
--
-- Dipakai oleh Edge Function `auth-user-sync`:
--   POST {"action":"purge"}   Authorization: Bearer <Firebase ID token>
-- UID diambil dari token (bukan dari body) dan dicocokkan dengan baris
-- public.users di database.
--
-- Rancangan:
--   * purge_user_storage(user_id, firebase_uid?, kodes?) — hapus berkas
--     Storage milik pengguna. Parameter opsional dipakai bila baris
--     public.users sudah terlanjur terhapus (pemanggilan ulang).
--   * purge_user_data(user_id) — titik masuk: kumpulkan uid + kode pesanan
--     DULU, hapus berkas, lalu hapus baris users (seluruh tabel anak memakai
--     on delete cascade / set null). Idempoten & aman dipanggil ulang.
--   * Keduanya HANYA boleh dipanggil service_role (Edge Function), tidak
--     pernah bisa dijangkau klien lewat PostgREST.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Hapus berkas Storage milik pengguna
-- ---------------------------------------------------------------------------
create or replace function public.purge_user_storage(
  p_user_id uuid,
  p_firebase_uid text default null,
  p_kodes text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  v_uid text := nullif(p_firebase_uid, '');
  v_kodes text[] := p_kodes;
  v_avatar int := 0;
  v_bukti int := 0;
begin
  if p_user_id is null and v_uid is null and coalesce(cardinality(v_kodes), 0) = 0 then
    return jsonb_build_object('deleted', false, 'reason', 'tidak_ada_penanda');
  end if;

  -- Bila belum diberikan, ambil dari database (berguna saat dipanggil manual).
  if v_uid is null and p_user_id is not null then
    select firebase_uid into v_uid from public.users where id = p_user_id;
  end if;
  if v_kodes is null and p_user_id is not null then
    select coalesce(array_agg(kode), '{}') into v_kodes
    from public.bookings where user_id = p_user_id;
  end if;

  -- Foto profil: avatars/users/<firebase_uid>/...
  if v_uid is not null then
    begin
      delete from storage.objects
      where bucket_id = 'avatars'
        and name like 'users/' || v_uid || '/%';
      get diagnostics v_avatar = row_count;
    exception when others then
      v_avatar := -1; -- dilaporkan apa adanya, tidak menggagalkan sisanya
    end;
  end if;

  -- Bukti transfer: payment-proofs/bookings/<kode>/...
  if coalesce(cardinality(v_kodes), 0) > 0 then
    begin
      delete from storage.objects
      where bucket_id = 'payment-proofs'
        and name like 'bookings/%'
        and split_part(name, '/', 2) = any (v_kodes);
      get diagnostics v_bukti = row_count;
    exception when others then
      v_bukti := -1;
    end;
  end if;

  return jsonb_build_object(
    'deleted', true,
    'firebase_uid', v_uid,
    'avatar_objects', v_avatar,
    'proof_objects', v_bukti,
    'kodes', to_jsonb(coalesce(v_kodes, '{}'))
  );
end $$;

-- ---------------------------------------------------------------------------
-- 2. Hapus seluruh data pengguna (titik masuk Edge Function)
-- ---------------------------------------------------------------------------
create or replace function public.purge_user_data(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_firebase_uid text;
  v_kodes text[] := '{}';
  v_users int := 0;
  v_bookings int := 0;
  v_bayar int := 0;
  v_notif int := 0;
  v_media int := 0;
  v_storage jsonb := '{}'::jsonb;
begin
  if p_user_id is null then
    return jsonb_build_object('deleted', false, 'reason', 'user_id_null');
  end if;

  select firebase_uid into v_firebase_uid
  from public.users where id = p_user_id;

  if v_firebase_uid is null then
    -- Sudah pernah dihapus (atau tidak pernah ada). Tetap bersihkan berkas
    -- bila pemanggil punya penanda lain; tanpa uid/kode tidak ada yang bisa
    -- dilakukan dan itu memang benar (bukan error).
    v_storage := public.purge_user_storage(p_user_id);
    return jsonb_build_object(
      'deleted', false,
      'reason', 'user_not_found',
      'storage', v_storage
    );
  end if;

  -- Kumpulkan DULU: setelah baris users/bookings hilang, jalurnya tak terlacak.
  select count(*) into v_bookings from public.bookings where user_id = p_user_id;
  select coalesce(array_agg(kode), '{}') into v_kodes
  from public.bookings where user_id = p_user_id;
  -- Data penumpang menempel di baris bookings (kontak & detail perjalanan),
  -- jadi ikut terhapus bersama barisnya; tidak ada tabel penumpang terpisah.
  select count(*) into v_bayar
  from public.payments p
  join public.bookings b on b.id = p.booking_id
  where b.user_id = p_user_id;
  select count(*) into v_notif from public.notification_jobs where user_id = p_user_id;
  select count(*) into v_media from public.media_assets where owner_user_id = p_user_id;

  -- (1) Berkas Storage, (2) baru baris database.
  v_storage := public.purge_user_storage(p_user_id, v_firebase_uid, v_kodes);

  delete from public.users where id = p_user_id;
  get diagnostics v_users = row_count;

  return jsonb_build_object(
    'deleted', v_users > 0,
    'firebase_uid', v_firebase_uid,
    'users', v_users,
    'bookings', v_bookings,
    'payments', v_bayar,
    'notification_jobs', v_notif,
    'media_assets', v_media,
    'storage', v_storage
  );
end $$;

-- ---------------------------------------------------------------------------
-- 3. Hak akses: HANYA service_role (Edge Function).
-- ---------------------------------------------------------------------------
revoke all on function public.purge_user_storage(uuid, text, text[]) from public, anon, authenticated;
revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_storage(uuid, text, text[]) to service_role;
grant execute on function public.purge_user_data(uuid) to service_role;

comment on function public.purge_user_data(uuid) is
  'Hapus permanen seluruh data pribadi pengguna (profil, pesanan, pembayaran, notifikasi, berkas bukti). Dipakai Edge Function auth-user-sync aksi purge.';
comment on function public.purge_user_storage(uuid, text, text[]) is
  'Hapus berkas Storage milik pengguna (avatars/<uid>/** dan payment-proofs/bookings/<kode>/**). Aman dipanggil ulang.';

do $$
begin
  raise notice '[0010] RPC purge_user_data + purge_user_storage siap (hapus akun menyeluruh)';
end $$;
