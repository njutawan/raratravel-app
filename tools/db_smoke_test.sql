-- ============================================================================
-- tools/db_smoke_test.sql
-- Uji perilaku backend booking di PostgreSQL sungguhan (tanpa Supabase).
--
-- Cara pakai (dari akar repositori):
--   python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pgserver   # sekali
--   /tmp/venv/bin/python tools/db_check.py
--
-- Berkas ini dijalankan SETELAH seluruh migrasi oleh tools/db_check.py.
-- Setiap kegagalan berhenti dengan pesan 'FAIL <nomor>: <sebab>' sehingga
-- mudah dilacak. Semua data uji memakai kota "Kota Uji ..." agar tidak
-- bertabrakan dengan data seed (kota asli).
--
-- Kelompok uji:
--    1. create_booking bahagia        → harga & kursi dihitung server
--    2. harga kiriman aplikasi keliru → RA002 price_mismatch
--    3. kursi tidak mencukupi         → RA003 seats_unavailable
--    4. idempotency key               → pesanan sama, tidak dobel
--    5. promo RARAHEMAT               → potongan + plafon benar
--    6. pembatalan                    → kursi kembali, status cancelled
--    7. nomor kursi dobel             → ditolak, transaksi utuh
--    8. riwayat + daftar pesanan      → pagination & filter status
--    9. search_routes                 → pagination, filter kursi, urutan,
--                                       kota tak dikenal, jadwal virtual
--   10. detail rute + daftar kota
--   11. user_devices                  → pindah pemilik, nonaktifkan
--   12. pembayaran                    → webhook idempoten, lunas → confirmed
--   13. notifikasi                    → antrean, dedupe, klaim, retry, token basi
--   14. admin                         → peran, ubah status, stats, impor katalog
--   15. impor riwayat Firestore       → idempoten + pemetaan status lama
--   16. RPC pendukung Edge Function   → resolve_user_id, booking_rate_ok,
--                                       prepare_notification_job
--   17. tagihan oleh staf             → admin_create_payment + verifikasi manual
-- ============================================================================

insert into public.cities (id, name, slug, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Kota Uji Asal', 'kota-uji-asal', true),
  ('22222222-2222-2222-2222-222222222222', 'Kota Uji Tujuan', 'kota-uji-tujuan', true)
on conflict do nothing;

insert into public.routes (
  id, origin_city_id, destination_city_id, base_price, default_capacity,
  is_active, duration_minutes, slug, departure_times, via, facilities, is_popular, sort_order
) values (
  '33333333-3333-3333-3333-333333333333',
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  450000, 12, true, 660, 'uji-asal-uji-tujuan', '{06.00,19.00}', 'via Tol Trans Jawa',
  '{Door-to-Door,AC,Wifi}', true, 1
) on conflict do nothing;

insert into public.routes (
  id, origin_city_id, destination_city_id, base_price, default_capacity,
  is_active, duration_minutes, slug, departure_times, is_popular, sort_order
) values (
  '66666666-6666-6666-6666-666666666666',
  '22222222-2222-2222-2222-222222222222',
  '11111111-1111-1111-1111-111111111111',
  400000, 10, true, 700, 'uji-tujuan-uji-asal', '{07.00}', false, 2
) on conflict do nothing;

insert into public.users (id, firebase_uid, full_name, phone)
values ('44444444-4444-4444-4444-444444444444', 'firebase-uid-uji', 'Budi Uji', '+6281200000001')
on conflict do nothing;

insert into public.users (id, firebase_uid, full_name, phone)
values ('55555555-5555-5555-5555-555555555555', 'firebase-uid-uji-2', 'Siti Uji', '+6281200000002')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 1. create_booking bahagia
-- ---------------------------------------------------------------------------
do $$
declare
  v_res jsonb;
  v_kode text;
  v_sisa integer;
begin
  v_res := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 1, 'YYYY-MM-DD'),
      'departure_time', '06.00',
      'seats', 2,
      'contact_name', 'Budi Uji',
      'contact_phone', '0812-0000-0001',
      'pickup_address', 'Jl. Raya Juanda 59',
      'dropoff_address', 'Jl. Sudirman 1',
      'payment_method', 'Transfer Bank',
      'promo_code', 'RARAHEMAT',
      'client_total', 850000,
      'idempotency_key', 'uji-bahagia-1'
    )
  );

  v_kode := v_res->'booking'->>'kode';
  if v_kode is null or v_kode !~ '^RARA-[A-Z0-9]{6}$' then
    raise exception 'FAIL 1a: kode booking tidak sesuai (%)', v_kode;
  end if;
  if (v_res->'booking'->>'total')::numeric <> 850000 then
    raise exception 'FAIL 1b: total harus 850000, dapat %', v_res->'booking'->>'total';
  end if;
  if (v_res->'booking'->>'discount')::numeric <> 50000 then
    raise exception 'FAIL 1c: diskon promo RARAHEMAT harus 50000 (plafon), dapat %', v_res->'booking'->>'discount';
  end if;
  if (v_res->'booking'->>'status') <> 'pending' then
    raise exception 'FAIL 1d: status awal harus pending, dapat %', v_res->'booking'->>'status';
  end if;
  if (v_res->'booking'->>'status_label') <> 'Menunggu Konfirmasi' then
    raise exception 'FAIL 1e: label status salah (%)', v_res->'booking'->>'status_label';
  end if;
  if (v_res->'booking'->>'contact_phone') <> '+6281200000001' then
    raise exception 'FAIL 1f: nomor WA harus dinormalisasi +62, dapat %', v_res->'booking'->>'contact_phone';
  end if;
  if (v_res->'pricing'->>'remaining_seats')::integer <> 10 then
    raise exception 'FAIL 1g: sisa kursi harus 10, dapat %', v_res->'pricing'->>'remaining_seats';
  end if;

  select available_seats into v_sisa
    from public.route_schedules s
   where s.route_id = '33333333-3333-3333-3333-333333333333'
     and s.travel_date = current_date + 1;

  if v_sisa <> 10 then
    raise exception 'FAIL 1h: available_seats di jadwal harus 10, dapat %', v_sisa;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Validasi harga: total dari aplikasi yang keliru harus ditolak (RA002)
-- ---------------------------------------------------------------------------
do $$
declare
  v_sqlstate text;
  v_detail jsonb;
