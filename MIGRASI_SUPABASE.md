# Migrasi Firestore → Supabase (Rara Travel & Tour)

Panduan ini menjelaskan cara memindahkan **data pesanan** dari Firestore ke
PostgreSQL (Supabase) tanpa mengganggu aplikasi yang sudah dipakai pelanggan.

**Prinsip yang dipegang:**

1. **Firebase Auth & FCM tetap dipakai.** Supabase hanya menggantikan Firestore
   sebagai tempat data. Login tetap OTP/Google lewat Firebase.
2. **Migrasi bertahap & bisa dibalik.** Semua tahap diatur lewat
   `--dart-define` saat build, bukan ubah kode.
3. **Penulisan booking ke Firestore tetap hidup** sampai semua tahap stabil
   (langkah 12). Selama masa itu data ditulis ke dua tempat (*dual write*).
4. **Server yang menilai harga & kursi.** Aplikasi hanya menampilkan; total
   resmi dihitung PostgreSQL saat pesanan dibuat.

---

## 1. Status 12 langkah

| # | Langkah | Berkas | Status |
|---|---|---|---|
| 1 | Firebase Auth + FCM tetap | `lib/services/auth_service.dart` | ✅ tetap |
| 2 | Config Supabase + migrasi PostgreSQL | `supabase/migrations/`, `supabase/config.toml` | ✅ siap |
| 3 | Tabel `users`, `cities`, `routes`, `rental_packages`, `tour_packages` | `…_0001_users_devices.sql`, `…_0002_catalog_schema.sql` | ✅ |
| 4 | `auth-user-sync` (Firebase UID → user Supabase) | `supabase/functions/auth-user-sync` | ✅ |
| 5 | `search-routes` + pagination | `supabase/functions/search-routes`, `…_0006_catalog_api.sql` | ✅ |
| 6 | Booking pindah ke PostgreSQL | `supabase/functions/create-booking`, `lib/repositories/booking_repository.dart` | ✅ |
| 7 | `create-booking` dengan transaksi + validasi harga/kursi | `…_0003_bookings.sql` | ✅ |
| 8 | Simpan token FCM ke `user_devices` | `register-device`, `MessagingService.sinkronSupabase()` | ✅ |
| 9 | Trigger status → notifikasi | `…_0005_notifications.sql`, `notify-booking-status` | ✅ |
| 10 | Pembayaran + webhook | `…_0004_payments.sql`, `payment-intent`, `payment-webhook` | ✅ |
| 11 | Storage + impor admin | `…_0008_storage.sql`, `…_0009_admin.sql`, `storage-sign`, `admin-import` | ✅ |
| 12 | Matikan penulisan booking ke Firestore | `--dart-define=BOOKING_WRITE=supabase` | ⛔ **belum** (lihat §8) |

Uji lokal yang sudah dijalankan: `tools/db_smoke_test.sql` (17 kelompok uji)
hijau di PostgreSQL 16 untuk seluruh migrasi `0000`–`0009`.

---

## 2. Menyiapkan proyek Supabase (langkah demi langkah)

Sekitar 15 menit. Urutannya:

```
buat proyek → pasang CLI → isi .env.supabase → migrasi database
→ secrets → deploy fungsi → setelan notifikasi → verifikasi
```

### 2.1 Buat proyek Supabase

1. Buka <https://supabase.com/dashboard> → **New project**.
2. Nama: `raratravel`. Region: **Southeast Asia (Singapore)** — terdekat dari
   Indonesia, jadi paling responsif.
3. **Database Password** → klik *Generate*, lalu **SIMPAN**. Password ini
   dibutuhkan `supabase link` dan tidak bisa dilihat lagi (kalau hilang:
   Dashboard → Settings → Database → *Reset database password*).
4. Tunggu ±2 menit sampai penyiapan selesai.
5. Catat **project ref** dari URL:
   `https://supabase.com/dashboard/project/<project-ref>`.

### 2.2 Pasang Supabase CLI di komputer

```bash
npm install -g supabase     # butuh Node 18+ (disarankan 20/22)
supabase login              # membuka peramban, sekali saja
supabase --version
```

