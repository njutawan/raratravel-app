-- ============================================================================
-- 202609140007_catalog_seed.sql
-- Katalog awal: kota, rute, armada, sewa mobil, dan paket wisata.
--
-- DIHASILKAN OTOMATIS oleh tools/generate_catalog_seed.py dari data aplikasi
-- (lib/utils/constants.dart + lib/data/dummy_data.dart). Jangan diedit manual:
-- ubah data di aplikasi lalu jalankan ulang generatornya.
--
-- Semua insert idempoten (on conflict → update harga/jadwal), aman diulang.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Kota yang dilayani (urutan mengikuti daftar di aplikasi)
-- ---------------------------------------------------------------------------
insert into public.cities (name, slug, sort_order, is_active) values
  ('Jember', 'jember', 10, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Surabaya', 'surabaya', 20, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Bandara Juanda', 'bandara-juanda', 30, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Malang', 'malang', 40, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Batu', 'batu', 50, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Banyuwangi', 'banyuwangi', 60, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Silo', 'silo', 70, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Jakarta', 'jakarta', 80, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Denpasar (Bali)', 'denpasar-bali', 90, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Sidoarjo', 'sidoarjo', 100, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Gresik', 'gresik', 110, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Mojokerto', 'mojokerto', 120, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Pasuruan', 'pasuruan', 130, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Probolinggo', 'probolinggo', 140, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Lumajang', 'lumajang', 150, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Bondowoso', 'bondowoso', 160, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

insert into public.cities (name, slug, sort_order, is_active) values
  ('Situbondo', 'situbondo', 170, true)
on conflict (lower(name)) do update
  set slug = excluded.slug,
      sort_order = excluded.sort_order,
      is_active = true;

-- ---------------------------------------------------------------------------
-- Armada
-- ---------------------------------------------------------------------------
insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Calya / Sigra', 'LCGC 7-Seat', 6, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Avanza / Xenia', 'MPV', 6, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Ertiga / Xpander', 'MPV Premium', 6, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Innova Reborn', 'SUV Premium', 6, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Hiace Executive', 'Van', 12, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values
  ('Elf Long', 'Minibus', 16, true)
on conflict (lower(name)) do update
  set vehicle_type = excluded.vehicle_type,
      seat_capacity = excluded.seat_capacity,
      is_active = true;

-- ---------------------------------------------------------------------------
-- Rute travel reguler (harga = harga dasar per kursi)
-- ---------------------------------------------------------------------------
insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Surabaya')),
  (select id from public.cities where lower(name) = lower('Jakarta')),
  'surabaya-jakarta', 450000, 14,
  600, 'via Tol Trans Jawa', '{"06.00","19.00"}', '{"Innova Reborn","Hiace Executive","Elf Long"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel eksekutif Surabaya–Jakarta PP dengan sistem door-to-door. Dijemput di alamat Surabaya/Sidoarjo/Gresik dan diantar sampai tujuan di Jabodetabek. Bagasi lega, cocok untuk pindahan barang & oleh-oleh.', true, 10, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jakarta')),
  (select id from public.cities where lower(name) = lower('Surabaya')),
  'jakarta-surabaya', 450000, 14,
  600, 'via Tol Trans Jawa', '{"06.00","19.00"}', '{"Innova Reborn","Hiace Executive","Elf Long"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel eksekutif Jakarta–Surabaya PP. Penjemputan dari seluruh Jabodetabek langsung ke alamat tujuan di Surabaya dan sekitarnya.', true, 20, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Malang')),
  (select id from public.cities where lower(name) = lower('Jakarta')),
  'malang-jakarta', 450000, 14,
  660, 'via Tol Trans Jawa', '{"06.00","19.00"}', '{"Innova Reborn","Hiace Executive","Elf Long"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Solusi pulang Malang–Jakarta tanpa ribet bagasi pesawat/kereta. Oleh-oleh khas Malang (strudel, keripik apel) aman dibawa, diantar sampai depan rumah.', true, 30, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jakarta')),
  (select id from public.cities where lower(name) = lower('Malang')),
  'jakarta-malang', 450000, 14,
  660, 'via Tol Trans Jawa', '{"06.00","19.00"}', '{"Innova Reborn","Hiace Executive","Elf Long"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Berangkat dari Jakarta/Batu, tiba di Malang/Batu dengan nyaman. Armada eksekutif full AC dengan kursi reclining.', false, 40, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Malang')),
  (select id from public.cities where lower(name) = lower('Jember')),
  'malang-jember', 175000, 14,
  240, 'via Tol + Lumajang', '{"06.00","09.00","15.00","21.00"}', '{"Avanza","Xenia","Ertiga","Xpander","Calya"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel Malang–Jember PP termurah dengan jemput langsung di rumah/kos. Jadwal 4x sehari, cocok untuk mahasiswa & pekerja.', true, 50, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jember')),
  (select id from public.cities where lower(name) = lower('Malang')),
  'jember-malang', 175000, 14,
  240, 'via Lumajang + Tol', '{"06.00","09.00","15.00","21.00"}', '{"Avanza","Xenia","Ertiga","Xpander","Calya"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Rute favorit Jember–Malang/Batu. Dijemput dari Jember kota, Ambulu, Balung, Rambipuji, hingga Tanggul.', true, 60, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jember')),
  (select id from public.cities where lower(name) = lower('Surabaya')),
  'jember-surabaya', 200000, 14,
  240, 'via Tol Probolinggo', '{"06.00","09.00","15.00","21.00"}', '{"Avanza","Xenia","Innova Reborn","Hiace Executive"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel Jember–Surabaya door-to-door. Mengantar ke seluruh area Surabaya: pusat kota, Surabaya Timur/Barat/Selatan/Utara, hingga Sidoarjo & Gresik.', true, 70, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Surabaya')),
  (select id from public.cities where lower(name) = lower('Jember')),
  'surabaya-jember', 200000, 14,
  240, 'via Tol Probolinggo', '{"06.00","09.00","15.00","21.00"}', '{"Avanza","Xenia","Innova Reborn","Hiace Executive"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Rute Surabaya–Jember PP harian. Penjemputan dari Bandara Juanda, stasiun, terminal, kos, hingga rumah.', false, 80, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jember')),
  (select id from public.cities where lower(name) = lower('Banyuwangi')),
  'jember-banyuwangi', 150000, 14,
  180, 'via Kalibaru / Gumitir', '{"06.00","12.00","18.00"}', '{"Avanza","Xenia","Calya","Sigra"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel Jember–Banyuwangi PP, cocok untuk lanjutan ke Kawah Ijen & penyeberangan ke Bali. Dijemput & diantar sesuai alamat.', false, 90, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jember')),
  (select id from public.cities where lower(name) = lower('Denpasar (Bali)')),
  'jember-denpasar-bali', 300000, 14,
  420, 'via Ketapang – Gilimanuk', '{"07.00","19.00"}', '{"Innova Reborn","Hiace Executive","Elf Long"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel Jember–Denpasar Bali PP dengan armada eksekutif. Termasuk tiket penyeberangan Ketapang–Gilimanuk, antar sampai Denpasar, Kuta, & Badung.', true, 100, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Jember')),
  (select id from public.cities where lower(name) = lower('Bandara Juanda')),
  'jember-bandara-juanda', 250000, 14,
  240, 'via Tol Probolinggo', '{"00.00","06.00","12.00","18.00"}', '{"Avanza","Innova Reborn","Hiace Executive"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Antar-jemput Bandara Juanda T1 & T2. Disesuaikan dengan jadwal penerbangan — tersedia penjemputan dini hari.', true, 110, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

insert into public.routes (
  origin_city_id, destination_city_id, slug, base_price, default_capacity,
  duration_minutes, via, departure_times, vehicle_names, facilities,
  description, is_popular, sort_order, is_active
) values (
  (select id from public.cities where lower(name) = lower('Silo')),
  (select id from public.cities where lower(name) = lower('Surabaya')),
  'silo-surabaya', 130000, 14,
  240, 'via Jember + Tol', '{"06.00","15.00"}', '{"Avanza","Xenia","Calya"}',
  '{"Door-to-Door (jemput & antar alamat)","AC + Reclining Seat","Free 1x Bagasi","Asuransi perjalanan","Driver profesional"}',
  'Travel Silo (Jember)–Surabaya. Jemput dari Silo, Mayang, Mumbulsari, dan sekitarnya.', false, 120, true
)
on conflict (origin_city_id, destination_city_id) where is_active do update
  set base_price = excluded.base_price,
      default_capacity = excluded.default_capacity,
      duration_minutes = excluded.duration_minutes,
      via = excluded.via,
      departure_times = excluded.departure_times,
      vehicle_names = excluded.vehicle_names,
      facilities = excluded.facilities,
      description = excluded.description,
      is_popular = excluded.is_popular,
      sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------------
-- Sewa mobil (rental_packages + harga harian)
-- ---------------------------------------------------------------------------
with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Calya / Sigra') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Calya / Sigra + Sopir (12 jam)', 'LCGC 7-Seat', 1,
         'Irit & lincah untuk city trip dan travel reguler. Fasilitas: AC, Audio, Bagasi 2 koper.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (350000::numeric, 0),
  (250000::numeric, 1)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Avanza / Xenia') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Avanza / Xenia + Sopir (12 jam)', 'MPV', 1,
         'MPV sejuta umat, nyaman untuk keluarga & travel harian. Fasilitas: AC Double Blower, Audio, Bagasi 3 koper.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (450000::numeric, 0),
  (300000::numeric, 1)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Ertiga / Xpander') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Ertiga / Xpander + Sopir (12 jam)', 'MPV Premium', 1,
         'Kabin lebih lega & suspensi empuk untuk perjalanan jauh. Fasilitas: AC Double Blower, Kabin lega, Bagasi 3 koper.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (500000::numeric, 0),
  (350000::numeric, 1)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Innova Reborn') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Innova Reborn + Sopir (12 jam)', 'SUV Premium', 1,
         'Favorit eksekutif untuk rute jauh: Jakarta, Bali, Surabaya. Fasilitas: Captain seat, AC Digital, Bagasi 4 koper, Suspensi empuk.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (750000::numeric, 0),
  (550000::numeric, 1)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Hiace Executive') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Hiace Executive + Sopir (12 jam)', 'Van', 1,
         'Rombongan 8–12 orang? Hiace jawabannya. Nyaman & lega. Fasilitas: Reclining seat, AC Central, Bagasi super lega, Snack.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (1400000::numeric, 0)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

with kota as (select id from public.cities where lower(name) = 'jember' limit 1),
armada as (
  select id from public.vehicles where lower(name) = lower('Elf Long') limit 1
),
paket as (
  insert into public.rental_packages (
    city_id, vehicle_id, name, package_type, duration_days, description, is_active
  )
  select kota.id, armada.id,
         'Elf Long + Sopir (12 jam)', 'Minibus', 1,
         'Minibus long untuk rombongan wisata, study tour, & acara kantor. Fasilitas: 16 seat, AC Central, Bagasi belakang, Cocok rombongan.', true
    from kota, armada
  on conflict (city_id, lower(name)) where is_active do update
    set vehicle_id = excluded.vehicle_id,
        package_type = excluded.package_type,
        description = excluded.description
  returning id
)
insert into public.rental_package_prices (rental_package_id, price, valid_from)
select paket.id, harga, current_date from paket, (values
  (1700000::numeric, 0)
) as daftar(harga, urutan)
where not exists (
  select 1 from public.rental_package_prices p
  where p.rental_package_id = paket.id
);

-- ---------------------------------------------------------------------------
-- Paket wisata
-- ---------------------------------------------------------------------------
with paket as (
  insert into public.tour_packages (
    name, destination, description, duration_days, is_active
  ) values (
    'Bromo Sunrise Open Trip', 'Gunung Bromo, Jawa Timur', 'Berangkat malam dari Malang/Surabaya/Jember, kejar sunrise di Penanjakan, lanjut kawah & savana. Pulang pagi/siang. Termasuk: Transport PP + BBM, Jeep Bromo 4 lokasi, Tiket wisata, Dokumentasi, Driver + guide. Highlight: Sunrise Penanjakan, Kawah Bromo, Pasir Berbisik, Bukit Teletubbies.', 1, true
  )
  on conflict (lower(name)) where is_active do update
    set destination = excluded.destination,
        description = excluded.description,
        duration_days = excluded.duration_days
  returning id
)
insert into public.tour_package_prices (tour_package_id, price, valid_from)
select paket.id, 350000, current_date from paket
where not exists (
  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id
);
-- tipe: Open Trip

with paket as (
  insert into public.tour_packages (
    name, destination, description, duration_days, is_active
  ) values (
    'Kawah Ijen Blue Fire', 'Banyuwangi, Jawa Timur', 'Saksikan blue fire yang hanya ada 2 di dunia. Trekking ringan ±3 km didampingi guide bersertifikat. Termasuk: Transport PP + BBM, Tiket + masker gas, Guide lokal, Dokumentasi, Snack & P3K. Highlight: Blue fire langka, Kawah belerang terbesar, Sunrise Ijen.', 1, true
  )
  on conflict (lower(name)) where is_active do update
    set destination = excluded.destination,
        description = excluded.description,
        duration_days = excluded.duration_days
  returning id
)
insert into public.tour_package_prices (tour_package_id, price, valid_from)
select paket.id, 375000, current_date from paket
where not exists (
  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id
);
-- tipe: Open Trip

with paket as (
  insert into public.tour_packages (
    name, destination, description, duration_days, is_active
  ) values (
    'Bali Highlights 3D2N', 'Denpasar, Kuta, Ubud', 'Paket private trip Bali bebas atur itinerary. Cocok untuk keluarga, honeymoon, & gathering kantor. Termasuk: Transport + driver 3 hari, Hotel 2 malam, Tiket wisata, Sarapan, Dokumentasi. Highlight: Uluwatu & Kecak, Nusa Dua & Tanjung Benoa, Ubud & Tegalalang.', 3, true
  )
  on conflict (lower(name)) where is_active do update
    set destination = excluded.destination,
        description = excluded.description,
        duration_days = excluded.duration_days
  returning id
)
insert into public.tour_package_prices (tour_package_id, price, valid_from)
select paket.id, 2750000, current_date from paket
where not exists (
  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id
);
-- tipe: Private Trip

with paket as (
  insert into public.tour_packages (
    name, destination, description, duration_days, is_active
  ) values (
    'Nusa Penida One Day', 'Nusa Penida, Bali', 'Sehari penuh menjelajah spot ikonik Nusa Penida barat. Berangkat dari meeting point Sanur/Denpasar. Termasuk: Fast boat PP Sanur, Mobil + driver, Tiket wisata, Makan siang, Dokumentasi. Highlight: Kelingking Beach, Angel Billabong, Broken Beach, Crystal Bay.', 1, true
  )
  on conflict (lower(name)) where is_active do update
    set destination = excluded.destination,
        description = excluded.description,
        duration_days = excluded.duration_days
  returning id
)
insert into public.tour_package_prices (tour_package_id, price, valid_from)
select paket.id, 850000, current_date from paket
where not exists (
  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id
);
-- tipe: Open Trip

with paket as (
  insert into public.tour_packages (
    name, destination, description, duration_days, is_active
  ) values (
    'Papuma + Tanjung Papuma', 'Jember, Jawa Timur', 'Wisata signature Jember: pasir putih Papuma + snorkeling di Tanjung Papuma + sunset ikonik. Termasuk: Transport PP Jember kota, Tiket wisata, Perahu ke Tanjung Papuma, Dokumentasi, Guide. Highlight: Sunset Pantai Papuma, Tanjung Papuma, Hutan mangrove.', 1, true
  )
  on conflict (lower(name)) where is_active do update
    set destination = excluded.destination,
        description = excluded.description,
        duration_days = excluded.duration_days
  returning id
)
insert into public.tour_package_prices (tour_package_id, price, valid_from)
select paket.id, 250000, current_date from paket
where not exists (
  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id
);
-- tipe: Open Trip