begin
  begin
    perform public.create_booking(
      '44444444-4444-4444-4444-444444444444',
      jsonb_build_object(
        'route_id', '33333333-3333-3333-3333-333333333333',
        'travel_date', to_char(current_date + 1, 'YYYY-MM-DD'),
        'departure_time', '06.00',
        'seats', 1,
        'contact_name', 'Budi Uji',
        'contact_phone', '08120000001',
        'client_total', 100000,
        'idempotency_key', 'uji-harga-1'
      )
    );
    raise exception 'FAIL 2a: seharusnya error price_mismatch';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    v_detail := null;
    if v_sqlstate <> 'RA002' then
      raise exception 'FAIL 2b: SQLSTATE harus RA002, dapat % (%)', v_sqlstate, sqlerrm;
    end if;
  end;

  -- harga klien yang benar harus lolos
  perform public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 1, 'YYYY-MM-DD'),
      'departure_time', '06.00',
      'seats', 1,
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'client_total', 450000,
      'idempotency_key', 'uji-harga-2'
    )
  );
end $$;

-- ---------------------------------------------------------------------------
-- 3. Kursi tidak cukup (RA003) — jadwal 14.00 kapasitas 12
-- ---------------------------------------------------------------------------
do $$
declare
  v_sqlstate text;
  v_detail text;
begin
  perform public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 2, 'YYYY-MM-DD'),
      'departure_time', '14:00',
      'seats', 10,
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'idempotency_key', 'uji-kursi-1'
    )
  );

  begin
    perform public.create_booking(
      '55555555-5555-5555-5555-555555555555',
      jsonb_build_object(
        'route_id', '33333333-3333-3333-3333-333333333333',
        'travel_date', to_char(current_date + 2, 'YYYY-MM-DD'),
        'departure_time', '14:00',
        'seats', 5,
        'contact_name', 'Siti Uji',
        'contact_phone', '08120000002',
        'idempotency_key', 'uji-kursi-2'
      )
    );
    raise exception 'FAIL 3a: seharusnya kursi tidak cukup';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_detail = pg_exception_detail;
    if v_sqlstate <> 'RA003' then
      raise exception 'FAIL 3b: SQLSTATE harus RA003, dapat % (%)', v_sqlstate, sqlerrm;
    end if;
    if (v_detail::jsonb->>'available')::integer <> 2 then
      raise exception 'FAIL 3c: detail sisa kursi harus 2, dapat %', v_detail;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Idempotency: permintaan ulang tidak membuat booking kedua
-- ---------------------------------------------------------------------------
do $$
declare
  v_1 jsonb;
  v_2 jsonb;
  v_jumlah integer;
begin
  v_1 := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 3, 'YYYY-MM-DD'),
      'departure_time', '06:00',
      'seats', 1,
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'idempotency_key', 'uji-idempotent-1'
    )
  );

  v_2 := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 3, 'YYYY-MM-DD'),
      'departure_time', '06:00',
      'seats', 1,
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'idempotency_key', 'uji-idempotent-1'
    )
  );

  if v_1->'booking'->>'kode' <> v_2->'booking'->>'kode' then
    raise exception 'FAIL 4a: kode berbeda pada permintaan ulang (% vs %)',
      v_1->'booking'->>'kode', v_2->'booking'->>'kode';
  end if;
  if (v_2->>'idempotent')::boolean is not true then
    raise exception 'FAIL 4b: flag idempotent harus true';
  end if;

  select count(*) into v_jumlah
    from public.bookings b
   where b.idempotency_key = 'uji-idempotent-1';
  if v_jumlah <> 1 then
    raise exception 'FAIL 4c: booking ganda terbentuk (%)', v_jumlah;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5 + 6. Pembatalan mengembalikan kursi + promo dihitung benar
-- ---------------------------------------------------------------------------
do $$
declare
  v_res jsonb;
  v_kode text;
  v_cancel jsonb;
  v_sisa integer;
  v_diskon numeric;
begin
  v_res := public.create_booking(
    '55555555-5555-5555-5555-555555555555',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 5, 'YYYY-MM-DD'),
      'departure_time', '19.00',
      'seats', 4,
      'contact_name', 'Siti Uji',
      'contact_phone', '6281200000002',
      'promo_code', 'rarahemat',
      'idempotency_key', 'uji-batal-1'
    )
  );
  v_kode := v_res->'booking'->>'kode';
  v_diskon := (v_res->'booking'->>'discount')::numeric;

  if v_diskon <> 50000 then
    raise exception 'FAIL 5a: diskon 4x450000 = 180000 → plafon 50000, dapat %', v_diskon;
  end if;
  if (v_res->'booking'->>'total')::numeric <> 1750000 then
    raise exception 'FAIL 5b: total harus 1750000, dapat %', v_res->'booking'->>'total';
  end if;

  v_cancel := public.cancel_booking(
    '55555555-5555-5555-5555-555555555555',
    v_kode,
    'berubah rencana'
  );

  if v_cancel->'booking'->>'status' <> 'cancelled' then
    raise exception 'FAIL 6a: status harus cancelled, dapat %', v_cancel->'booking'->>'status';
  end if;
  if (v_cancel->>'changed')::boolean is not true then
    raise exception 'FAIL 6b: flag changed harus true';
  end if;
  if (v_cancel->>'released_seats')::integer <> 4 then
    raise exception 'FAIL 6c: kursi yang dikembalikan harus 4';
  end if;

  select available_seats into v_sisa
    from public.route_schedules s
   where s.travel_date = current_date + 5
     and s.departure_time = '19:00';
  if v_sisa <> 12 then
    raise exception 'FAIL 6d: sisa kursi harus kembali 12, dapat %', v_sisa;
  end if;

  -- membatalkan dua kali tidak mengubah apa pun dan tidak menambah kursi
  v_cancel := public.cancel_booking('55555555-5555-5555-5555-555555555555', v_kode, null);
  if (v_cancel->>'changed')::boolean is not false then
    raise exception 'FAIL 6e: pembatalan kedua harus changed=false';
  end if;

  select available_seats into v_sisa
    from public.route_schedules s
   where s.travel_date = current_date + 5
     and s.departure_time = '19:00';
  if v_sisa <> 12 then
    raise exception 'FAIL 6f: kursi tidak boleh bertambah dari pembatalan ganda, dapat %', v_sisa;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Nomor kursi dobel harus ditolak (RA003) dan transaksi tidak separuh jalan
-- ---------------------------------------------------------------------------
do $$
declare
  v_sqlstate text;
  v_jumlah integer;