Tidak punya Node/npm? Setiap perintah `supabase …` bisa diganti
`npx supabase@latest …` (tanpa instalasi). Bila komputer benar-benar tidak
bisa memasang CLI, ikuti §2.5 (lewat Dashboard).

Di lingkungan CI/otomatis, gunakan token: buat di Dashboard → Account →
Access Tokens, lalu `export SUPABASE_ACCESS_TOKEN=sbp_…`.

### 2.3 Isi berkas setelan lokal

```bash
cp .env.supabase.example .env.supabase
# isi minimal: SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD, FIREBASE_PROJECT_ID
```

`.env.supabase` sudah masuk `.gitignore` — **jangan** di-commit.

| Isian | Dari mana |
|---|---|
| `SUPABASE_PROJECT_REF` | URL Dashboard (lihat §2.1) |
| `SUPABASE_DB_PASSWORD` | password saat membuat proyek |
| `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Dashboard → Settings → API (boleh dikosongkan: skrip mencoba mengambil sendiri) |
| `FIREBASE_PROJECT_ID` | Firebase Console → Project settings → General |
| `FIREBASE_SERVICE_ACCOUNT_FILE` | Firebase Console → Project settings → **Service accounts** → *Generate new private key* → simpan **di luar** repositori |

### 2.4 Jalankan skrip penyiapan

```bash
bash tools/setup_supabase.sh              # semua langkah (aman diulang)
bash tools/setup_supabase.sh --check      # periksa saja, tidak mengubah apa pun
bash tools/setup_supabase.sh --step 4 8   # hanya langkah tertentu
```

| Langkah | Isi | Setara perintah manual |
|---|---|---|
| 1 | periksa CLI + isi `.env.supabase` | — |
| 2 | login ke Supabase | `supabase login` |
| 3 | sambungkan proyek | `supabase link --project-ref <ref>` |
| 4 | terapkan 11 migrasi | `supabase db push --linked` |
| 5 | kirim secrets | `supabase secrets set …` (§3) |
| 6 | deploy 10 Edge Function | `supabase functions deploy <nama>` (§4) |
| 7 | `pg_net` + `app.settings.notify_*` | tempel SQL di SQL Editor (§4) |
| 8 | verifikasi (REST, Storage, daftar fungsi) | — |

Ingin manual sepenuhnya? Urutannya sama:

```bash
supabase link --project-ref <ref>
supabase migration list              # melihat migrasi lokal ↔ remote
supabase db push --dry-run           # melihat apa yang akan dijalankan
supabase db push                     # menerapkan 202609120001 … 202609140009
```

### 2.5 Bila memakai Dashboard saja (tanpa CLI)

1. **SQL Editor** → tempel isi `supabase/migrations/*.sql` **berurutan sesuai
   nama berkas** (`202609120001_initial_catalog.sql` → `…_0009_admin.sql`),
   satu berkas sekali jalan. Semua berkas idempoten (aman diulang).
2. **Edge Functions** → buat 10 fungsi dengan nama sama seperti folder di
   `supabase/functions/`, tempel isi `index.ts` (folder `_shared` ikut
   diunggah). **Matikan “Verify JWT”** untuk semuanya.
3. **Edge Functions → Manage secrets** → isi seperti §3.
4. **Storage → New bucket** — hanya bila migrasi `0008` melaporkan
   `PERINGATAN`: `public-assets` (public, 5 MB), `avatars` (public, 2 MB),
   `payment-proofs` (privat, 5 MB); batasi tipe ke `image/jpeg, image/png,
   image/webp` (+`application/pdf` untuk bukti transfer).
5. **Storage → Policies** → buat `public_assets_read`: SELECT untuk role
   `anon` + `authenticated`, ekspresi
   `bucket_id in ('public-assets', 'avatars')`.
6. **Database → Extensions** → aktifkan `pg_net`; `pg_cron` opsional.

### 2.6 Titik periksa tiap tahap

| Setelah langkah | Tanda berhasil |
|---|---|
| 4 (migrasi) | `supabase migration list` tidak menyisakan kolom remote kosong; tabel `bookings`, `payments`, `user_devices`, `media_assets` ada di Table Editor; `cities` berisi 17 baris |
| 5 (secrets) | `supabase secrets list` memuat `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `FIREBASE_PROJECT_ID`, `NOTIFY_WEBHOOK_SECRET`, `FIREBASE_SERVICE_ACCOUNT` |
| 6 (deploy) | `supabase functions list` menampilkan 10 fungsi berstatus `ACTIVE` |
| 7 (setelan) | `select current_setting('app.settings.notify_endpoint', true);` tidak kosong |
| 8 (verifikasi) | `catalog_cities` & `search_routes` menjawab 200; bucket `public-assets` & `payment-proofs` ada |

### 2.7 Kendala yang sering muncul

| Gejala | Sebab & jalan keluar |
|---|---|
| `supabase link` → *password authentication failed* | password database salah/terlalu lama → reset di Dashboard → Settings → Database |
| `db push` → `ERROR: must be owner of table objects` | kebijakan pada `storage.objects`. Migrasi `0008` sudah menangkap galat ini dan hanya memberi `PERINGATAN`; sisa langkah tetap jalan. Buat bucket & kebijakan lewat Dashboard (§2.5 butir 4–5) |
| `db push` → *found local migrations not present on remote* | riwayat berbeda. Lihat `supabase migration list`; bila migrasi itu **sudah** ada di remote, tandai dengan `supabase migration repair --status applied <versi>` |
| Fungsi membalas `Konfigurasi SUPABASE_SERVICE_ROLE_KEY belum diisi` | secret belum di-set (langkah 5) — secrets berlaku langsung tanpa deploy ulang |
| Fungsi membalas `unauthorized` untuk token aplikasi yang sah | `FIREBASE_PROJECT_ID` berbeda dengan proyek Firebase aplikasi |
| Katalog balas `[]` atau kuota kosong | migrasi seed `0007` belum jalan, atau `CATALOG_SOURCE` masih `local` di aplikasi |
| Unggah berkas → `Bucket not found` | bucket belum dibuat (langkah `0008` dilewati) → Dashboard → Storage (§2.5 butir 4) |
| Notifikasi FCM tidak sampai | `pg_net`/`app.settings` belum diisi (langkah 7). Sementara: panggil `notify-booking-status` dengan body `{"drain": true}` dari Scheduled Function tiap 5 menit |
| Aplikasi masih menampilkan data lama | build tanpa `--dart-define` (lihat §5) |

**Ekstensi** yang dipakai:

| Ekstensi | Wajib? | Kegunaan |
|---|---|---|
| `pgcrypto` | ya | `gen_random_uuid()` (di PG 13+ sudah bawaan) |
| `pg_net` | dianjurkan | trigger mengirim HTTP ke Edge Function |
| `pg_cron` | opsional | drain notifikasi tiap 5 menit (cadangan) |

Tanpa `pg_net`, notifikasi tetap masuk: job disimpan berstatus `queued` dan
dikirim saat Edge Function `notify-booking-status` dipanggil (mis. dari
Scheduled Function Supabase tiap 5 menit dengan body `{"drain": true}`).

---

## 3. Secrets Edge Function (sekali saja)

Dashboard → Edge Functions → **Manage secrets**, atau:

```bash
supabase secrets set \
  SUPABASE_URL="https://<ref>.supabase.co" \
  SUPABASE_SERVICE_ROLE_KEY="<service-role-key>" \
  FIREBASE_PROJECT_ID="raratravel-xxxx" \
  FIREBASE_SERVICE_ACCOUNT="$(cat service-account.json)" \
  NOTIFY_WEBHOOK_SECRET="$(openssl rand -hex 24)" \
  ALLOWED_ORIGINS="https://raratravel.id,https://admin.raratravel.id"
```

| Secret | Wajib | Fungsi |
|---|---|---|
| `SUPABASE_URL` | ya | alamat proyek |
| `SUPABASE_SERVICE_ROLE_KEY` | ya | akses database dari Edge Function (jangan pernah masuk aplikasi) |
| `FIREBASE_PROJECT_ID` | ya | verifikasi ID token Firebase |
| `FIREBASE_SERVICE_ACCOUNT` | untuk FCM | JSON service account → kirim push |
| `NOTIFY_WEBHOOK_SECRET` | dianjurkan | kunci pemanggil webhook notifikasi |
| `MIDTRANS_SERVER_KEY`, `MIDTRANS_IS_PRODUCTION` | bila bayar online | Midtrans Snap |
| `XENDIT_CALLBACK_TOKEN` | bila Xendit | verifikasi webhook Xendit |
| `PAYMENT_HMAC_SECRET` | opsional | provider lain (HMAC) |
| `ALLOWED_ORIGINS` | opsional | CORS panel admin (`*` bawaan) |

---

## 4. Deploy Edge Function

Semua fungsi **tidak diverifikasi JWT oleh Supabase** (`verify_jwt = false`
di `supabase/config.toml`) karena otentikasi memakai token Firebase yang
diperiksa di dalam fungsi.

Cara tercepat: `bash tools/setup_supabase.sh --step 6` (memeriksa satu per satu).
Bila dikerjakan manual, untuk setiap nama fungsi di bawah jalankan:

```bash
supabase functions deploy auth-user-sync
supabase functions deploy register-device
supabase functions deploy search-routes
supabase functions deploy create-booking
supabase functions deploy manage-booking
supabase functions deploy notify-booking-status
supabase functions deploy payment-intent
supabase functions deploy payment-webhook
supabase functions deploy storage-sign
supabase functions deploy admin-import
```

Setelah deploy, isi kedua setelan PostgreSQL agar trigger bisa memanggil
fungsi notifikasi:

```sql
alter database postgres set app.settings.notify_endpoint =
  'https://<ref>.supabase.co/functions/v1/notify-booking-status';
alter database postgres set app.settings.notify_secret = '<NOTIFY_WEBHOOK_SECRET>';
-- muat ulang koneksi agar setelan terpakai:
select pg_reload_conf();
```

---

## 5. Sakelar aplikasi (dart-define)

| Parameter | Nilai | Arti |
|---|---|---|
| `SUPABASE_URL` | `https://<ref>.supabase.co` | alamat proyek |
| `SUPABASE_ANON_KEY` | `eyJ…` | kunci publik (aman di aplikasi) |
| `CATALOG_SOURCE` | `local` (bawaan) / `supabase` | asal data rute, jadwal, harga |
| `BOOKING_WRITE` | `dual` (bawaan) / `supabase` / `firestore` | kemana pesanan ditulis |
| `PAYMENTS_ENABLED` | `false` (bawaan) / `true` | menu “Bayar Sekarang” |
| `EDGE_TIMEOUT` | detik (15) | batas tunggu panggilan fungsi |

Contoh tahap uji (katalog dari server, pesanan masih dua tempat):

```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key> \
  --dart-define=CATALOG_SOURCE=supabase \
  --dart-define=BOOKING_WRITE=dual
```

Urutan yang disarankan: `CATALOG_SOURCE=supabase` dulu (resiko kecil) →
`BOOKING_WRITE=dual` → setelah tenang → `BOOKING_WRITE=supabase`.

---

## 6. Uji lokal sebelum deploy (tanpa Deno/Supabase CLI)

Tiga tingkat pemeriksaan, semuanya jalan di laptop:

```bash
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install pgserver "psycopg[binary]"   # sekali saja
/tmp/venv/bin/python tools/db_check.py   # migrasi + 17 kelompok uji database + kecocokan RPC
node tools/ts_check.js                   # impor relatif + nama ekspor Edge Function
node tools/e2e/run_e2e.mts               # Edge Function DIJALANKAN (17 skenario)
```

`tools/e2e/run_e2e.mts` menjalankan berkas `supabase/functions/*/index.ts` yang
sama dengan yang akan di-deploy di dalam Node 22 (dukungan TypeScript bawaan),
dengan:

* PostgreSQL 16 sungguhan sebagai database (tiruan PostgREST + Storage di
  `tools/e2e/pg_bridge.py`) sehingga nama RPC, tipe argumen, dan kebijakan
  izin diuji apa adanya;
* token Firebase betulan (RS256) yang ditandatangani kunci buatan sendiri,
  diverifikasi lewat JWKS tiruan — termasuk kasus token rusak, kedaluwarsa,
  dan audience proyek lain;
* tiruan FCM, OAuth2 Google, dan Snap Midtrans.

Yang diperiksa: katalog publik, sinkronisasi pengguna + perangkat, pemesanan
(harga & kursi dihitung server, idempotensi, kursi habis), riwayat & pembatalan,
tagihan Midtrans + webhook bertanda tangan, verifikasi transfer manual oleh
staf, notifikasi FCM (termasuk token basi), tautan unggah/unduh Storage,
impor admin, dan batas peran pelanggan vs staf.

Harness ini sudah menemukan dan memperbaiki beberapa kesalahan yang tidak
terlihat dari pembacaan kode, mis. variabel `gross_amount` yang tidak ada di
webhook Midtrans, status HTTP yang selalu 400 untuk galat database, dan
rujukan alias SQL yang salah pada `record_media_asset`.

## 7. Uji cepat setelah deploy

Pemeriksaan tanpa token (`catalog_cities`, `search_routes`, tolakan 401,
bucket Storage) bisa dijalankan sekali jalan:

```bash
bash tools/setup_supabase.sh --step 8
```

Pemeriksaan dengan token Firebase (perlu login di aplikasi):

```bash
REF=https://<ref>.supabase.co
ANON=<anon-key>
TOKEN=<firebase-id-token>   # dari aplikasi: AuthService → debugPrint