begin
  perform public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 7, 'YYYY-MM-DD'),
      'departure_time', '06:00',
      'seats', 2,
      'seat_numbers', jsonb_build_array(1, 2),
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'idempotency_key', 'uji-kursi-nomor-1'
    )
  );

  begin
    perform public.create_booking(
      '55555555-5555-5555-5555-555555555555',
      jsonb_build_object(
        'route_id', '33333333-3333-3333-3333-333333333333',
        'travel_date', to_char(current_date + 7, 'YYYY-MM-DD'),
        'departure_time', '06:00',
        'seats', 1,
        'seat_numbers', jsonb_build_array(1),
        'contact_name', 'Siti Uji',
        'contact_phone', '08120000002',
        'idempotency_key', 'uji-kursi-nomor-2'
      )
    );
    raise exception 'FAIL 7a: kursi 1 seharusnya sudah dipesan';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    if v_sqlstate <> 'RA003' then
      raise exception 'FAIL 7b: SQLSTATE harus RA003, dapat % (%)', v_sqlstate, sqlerrm;
    end if;
  end;

  -- booking yang gagal tidak boleh menyisakan data (rollback penuh)
  select count(*) into v_jumlah
    from public.bookings b
   where b.idempotency_key = 'uji-kursi-nomor-2';
  if v_jumlah <> 0 then
    raise exception 'FAIL 7c: booking gagal seharusnya tidak tersimpan';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Riwayat status + daftar pesanan berpaginasi
-- ---------------------------------------------------------------------------
do $$
declare
  v_list jsonb;
  v_riwayat integer;
begin
  v_list := public.list_my_bookings('44444444-4444-4444-4444-444444444444', 2, 0, null);
  if jsonb_array_length(v_list->'items') <> 2 then
    raise exception 'FAIL 8a: limit=2 harus mengembalikan 2 item, dapat %', jsonb_array_length(v_list->'items');
  end if;
  if (v_list->>'has_more')::boolean is not true then
    raise exception 'FAIL 8b: has_more harus true';
  end if;
  if (v_list->>'total')::integer < 3 then
    raise exception 'FAIL 8c: total pesanan salah (%)', v_list->>'total';
  end if;

  select count(*) into v_riwayat
    from public.booking_status_history h
    join public.bookings b on b.id = h.booking_id
   where b.idempotency_key = 'uji-idempotent-1';
  if v_riwayat <> 1 then
    raise exception 'FAIL 8d: riwayat status awal harus 1 baris, dapat %', v_riwayat;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. search_routes: pagination, filter kursi, urutan harga, kota tak dikenal
-- ---------------------------------------------------------------------------
do $$
declare
  v_res jsonb;
  v_asc jsonb;
begin
  v_res := public.search_routes('Kota Uji Asal', 'Kota Uji Tujuan', null, 1, null, 'popular', 10, 0);
  if (v_res->>'total')::integer <> 1 then
    raise exception 'FAIL 9a: total rute harus 1, dapat %', v_res->>'total';
  end if;
  -- Tanpa tanggal: maksimal satu jadwal per jam (jam terdekat yang tersedia)
  -- dan jadwal pertama harus jam paling awal (06.00).
  if (select count(*) from jsonb_array_elements(v_res->'items'->0->'schedules') s)
     <> (select count(distinct s->>'departure_time') from jsonb_array_elements(v_res->'items'->0->'schedules') s) then
    raise exception 'FAIL 9b: jam tidak boleh ganda pada hasil tanpa tanggal, dapat %',
      v_res->'items'->0->'schedules';
  end if;
  if (v_res->'items'->0->'schedules'->0->>'departure_time') <> '06:00' then
    raise exception 'FAIL 9b2: jadwal pertama harus 06:00, dapat %',
      v_res->'items'->0->'schedules'->0->>'departure_time';
  end if;
  if (v_res->'items'->0->'schedules'->0->>'travel_date') <> to_char(current_date + 1, 'YYYY-MM-DD') then
    raise exception 'FAIL 9b3: jadwal 06.00 harus yang terdekat (besok), dapat %',
      v_res->'items'->0->'schedules'->0->>'travel_date';
  end if;
  if (v_res->'items'->0->>'price_from')::numeric <> 450000 then
    raise exception 'FAIL 9c: harga dari harus 450000, dapat %', v_res->'items'->0->>'price_from';
  end if;
  if (v_res->'items'->0->'schedules'->0->>'departure_time_label') <> '06.00' then
    raise exception 'FAIL 9d: label jam salah (%)', v_res->'items'->0->'schedules'->0->>'departure_time_label';
  end if;

  -- filter penumpang: jadwal 06.00 (12 kursi) di tanggal +7 sudah terisi 2 kursi
  v_res := public.search_routes('Kota Uji Asal', 'Kota Uji Tujuan', current_date + 7, 11, null, 'popular', 10, 0);
  if (v_res->>'total')::integer <> 1 then
    raise exception 'FAIL 9e: rute harus tetap muncul (jadwal 19.00 kosong)';
  end if;
  if jsonb_array_length(v_res->'items'->0->'schedules') <> 1 then
    raise exception 'FAIL 9f: hanya jadwal 19.00 yang cukup untuk 11 kursi, dapat %',
      v_res->'items'->0->'schedules';
  end if;

  -- urutan harga menaik: 400000 (Jakarta–Surabaya) lebih dulu
  v_asc := public.search_routes(null, null, null, 1, null, 'price_asc', 10, 0);
  if (v_asc->'items'->0->>'price_from')::numeric > (v_asc->'items'->1->>'price_from')::numeric then
    raise exception 'FAIL 9g: urutan price_asc salah';
  end if;

  -- pagination
  v_res := public.search_routes(null, null, null, 1, null, 'price_asc', 1, 0);
  if jsonb_array_length(v_res->'items') <> 1 or (v_res->>'has_more')::boolean is not true then
    raise exception 'FAIL 9h: pagination limit=1 salah (%)', v_res->>'has_more';
  end if;

  -- kota tidak dikenal → alasan jelas, bukan error
  v_res := public.search_routes('Kota Tidak Ada', null, null, 1, null, 'popular', 10, 0);
  if (v_res->>'reason') <> 'origin_not_found' then
    raise exception 'FAIL 9i: reason harus origin_not_found, dapat %', v_res->>'reason';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Detail rute + daftar kota
-- ---------------------------------------------------------------------------
do $$
declare
  v_detail jsonb;
  v_kota jsonb;
  v_sewa jsonb;
  v_wisata jsonb;
  v_armada jsonb;
begin
  v_detail := public.get_route_detail('uji-asal-uji-tujuan', null);
  if v_detail->>'origin' <> 'Kota Uji Asal' or v_detail->>'destination' <> 'Kota Uji Tujuan' then
    raise exception 'FAIL 10a: detail rute salah (%)', v_detail;
  end if;
  if jsonb_array_length(v_detail->'facilities') <> 3 then
    raise exception 'FAIL 10b: fasilitas harus 3, dapat %', v_detail->'facilities';
  end if;

  v_kota := public.catalog_cities(null);
  if jsonb_array_length(v_kota) < 2 then
    raise exception 'FAIL 10c: kota aktif harus ≥2';
  end if;

  -- Sewa mobil & paket wisata (data seed ikut diuji)
  v_sewa := public.list_rental_packages(null, null, 5, 0);
  if (v_sewa->>'total')::integer < 1 then
    raise exception 'FAIL 10d: minimal 1 paket sewa dari seed katalog';
  end if;
  if jsonb_array_length(v_sewa->'items') < 1 or (v_sewa->'items'->0->>'price_from')::numeric < 1 then
    raise exception 'FAIL 10e: harga sewa harus terbaca dari tabel harga (%)', v_sewa->'items'->0;
  end if;
  if (v_sewa->'items'->0->>'city') is null then
    raise exception 'FAIL 10f: paket sewa harus menyertakan kota';
  end if;

  v_wisata := public.list_tour_packages(null, 5, 0);
  if (v_wisata->>'total')::integer < 1 or (v_wisata->'items'->0->>'price_from')::numeric < 1 then
    raise exception 'FAIL 10g: paket wisata dari seed harus punya harga';
  end if;

  v_armada := public.list_vehicles();
  if jsonb_array_length(v_armada) < 1 then
    raise exception 'FAIL 10h: daftar armada tidak boleh kosong';
  end if;

  -- pagination paket wisata
  v_wisata := public.list_tour_packages(null, 1, 0);
  if jsonb_array_length(v_wisata->'items') <> 1 or (v_wisata->>'has_more')::boolean is not true then
    raise exception 'FAIL 10i: pagination paket wisata salah (%)', v_wisata->>'has_more';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. user_devices: daftar token FCM, pindah pemilik, nonaktifkan
-- ---------------------------------------------------------------------------
do $$
declare
  v_hasil jsonb;
  v_pemilik uuid;
  v_aktif boolean;
begin
  v_hasil := public.register_user_device(
    '44444444-4444-4444-4444-444444444444',
    'fcm-token-uji-abcdefghij',
    'android', 'Pixel Uji', '1.0.0+1', 'id_ID'
  );
  if (v_hasil->>'is_active')::boolean is not true then
    raise exception 'FAIL 11a: perangkat harus aktif';
  end if;

  -- token sama didaftarkan akun lain → pindah pemilik (bukan duplikat)
  perform public.register_user_device(
    '55555555-5555-5555-5555-555555555555',
    'fcm-token-uji-abcdefghij', 'android', null, null, null
  );
  select d.user_id into v_pemilik from public.user_devices d where d.fcm_token = 'fcm-token-uji-abcdefghij';
  if v_pemilik <> '55555555-5555-5555-5555-555555555555' then
    raise exception 'FAIL 11b: token harus pindah ke akun baru';
  end if;

  v_hasil := public.unregister_user_device('55555555-5555-5555-5555-555555555555', 'fcm-token-uji-abcdefghij');
  if (v_hasil->>'deactivated')::integer <> 1 then
    raise exception 'FAIL 11c: harus 1 perangkat dinonaktifkan';
  end if;

  select d.is_active into v_aktif from public.user_devices d where d.fcm_token = 'fcm-token-uji-abcdefghij';
  if v_aktif then
    raise exception 'FAIL 11d: perangkat seharusnya nonaktif';
  end if;

  -- pulihkan untuk uji notifikasi
  perform public.register_user_device('44444444-4444-4444-4444-444444444444', 'fcm-token-uji-abcdefghij', 'android', null, null, null);
end $$;

-- ---------------------------------------------------------------------------
-- 12. Pembayaran: create_payment + webhook idempoten + lunas → terkonfirmasi
-- ---------------------------------------------------------------------------
do $$
declare
  v_booking jsonb;
  v_kode text;
  v_payment jsonb;
  v_event jsonb;
  v_ulang jsonb;
  v_palsu jsonb;
  v_status jsonb;
  v_booking_id uuid;