# katalog (publik)
curl -s "$REF/functions/v1/search-routes?action=search&origin=Surabaya&destination=Jakarta" \
  -H "apikey: $ANON" | jq '.total, .items[0].price_from'

# profil + perangkat
curl -s -X POST "$REF/functions/v1/auth-user-sync" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"sync","platform":"android","app_version":"1.0.0+1"}' | jq

# buat pesanan (harga dibandingkan server)
curl -s -X POST "$REF/functions/v1/create-booking" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"idempotency_key":"uji-1","origin":"Surabaya","destination":"Jakarta",
       "travel_date":"2026-10-01","departure_time":"06:00","seats":2,
       "contact_name":"Budi","contact_phone":"08123456789",
       "payment_method":"Transfer Bank"}' | jq '.booking.kode, .pricing'
```

Arti kode galat yang paling sering muncul:

| Kode | HTTP | Arti & tindakan |
|---|---|---|
| `unauthorized` | 401 | token Firebase tidak ada/kedaluwarsa — pengguna perlu login |
| `validation_error` | 400 | isian tidak lengkap/format salah |
| `price_mismatch` | 409 | harga berubah; balasan memuat `expected_total` |
| `seats_unavailable` | 409 | kursi tidak cukup; `available` memuat sisa |
| `promo_invalid` | 400 | kode promo salah/kedaluwarsa |
| `forbidden` | 403 | butuh peran staf (admin/finance/operator) |
| `not_found` | 404 | pesanan tidak ditemukan / bukan milik pengguna |
| `payment_failed` | 402 | permintaan pembayaran ditolak provider |
| `rate_limited` | 429 | lebih dari 8 pembuatan pesanan/jam |

---

## 8. Memindahkan data lama

1. Ekspor Firestore (mis. ekstensi Firebase → BigQuery, atau
   `gcloud firestore export`).
2. Susun berkas JSON per batch (maksimal 500 baris per panggilan):

```json
[{"kode":"RARA-AB1234","asal":"Surabaya","tujuan":"Jakarta",
  "tanggal":"2026-09-12","jam":"06:00","nama":"Siti","wa":"0812…",
  "kursi":2,"totalHarga":800000,"status":"Dikonfirmasi",
  "createdAt":"2026-09-01T08:00:00Z"}]