begin
  v_booking := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 10, 'YYYY-MM-DD'),
      'departure_time', '06:00',
      'seats', 1,
      'contact_name', 'Budi Uji',
      'contact_phone', '08120000001',
      'idempotency_key', 'uji-bayar-1'
    )
  );
  v_kode := v_booking->'booking'->>'kode';
  v_booking_id := (v_booking->'booking'->>'id')::uuid;

  v_payment := public.create_payment(
    '44444444-4444-4444-4444-444444444444', v_kode, 'midtrans', 'qris',
    null, 'ORDER-UJI-1', 'https://checkout.contoh/ORDER-UJI-1', now() + interval '1 hour'
  );
  if (v_payment->'payment'->>'amount')::numeric <> 450000 then
    raise exception 'FAIL 12a: nominal tagihan harus 450000, dapat %', v_payment->'payment'->>'amount';
  end if;
  if v_payment->'booking'->>'payment_status' <> 'pending' then
    raise exception 'FAIL 12b: payment_status booking harus pending, dapat %', v_payment->'booking'->>'payment_status';
  end if;

  -- webhook sah: lunas → booking terkonfirmasi otomatis
  v_event := public.apply_payment_event(
    'midtrans', 'evt-uji-1', 'settlement', 'paid', 'ORDER-UJI-1', 450000,
    jsonb_build_object('order_id', 'ORDER-UJI-1'), true
  );
  if (v_event->>'ok')::boolean is not true or (v_event->>'duplicate')::boolean is not false then
    raise exception 'FAIL 12c: event pertama harus ok & bukan duplikat (%)', v_event;
  end if;
  if v_event->'booking'->>'status' <> 'confirmed' then
    raise exception 'FAIL 12d: booking harus confirmed setelah lunas, dapat %', v_event->'booking'->>'status';
  end if;
  if v_event->'booking'->>'payment_status' <> 'paid' then
    raise exception 'FAIL 12e: payment_status harus paid';
  end if;

  -- webhook dikirim ulang provider → tidak diproses dua kali
  v_ulang := public.apply_payment_event(
    'midtrans', 'evt-uji-1', 'settlement', 'paid', 'ORDER-UJI-1', 450000,
    jsonb_build_object('order_id', 'ORDER-UJI-1'), true
  );
  if (v_ulang->>'duplicate')::boolean is not true then
    raise exception 'FAIL 12f: event ulang harus duplicate=true';
  end if;

  -- tanda tangan palsu → tidak mengubah apa pun
  v_palsu := public.apply_payment_event(
    'midtrans', 'evt-uji-palsu', 'settlement', 'paid', 'ORDER-UJI-1', 450000,
    '{}'::jsonb, false
  );
  if (v_palsu->>'ok')::boolean is not false or (v_palsu->>'reason') <> 'invalid_signature' then
    raise exception 'FAIL 12g: tanda tangan palsu harus ditolak (%)', v_palsu;
  end if;

  v_status := public.payment_status_for_booking('44444444-4444-4444-4444-444444444444', v_kode);
  if (v_status->>'remaining_amount')::numeric <> 0 then
    raise exception 'FAIL 12h: sisa tagihan harus 0, dapat %', v_status->>'remaining_amount';
  end if;

  -- pembayaran sebagian (DP) pada pesanan lain
  v_booking := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 11, 'YYYY-MM-DD'),
      'departure_time', '06:00', 'seats', 2,
      'contact_name', 'Budi Uji', 'contact_phone', '08120000001',
      'idempotency_key', 'uji-bayar-2'
    )
  );
  v_kode := v_booking->'booking'->>'kode';
  perform public.create_payment('44444444-4444-4444-4444-444444444444', v_kode, 'manual', 'Transfer Bank', 300000, null, null, now() + interval '2 hours');
  v_event := public.apply_payment_event(
    'manual', 'evt-uji-2', 'transfer diterima', 'paid', null, 300000, '{}'::jsonb, true
  );
  if (v_event->'booking'->>'payment_status') <> 'partial' then
    raise exception 'FAIL 12i: DP harus berstatus partial, dapat %', v_event->'booking'->>'payment_status';
  end if;
  if (v_event->'booking'->>'status') <> 'pending' then
    raise exception 'FAIL 12j: status booking belum boleh confirmed sebelum lunas, dapat %', v_event->'booking'->>'status';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 13. Notifikasi: antrean otomatis, dedupe, klaim, retry, token basi
-- ---------------------------------------------------------------------------
do $$
declare
  v_jumlah integer;
  v_klaim jsonb;
  v_job jsonb;
  v_job_id uuid;
  v_hasil jsonb;
  v_aktif boolean;
begin
  -- Tiap booking pada uji di atas membuat 1 job; status berubah → job tambahan.
  select count(*) into v_jumlah
    from public.notification_jobs j
    join public.bookings b on b.id = j.booking_id
   where b.idempotency_key = 'uji-bayar-1';
  if v_jumlah < 2 then
    raise exception 'FAIL 13a: booking lunas harus punya ≥2 notifikasi (dibuat + terkonfirmasi), dapat %', v_jumlah;
  end if;

  select max(j.attempts) into v_jumlah from public.notification_jobs j;
  if v_jumlah <> 0 then
    raise exception 'FAIL 13b: job baru tidak boleh punya attempt, dapat %', v_jumlah;
  end if;

  v_klaim := public.claim_notification_jobs(5);
  if (v_klaim->>'count')::integer < 1 then
    raise exception 'FAIL 13c: harus ada job yang bisa diklaim';
  end if;
  v_job := v_klaim->'jobs'->0;
  v_job_id := (v_job->>'job_id')::uuid;
  if jsonb_array_length(v_job->'tokens') < 1 then
    raise exception 'FAIL 13d: job harus membawa token perangkat aktif (%)', v_job;
  end if;
  if v_job->>'title' is null or v_job->>'body' is null then
    raise exception 'FAIL 13e: judul/isi notifikasi tidak boleh kosong';
  end if;

  -- klaim berikutnya tidak mengambil job yang sedang dipegang instance lain
  v_hasil := public.claim_notification_jobs(50);
  if v_hasil::text like '%' || v_job_id::text || '%' then
    raise exception 'FAIL 13f: job yang sudah diklaim tidak boleh diklaim ulang';
  end if;

  -- gagal kirim → kembali ke antrean dengan backoff (5 menit × percobaan)
  v_hasil := public.complete_notification_job(v_job_id, false, 'fcm 503', null, null);
  if (v_hasil->>'status') <> 'queued' then
    raise exception 'FAIL 13g: gagal sementara harus kembali queued, dapat %', v_hasil->>'status';
  end if;
  if (v_hasil->>'attempts')::integer <> 1 then
    raise exception 'FAIL 13g2: percobaan harus tercatat 1, dapat %', v_hasil->>'attempts';
  end if;

  -- Job yang sedang backoff tidak boleh langsung diklaim lagi.
  v_klaim := public.claim_notification_jobs(50);
  if v_klaim::text like '%' || v_job_id::text || '%' then
    raise exception 'FAIL 13g3: job backoff tidak boleh diklaim sebelum waktunya';
  end if;

  -- Percobaan ke-2 gagal, sekaligus menandai token basi (app di-uninstall).
  update public.notification_jobs j set scheduled_at = now() - interval '1 second' where j.id = v_job_id;
  v_klaim := public.claim_notification_jobs(50);
  if v_klaim::text not like '%' || v_job_id::text || '%' then
    raise exception 'FAIL 13g4: job harus bisa diklaim setelah backoff lewat';
  end if;
  v_hasil := public.complete_notification_job(
    v_job_id, false, 'token mati', null, array['fcm-token-uji-abcdefghij']
  );
  if (v_hasil->>'invalid_tokens_deactivated')::integer <> 1 then
    raise exception 'FAIL 13h: token basi harus mengubah 1 perangkat, dapat %', v_hasil->>'invalid_tokens_deactivated';
  end if;
  select d.is_active into v_aktif from public.user_devices d where d.fcm_token = 'fcm-token-uji-abcdefghij';
  if v_aktif then
    raise exception 'FAIL 13h2: token basi harus ditandai nonaktif';
  end if;

  -- Percobaan ke-3 (terakhir) gagal → status failed
  update public.notification_jobs j set scheduled_at = now() - interval '1 second' where j.id = v_job_id;
  v_klaim := public.claim_notification_jobs(50);
  v_hasil := public.complete_notification_job(v_job_id, false, 'gagal terus', null, null);
  if (v_hasil->>'status') <> 'failed' then
    raise exception 'FAIL 13i: setelah 3 percobaan job harus failed, dapat %', v_hasil->>'status';
  end if;
  if (v_hasil->>'attempts')::integer <> 3 then
    raise exception 'FAIL 13i2: percobaan harus 3, dapat %', v_hasil->>'attempts';
  end if;

  -- Job yang sudah habis percobaan tidak boleh diklaim lagi
  v_klaim := public.claim_notification_jobs(50);
  if v_klaim::text like '%' || v_job_id::text || '%' then
    raise exception 'FAIL 13j: job failed yang sudah habis percobaan tidak boleh diklaim lagi';
  end if;

  -- Kirim sukses menutup job
  update public.notification_jobs j
     set scheduled_at = now() - interval '1 second', attempts = 0
   where j.id = v_job_id;
  v_klaim := public.claim_notification_jobs(50);
  v_hasil := public.complete_notification_job(v_job_id, true, null, 'fcm-msg-1', null);
  if (v_hasil->>'status') <> 'sent' then
    raise exception 'FAIL 13k: kirim sukses harus sent, dapat %', v_hasil->>'status';
  end if;

  if public.notification_queue_summary() is null then
    raise exception 'FAIL 13l: ringkasan antrean harus tersedia';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 14. Admin: pembatasan peran, ubah status, stats, impor katalog & riwayat
-- ---------------------------------------------------------------------------
do $$
declare
  v_sqlstate text;
  v_hasil jsonb;
  v_kode text;
  v_booking jsonb;
  v_sisa integer;
begin
  insert into public.users (id, firebase_uid, full_name, role)
  values ('77777777-7777-7777-7777-777777777777', 'firebase-uid-admin', 'Admin Uji', 'admin')
  on conflict do nothing;

  insert into public.users (id, firebase_uid, full_name, role)
  values ('88888888-8888-8888-8888-888888888888', 'firebase-uid-operator', 'Operator Uji', 'operator')
  on conflict do nothing;

  -- 14a. Pengguna biasa TIDAK boleh memakai fungsi admin
  begin
    perform public.admin_stats('44444444-4444-4444-4444-444444444444');
    raise exception 'FAIL 14a: pengguna biasa seharusnya ditolak';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    if v_sqlstate <> 'RA006' then
      raise exception 'FAIL 14a2: SQLSTATE harus RA006 (forbidden), dapat % (%)', v_sqlstate, sqlerrm;
    end if;
  end;

  -- 14b. Siapkan pesanan untuk diubah admin
  v_booking := public.create_booking(
    '44444444-4444-4444-4444-444444444444',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 14, 'YYYY-MM-DD'),
      'departure_time', '06:00', 'seats', 3,
      'contact_name', 'Budi Uji', 'contact_phone', '08120000001',
      'idempotency_key', 'uji-admin-1'
    )
  );
  v_kode := v_booking->'booking'->>'kode';

  -- 14c. Operator mengonfirmasi pesanan
  v_hasil := public.admin_set_booking_status(
    '88888888-8888-8888-8888-888888888888', v_kode, 'Dikonfirmasi', 'sudah transfer'
  );
  if v_hasil->'booking'->>'status' <> 'confirmed' then
    raise exception 'FAIL 14c: status harus confirmed, dapat %', v_hasil->'booking'->>'status';
  end if;
  if (v_hasil->'booking'->>'confirmed_at') is null then
    raise exception 'FAIL 14c2: confirmed_at harus terisi';
  end if;

  -- 14d. Membatalkan pesanan mengembalikan kursi
  select available_seats into v_sisa
    from public.route_schedules s
   where s.travel_date = current_date + 14 and s.departure_time = '06:00';

  v_hasil := public.admin_set_booking_status(
    '77777777-7777-7777-7777-777777777777', v_kode, 'cancelled', 'pelanggan minta batal'
  );
  if v_hasil->'booking'->>'status' <> 'cancelled' or (v_hasil->>'released_seats')::integer <> 3 then
    raise exception 'FAIL 14d: pembatalan admin harus melepas 3 kursi (%)', v_hasil;
  end if;
  if (select available_seats from public.route_schedules s
       where s.travel_date = current_date + 14 and s.departure_time = '06:00') <> v_sisa + 3 then
    raise exception 'FAIL 14d2: kursi tidak kembali setelah dibatalkan admin';
  end if;

  -- 14e. Riwayat status mencatat pelaku & tidak bisa diubah dua kali
  v_hasil := public.admin_set_booking_status('77777777-7777-7777-7777-777777777777', v_kode, 'cancelled', null);
  if (v_hasil->>'changed')::boolean is not false then
    raise exception 'FAIL 14e: pengulangan status sama harus changed=false';
  end if;

  -- 14f. Ringkasan admin
  v_hasil := public.admin_stats('77777777-7777-7777-7777-777777777777');
  if (v_hasil->>'bookings_total')::integer < 1 or (v_hasil->>'users_total')::integer < 2 then
    raise exception 'FAIL 14f: ringkasan admin tidak wajar (%)', v_hasil;
  end if;
  if (v_hasil->'notifications'->>'queued')::integer < 0 then
    raise exception 'FAIL 14f2: ringkasan notifikasi harus ada';
  end if;

  -- 14g. Daftar pesanan admin + pencarian
  v_hasil := public.admin_list_bookings('88888888-8888-8888-8888-888888888888', null, v_kode, null, 5, 0);
  if (v_hasil->>'total')::integer <> 1 then
    raise exception 'FAIL 14g: pencarian kode harus menemukan 1 pesanan, dapat %', v_hasil->>'total';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 15. Impor riwayat Firestore (idempoten) + impor katalog
-- ---------------------------------------------------------------------------
do $$
declare
  v_batch jsonb;
  v_hasil jsonb;
  v_ulang jsonb;
  v_booking public.bookings;
  v_uid_baru integer;