```

3. **Uji kering** (tidak menulis apa pun):

```bash
curl -s -X POST "$REF/functions/v1/admin-import" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"legacy-bookings","dry_run":true,"items":[…] }' | jq
```

4. Ulangi dengan `"dry_run": false`. Impor bersifat **idempoten** (kunci:
   `kode`) serta mempertahankan tanggal pembuatan asli, membuat pengguna baru
   bila perlu, dan menyimpan rute historis sebagai non-aktif agar tidak muncul
   di pencarian.

> Riwayat di HP pengguna tidak perlu diimpor: aplikasi membaca Firestore/HP
> lalu mengirim pesanan yang belum ada ke server (lihat `_sinkronPesananSupabase`).

---

## 9. Sebelum langkah 12 (matikan tulisan Firestore)

Jangan ubah `BOOKING_WRITE=supabase` sebelum semua poin ini terpenuhi:

- [ ] `supabase db push` sukses; `tools/db_smoke_test.sql` hijau di proyek nyata.
- [ ] `CATALOG_SOURCE=supabase` sudah dipakai minimal 1 minggu tanpa keluhan
      (harga & jadwal cocok dengan yang dijanjikan admin).
- [ ] `BOOKING_WRITE=dual` berjalan: jumlah pesanan harian di Firestore **dan**
      di PostgreSQL sama (`admin_stats` vs Console Firestore).
- [ ] Impor data lama selesai dan jumlahnya cocok (`total`, `inserted`, `skipped`).
- [ ] Notifikasi FCM jalan dari `user_devices` (uji: ubah status pesanan → push masuk).
- [ ] `payment-webhook` menerima notifikasi uji provider dan menandai `paid`.
- [ ] Ada admin yang tahu cara memakai `admin-import` & `manage-booking` (admin-set-status).

Setelah semua tercentang:

```bash
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=… \
  --dart-define=CATALOG_SOURCE=supabase \
  --dart-define=BOOKING_WRITE=supabase      # ← langkah 12