begin
  v_batch := jsonb_build_array(
    jsonb_build_object(
      'kode', 'RARA-LEGACY1', 'userId', 'firebase-uid-uji',
      'asal', 'Surabaya', 'tujuan', 'Jakarta',
      'tanggal', to_char(current_date - 20, 'YYYY-MM-DD'), 'jam', '06.00',
      'nama', 'Budi Uji', 'wa', '0812-0000-0001',
      'jemput', 'Jl. Juanda 59', 'antar', 'Jl. Sudirman 1',
      'kursi', 2, 'totalHarga', 900000, 'metodeBayar', 'Transfer Bank',
      'status', 'Dikonfirmasi', 'promo', '', 'diskon', 0,
      'createdAt', '2026-08-01T03:00:00.000Z'
    ),
    jsonb_build_object(
      'kode', 'RARA-LEGACY2', 'userId', 'firebase-uid-legacy-baru',
      'asal', 'Kota Kecil', 'tujuan', 'Kota Uji Baru',
      'tanggal', to_char(current_date + 20, 'YYYY-MM-DD'), 'jam', '21:00',
      'nama', 'Pelanggan Lama', 'wa', '6281299999999',
      'kursi', 1, 'totalHarga', 150000,
      'status', 'Menunggu Konfirmasi',
      'createdAt', '2026-08-05T03:00:00.000Z'
    )
  );

  -- 15a. Uji kering: tidak menulis apa pun
  v_hasil := public.import_legacy_bookings(v_batch, true);
  if (v_hasil->>'inserted')::integer <> 2 or (v_hasil->>'dry_run')::boolean is not true then
    raise exception 'FAIL 15a: dry run harus melaporkan 2 kandidat (%)', v_hasil;
  end if;
  if exists (select 1 from public.bookings where kode in ('RARA-LEGACY1', 'RARA-LEGACY2')) then
    raise exception 'FAIL 15a2: dry run tidak boleh menulis data';
  end if;

  -- 15b. Impor sesungguhnya
  v_hasil := public.import_legacy_bookings(v_batch, false);
  if (v_hasil->>'inserted')::integer <> 2 or (v_hasil->>'failed')::integer <> 0 then
    raise exception 'FAIL 15b: impor harus berhasil 2 tanpa gagal (%)', v_hasil;
  end if;

  select * into v_booking from public.bookings b where b.kode = 'RARA-LEGACY1';
  if v_booking.status <> 'confirmed' or v_booking.payment_status <> 'paid' then
    raise exception 'FAIL 15c: "Dikonfirmasi" harus jadi confirmed + paid, dapat % / %',
      v_booking.status, v_booking.payment_status;
  end if;
  if v_booking.created_at <> '2026-08-01T03:00:00Z'::timestamptz then
    raise exception 'FAIL 15d: tanggal dibuat harus terjaga, dapat %', v_booking.created_at;
  end if;

  -- Pengguna lama tanpa akun dibuat otomatis
  select count(*) into v_uid_baru from public.users u where u.firebase_uid = 'firebase-uid-legacy-baru';
  if v_uid_baru <> 1 then
    raise exception 'FAIL 15e: akun pemilik pesanan lama harus dibuat otomatis';
  end if;

  -- 15f. Impor ulang: semuanya dilewati (data baru tidak ditimpa)
  v_ulang := public.import_legacy_bookings(v_batch, false);
  if (v_ulang->>'skipped')::integer <> 2 or (v_ulang->>'inserted')::integer <> 0 then
    raise exception 'FAIL 15f: impor ulang harus melewati 2 pesanan (%)', v_ulang;
  end if;

  -- 15g. Rute historis tidak boleh muncul di pencarian
  v_hasil := public.search_routes('Kota Kecil', 'Kota Uji Baru', null, 1, null, 'popular', 5, 0);
  if (v_hasil->>'total')::integer <> 0 then
    raise exception 'FAIL 15g: rute historis (is_active=false) tidak boleh tampil di pencarian';
  end if;

  -- 15h. Impor katalog oleh admin
  v_hasil := public.admin_import_catalog(
    '77777777-7777-7777-7777-777777777777',
    jsonb_build_object(
      'cities', jsonb_build_array(jsonb_build_object('name', 'Kota Impor', 'province', 'Jawa Timur')),
      'vehicles', jsonb_build_array(jsonb_build_object('name', 'Hiace Impor', 'seat_capacity', 12, 'vehicle_type', 'Van')),
      'routes', jsonb_build_array(jsonb_build_object(
        'origin', 'Kota Impor', 'destination', 'Kota Uji Tujuan',
        'base_price', 375000, 'departure_times', jsonb_build_array('05.30', '17.00'),
        'duration_minutes', 480, 'default_capacity', 12
      )),
      'schedules', jsonb_build_array(jsonb_build_object(
        'origin', 'Kota Impor', 'destination', 'Kota Uji Tujuan',
        'travel_date', to_char(current_date + 4, 'YYYY-MM-DD'),
        'departure_time', '05.30', 'price', 395000, 'capacity', 12
      )),
      'tour_packages', jsonb_build_array(jsonb_build_object(
        'name', 'Paket Impor Uji', 'destination', 'Gunung Uji',
        'price', 275000, 'duration_days', 1
      ))
    )
  );
  if (v_hasil->'counts'->>'cities')::integer <> 1
     or (v_hasil->'counts'->>'routes')::integer <> 1
     or (v_hasil->'counts'->>'schedules')::integer <> 1 then
    raise exception 'FAIL 15h: hasil impor katalog tidak sesuai (%)', v_hasil;
  end if;

  -- Rute hasil impor muncul dengan jadwal sesuai pola + jadwal khusus tanggal
  v_hasil := public.search_routes('Kota Impor', 'Kota Uji Tujuan', current_date + 4, 1, null, 'popular', 5, 0);
  if (v_hasil->>'total')::integer <> 1 then
    raise exception 'FAIL 15i: rute hasil impor harus bisa dicari (%)', v_hasil->>'total';
  end if;
  -- Jadwal khusus tanggal itu memakai harga sendiri (395000), sedangkan jam
  -- lain yang belum punya baris jadwal tetap memakai harga dasar (375000).
  if (v_hasil->'items'->0->>'price_from')::numeric <> 375000 then
    raise exception 'FAIL 15j: harga terendah harus 375000 (jam 17.00), dapat %',
      v_hasil->'items'->0->>'price_from';
  end if;
  if (v_hasil->'items'->0->'schedules'->0->>'departure_time') <> '05:30'
     or (v_hasil->'items'->0->'schedules'->0->>'price')::numeric <> 395000
     or (v_hasil->'items'->0->'schedules'->0->>'is_virtual')::boolean is not false then
    raise exception 'FAIL 15j2: jadwal khusus 05.30 harus berharga 395000 (%)',
      v_hasil->'items'->0->'schedules'->0;
  end if;
  if (v_hasil->'items'->0->'schedules'->1->>'departure_time') <> '17:00'
     or (v_hasil->'items'->0->'schedules'->1->>'is_virtual')::boolean is not true then
    raise exception 'FAIL 15j3: jadwal 17.00 harus muncul sebagai jadwal virtual (%)',
      v_hasil->'items'->0->'schedules'->1;
  end if;

  -- Operator tidak boleh mengimpor katalog (hanya admin/super_admin)
  begin
    perform public.admin_import_catalog('88888888-8888-8888-8888-888888888888', jsonb_build_object('cities', '[]'::jsonb));
    raise exception 'FAIL 15k: operator seharusnya tidak boleh impor katalog';
  exception when others then
    if sqlerrm not like '%tidak punya akses admin%' then
      raise exception 'FAIL 15k2: pesan penolakan salah (%)', sqlerrm;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 16. RPC pendukung Edge Function: pemetaan user, rem laju, kirim 1 job
-- ---------------------------------------------------------------------------
do $$
declare
  v_hasil jsonb;
  v_user_id uuid;
  v_job_id uuid;
begin
  -- 16a. Firebase UID → users.id
  v_user_id := public.resolve_user_id('firebase-uid-uji');
  if v_user_id <> '44444444-4444-4444-4444-444444444444' then
    raise exception 'FAIL 16a: pemetaan firebase uid salah (%)', v_user_id;
  end if;
  if public.resolve_user_id('uid-tidak-ada') is not null then
    raise exception 'FAIL 16a2: uid tak dikenal harus null';
  end if;

  -- 16b. Rem laju pembuatan pesanan
  v_hasil := public.booking_rate_ok('44444444-4444-4444-4444-444444444444', 3, 60);
  if (v_hasil->>'allowed')::boolean is not false then
    raise exception 'FAIL 16b: pengguna dengan banyak pesanan harus kena rem (%)', v_hasil;
  end if;
  v_hasil := public.booking_rate_ok('55555555-5555-5555-5555-555555555555', 100, 60);
  if (v_hasil->>'allowed')::boolean is not true then
    raise exception 'FAIL 16b2: di bawah batas harus diizinkan (%)', v_hasil;
  end if;

  -- 16c. Kirim satu job langsung (dipanggil trigger setelah HTTP request)
  select j.id into v_job_id
    from public.notification_jobs j
   where j.status in ('queued', 'failed') and j.attempts < j.max_attempts
   order by j.created_at
   limit 1;

  v_hasil := public.prepare_notification_job(v_job_id);
  if v_hasil is null or (v_hasil->>'job_id')::uuid <> v_job_id then
    raise exception 'FAIL 16c: job harus bisa disiapkan (%)', v_hasil;
  end if;
  if (v_hasil->>'attempts')::integer <> 1 then
    raise exception 'FAIL 16c2: percobaan harus bertambah jadi 1, dapat %', v_hasil->>'attempts';
  end if;

  -- Job yang sama dipanggil dua kali (mis. trigger ganda) → tidak dobel
  if public.prepare_notification_job(v_job_id) is not null then
    raise exception 'FAIL 16c3: job yang sudah dikirim tidak boleh disiapkan ulang';
  end if;

  v_hasil := public.complete_notification_job(v_job_id, true, null, 'fcm-msg-uji', null);
  if (v_hasil->>'status') <> 'sent' then
    raise exception 'FAIL 16d: job harus berstatus sent, dapat %', v_hasil->>'status';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 17. Staf membuat tagihan untuk pesanan pelanggan + verifikasi transfer manual
-- ---------------------------------------------------------------------------
do $$
declare
  v_hasil jsonb;
  v_kode text;
  v_booking jsonb;
begin
  -- Pesanan milik Siti (pelanggan lain) — staf harus bisa menagih
  v_booking := public.create_booking(
    '55555555-5555-5555-5555-555555555555',
    jsonb_build_object(
      'route_id', '33333333-3333-3333-3333-333333333333',
      'travel_date', to_char(current_date + 16, 'YYYY-MM-DD'),
      'departure_time', '06:00', 'seats', 2,
      'contact_name', 'Siti Uji', 'contact_phone', '08120000002',
      'idempotency_key', 'uji-staf-1'
    )
  );
  v_kode := v_booking->'booking'->>'kode';

  -- 17a. Pelanggan biasa tidak boleh memakai jalur staf
  begin
    perform public.admin_create_payment(
      '55555555-5555-5555-5555-555555555555', v_kode, 'manual', 'Transfer Bank', 100000, null, null, null, '{}'::jsonb
    );
    raise exception 'FAIL 17a: pelanggan seharusnya ditolak';
  exception when others then
    if sqlerrm not like '%tidak punya akses admin%' then
      raise exception 'FAIL 17a2: pesan penolakan salah (%)', sqlerrm;
    end if;
  end;

  -- 17b. Staf membuat tagihan DP untuk pesanan pelanggan
  v_hasil := public.admin_create_payment(
    '88888888-8888-8888-8888-888888888888',
    v_kode, 'manual', 'Transfer Bank', 400000, null, null, null,
    jsonb_build_object('channel', 'kasir')
  );
  if (v_hasil->'payment'->>'amount')::numeric <> 400000 then
    raise exception 'FAIL 17b: nominal tagihan staf salah (%)', v_hasil->'payment'->>'amount';
  end if;
  if (v_hasil->'payment'->>'provider_reference') is null then
    raise exception 'FAIL 17b2: referensi manual harus dibuat otomatis';
  end if;

  -- 17c. Transfer manual diverifikasi → pembayaran tercatat idempoten
  v_hasil := public.apply_payment_event(
    'manual', 'evt-staf-1', 'manual.transfer_received', 'paid',
    v_hasil->'payment'->>'provider_reference', 400000, '{}'::jsonb, true
  );
  if (v_hasil->'booking'->>'payment_status') <> 'partial' then
    raise exception 'FAIL 17c: DP harus partial, dapat %', v_hasil->'booking'->>'payment_status';
  end if;

  -- kirim ulang event yang sama → tidak dobel
  v_hasil := public.apply_payment_event(
    'manual', 'evt-staf-1', 'manual.transfer_received', 'paid',
    v_hasil->'payment'->>'provider_reference', 400000, '{}'::jsonb, true
  );
  if (v_hasil->>'duplicate')::boolean is not true then
    raise exception 'FAIL 17c2: event ulang harus duplicate';
  end if;

  -- 17d. staff_role memetakan peran
  if public.staff_role('88888888-8888-8888-8888-888888888888') <> 'operator' then
    raise exception 'FAIL 17d: peran staf harus terbaca';
  end if;
  if public.staff_role('55555555-5555-5555-5555-555555555555') is not null then
    raise exception 'FAIL 17d2: pelanggan harus null';
  end if;
end $$;