```

**Rollback**: kirim ulang build dengan `BOOKING_WRITE=dual` (atau `firestore`)
dan `CATALOG_SOURCE=local`. Firestore tidak pernah dihapus, jadi data lama
tetap utuh. Perbarui juga `firestore.rules` bila penulisan dari aplikasi benar
sudah tidak dipakai (baca saja → `allow write: if false`), setelah yakin
seluruh klien sudah versi baru.

---

## 10. Peta status

| PostgreSQL | Tampilan aplikasi | Keterangan |
|---|---|---|
| `pending` | Menunggu Konfirmasi | menunggu pembayaran/verifikasi admin |
| `confirmed` | Dikonfirmasi | pembayaran penuh diterima |
| `completed` | Selesai | perjalanan selesai |
| `cancelled` | Dibatalkan | kursi dikembalikan otomatis |
| `expired` | Kedaluwarsa | tidak dibayar sampai batas waktu |

| `payment_status` | Tampilan |
|---|---|
| `unpaid` | Belum Dibayar |
| `pending` | Menunggu Pembayaran |
| `partial` | Dibayar Sebagian (DP) |
| `paid` | Lunas |
| `failed` / `expired` / `refunded` | Pembayaran Gagal / Kedaluwarsa / Dana Dikembalikan |

Promo `RARAHEMAT`: potongan 10%, maksimal Rp50.000.

---

## 11. Berkas terkait

| Berkas | Isi |
|---|---|
| `supabase/migrations/*.sql` | skema, RPC, trigger, seed, storage, admin |
| `supabase/functions/README.md` | daftar Edge Function + contoh panggilan |
| `tools/setup_supabase.sh` | penyiapan proyek: migrasi, secrets, deploy, verifikasi |
| `.env.supabase.example` | contoh setelan lokal (salin jadi `.env.supabase`) |
| `tools/db_smoke_test.sql` | 17 kelompok uji database (jalankan lokal) |
| `tools/generate_catalog_seed.py` | membuat ulang seed katalog dari `dummy_data.dart` |
| `lib/config/backend_config.dart` | sakelar migrasi di sisi aplikasi |
| `lib/repositories/*.dart` | jembatan aplikasi → Edge Function |
| `PANDUAN_FIREBASE.md` | setup Firebase (Auth, FCM, Firestore) |
