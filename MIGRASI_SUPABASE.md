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

Uji lokal yang sudah dijalankan: `tools/e2e/run_e2e.mts` (18 skenario, termasuk
penerimaan kunci Supabase model baru) + `tools/db_smoke_test.sql` (17 kelompok uji)
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

### 2.5 Jalur Dashboard (tanpa CLI) — lengkap

Cocok kalau komputer tidak memasang Node/Supabase CLI (mis. Windows tanpa WSL).
Semua dikerjakan dari peramban; berkas yang perlu ditempel sudah disiapkan.

| Yang ditempel | Berkas | Jumlah |
|---|---|---|
| Skema database | `supabase/migrations/*.sql` (urut nama) | 11 |
| Edge Function | `supabase/deploy-dashboard/*.ts` (satu berkas per fungsi) | 10 |

Dua skrip Windows membuat jalur ini jauh lebih ringkas (jalankan dari akar repo
di PowerShell):

```powershell
# 1) memandu menempel 11 migrasi: salin otomatis + tunggu Enter tiap berkas
.\tools\paste_migrations.ps1

# 2) memeriksa hasilnya kapan saja (tabel, RPC katalog, Storage, 10 fungsi)
.\tools\verify_supabase.ps1 -AnonKey "<kunci publik>"
.\tools\verify_supabase.ps1 -EnvFile .env.supabase -ServiceKey "<kunci server>"
```

`verify_supabase.ps1` mencetak laporan ✔/✖ per pemeriksaan beserta saran
perbaikannya, dan keluar dengan kode 1 bila ada yang belum beres — jadi bisa
dipakai di skrip otomatis (mis. GitHub Actions self-hosted / Task Scheduler).

`supabase/deploy-dashboard/` berisi **berkas hasil bundel** — setiap fungsi
sudah memuat `_shared/*.ts` di dalamnya, sehingga bisa ditempel di editor
Dashboard yang hanya menerima satu berkas. Jangan diedit manual; bila kode
fungsi berubah, buat ulang dengan `node tools/bundle_functions.js`
(berkas ini teruji: 18/18 skenario e2e lulus memakai bundel tersebut).

> **Tips Windows (PowerShell)** — menyalin isi berkas langsung ke papan klip:
> ```powershell
> Get-Content -Raw supabase\migrations\202609120001_initial_catalog.sql | Set-Clipboard
> ```

#### 2.5.1 Database — SQL Editor

1. Dashboard → **SQL Editor** → *New query*.
2. Tempel isi berkas migrasi **satu per satu, urut nama**, tekan **Run**,
   lanjut ke berkas berikutnya. Jangan diacak: berkas `0001`–`0009` saling
   melanjutkan.

| Urut | Berkas | Isi |
|---|---|---|
| 1 | `202609120001_initial_catalog.sql` | tabel dasar (users, cities, routes, paket) |
| 2 | `202609140000_shared_helpers.sql` | fungsi bantu (kode galat, normalisasi telepon) |
| 3 | `202609140001_users_devices.sql` | `user_devices`, `auth_user_sync`, `resolve_user_id` |
| 4 | `202609140002_catalog_schema.sql` | jadwal, harga, kendaraan, kolom katalog |
| 5 | `202609140003_bookings.sql` | `bookings`, kursi, promo, `create_booking`, `cancel_booking` |
| 6 | `202609140004_payments.sql` | `payments`, `apply_payment_event` |
| 7 | `202609140005_notifications.sql` | antrean notifikasi + trigger status |
| 8 | `202609140006_catalog_api.sql` | RPC katalog (`search_routes`, `catalog_cities`, …) |
| 9 | `202609140007_catalog_seed.sql` | 17 kota, 12 rute, 6 kendaraan, 10 paket |
| 10 | `202609140008_storage.sql` | `media_assets` + bucket Storage |
| 11 | `202609140009_admin.sql` | `require_staff`, impor data lama, statistik admin |

3. Periksa: **Table Editor** → `cities` berisi 17 baris; ada tabel `bookings`,
   `payments`, `user_devices`, `media_assets`. **Database → Functions** memuat
   `create_booking`, `search_routes`, `catalog_cities`, dll.

#### 2.5.2 Storage

Berkas `0008` biasanya sudah membuat bucketnya. Bila pada langkah 10 muncul
`PERINGATAN [0008]` (peran SQL Editor tidak berhak menulis ke skema storage),
buat manual di **Storage → New bucket**:

| Bucket | Public? | Batas | Tipe diizinkan |
|---|---|---|---|
| `public-assets` | ya | 5 MB | `image/jpeg`, `image/png`, `image/webp` |
| `avatars` | ya | 2 MB | `image/jpeg`, `image/png`, `image/webp` |
| `payment-proofs` | tidak | 5 MB | jpg, png, webp, `application/pdf` |

Lalu **Storage → Policies → New policy → For full customization** pada bucket
`public-assets`: nama `public_assets_read`, operasi **SELECT**, role
`anon` + `authenticated`, ekspresi `bucket_id in ('public-assets', 'avatars')`.
(`payment-proofs` sengaja **tanpa** policy — aksesnya hanya lewat Edge Function.)

#### 2.5.3 Secrets — apa saja yang perlu diisi

Supabase **sudah menyediakan** `SUPABASE_URL` dan kunci server untuk setiap Edge
Function secara otomatis, jadi yang perlu Anda isi manual hanya yang berkaitan
dengan Firebase (dan Midtrans bila dipakai). Ringkasnya:

| Secret | Perlu diisi manual? | Kegunaan |
|---|---|---|
| `SUPABASE_URL` | **tidak** (otomatis) | alamat proyek — platform menyediakannya |
| kunci server (`SUPABASE_SERVICE_ROLE_KEY` atau `SUPABASE_SECRET_KEYS`) | **tidak** (otomatis) | akses database dari Edge Function |
| `FIREBASE_PROJECT_ID` | **ya** | memverifikasi ID token Firebase |
| `FIREBASE_SERVICE_ACCOUNT` | ya (untuk notifikasi FCM) | kirim push |
| `NOTIFY_WEBHOOK_SECRET` | ya (bebas, mis. 48 karakter acak) | kunci pemanggil webhook notifikasi |
| `MIDTRANS_SERVER_KEY`, `MIDTRANS_IS_PRODUCTION` | bila bayar online | Snap Midtrans |
| `XENDIT_CALLBACK_TOKEN`, `PAYMENT_HMAC_SECRET` | bila dipakai | verifikasi webhook provider lain |

**Edge Functions → Manage secrets** (tingkat proyek, bukan per fungsi) → isi
baris yang perlu saja. Nilai `FIREBASE_SERVICE_ACCOUNT` = **isi berkas JSON
service account dalam satu baris**; di PowerShell:

```powershell
(Get-Content -Raw "$env:USERPROFILE\kunci\firebase-sa.json" | ConvertFrom-Json | ConvertTo-Json -Compress) | Set-Clipboard
```

Perhatikan kotak komentar di dalam berkas JSON itu **tidak ada** di versi
`ConvertTo-Json` — hasilnya memang tanpa spasi/baris baru seperti yang
dibutuhkan. Bila ragu, tempel apa adanya dari editor teks lalu hapus baris
barunya.

#### 2.5.4 Deploy 10 Edge Function

Dashboard → **Edge Functions** → *Deploy a new function* → **Via Editor**.
Untuk setiap baris di bawah: isi **Name** persis seperti kolom pertama,
tempel isi berkas di kolom kedua, **matikan “Verify JWT”**, lalu **Deploy**.
(Ulangi 10 kali.)

| Nama fungsi | Berkas tempel | Kegunaan |
|---|---|---|
| `auth-user-sync` | `deploy-dashboard/auth-user-sync.ts` | Firebase UID → user + perangkat |
| `register-device` | `deploy-dashboard/register-device.ts` | simpan token FCM |
| `search-routes` | `deploy-dashboard/search-routes.ts` | katalog publik + pagination |
| `create-booking` | `deploy-dashboard/create-booking.ts` | buat pesanan (harga & kursi dari server) |
| `manage-booking` | `deploy-dashboard/manage-booking.ts` | riwayat, detail, batal, bayar |
| `notify-booking-status` | `deploy-dashboard/notify-booking-status.ts` | kirim notifikasi FCM |
| `payment-intent` | `deploy-dashboard/payment-intent.ts` | tagihan (Midtrans/manual) |
| `payment-webhook` | `deploy-dashboard/payment-webhook.ts` | callback provider pembayaran |
| `storage-sign` | `deploy-dashboard/storage-sign.ts` | tautan unggah/unduh berkas |
| `admin-import` | `deploy-dashboard/admin-import.ts` | impor data lama + statistik |

```powershell
Get-Content -Raw supabase\deploy-dashboard\search-routes.ts | Set-Clipboard
```

Setelah selesai, tiap fungsi harus berstatus **ACTIVE**. Ingat: “Verify JWT”
harus **OFF** di semuanya — login memakai Firebase, dan Supabase tidak mengenal
token itu (kalau lupa, aplikasi akan menerima galat 401 dari gerbang Supabase).

#### 2.5.5 Setelan notifikasi (SQL Editor)

```sql
create extension if not exists pg_net;

-- Simpan endpoint & rahasia webhook ke tabel app_settings
insert into public.app_settings (key, value)
values
  ('notify_endpoint', 'https://<project-ref>.supabase.co/functions/v1/notify-booking-status'),
  ('notify_secret', '<NOTIFY_WEBHOOK_SECRET>')
on conflict (key) do update set value = excluded.value, updated_at = now();
```

Mengaktifkan ekstensi juga bisa lewat **Database → Extensions** (`pg_net`;
`pg_cron` opsional untuk drain tiap 5 menit).

#### 2.5.6 Verifikasi tanpa CLI

Cara tercepat: ` .\tools\verify_supabase.ps1 -AnonKey "<kunci publik>"`.
Skrip itu menjalankan seluruh pemeriksaan di bawah ini sekaligus.

Manual (perhatikan: pakai `curl.exe`, bukan alias `curl`):

```powershell
$URL  = "https://<project-ref>.supabase.co"
$ANON = "<anon-key>"

# 1. katalog publik: harus berisi 17 kota
Invoke-RestMethod "$URL/rest/v1/rpc/catalog_cities" -Method Post `
  -Headers @{ apikey=$ANON; Authorization="Bearer $ANON"; "Content-Type"="application/json" } `
  -Body "{}" | Format-Table -AutoSize

# 2. pencarian rute (publik)
Invoke-RestMethod "$URL/rest/v1/rpc/search_routes" -Method Post `
  -Headers @{ apikey=$ANON; Authorization="Bearer $ANON"; "Content-Type"="application/json" } `
  -Body '{"p_limit":3}'

# 3. fungsi harus menolak tanpa token (401), bukan 500/404
try {
  Invoke-RestMethod "$URL/functions/v1/manage-booking" -Method Post `
    -Headers @{ apikey=$ANON; "Content-Type"="application/json" } -Body '{"action":"history"}'
} catch { $_.Exception.Response.StatusCode.value__ }   # harapan: 401
```

Di Dashboard, pastikan pula: **Edge Functions** → 10 fungsi `ACTIVE`;
**Storage** → 3 bucket ada; **Settings → API** → `service_role` **tidak** pernah
dipakai di aplikasi Flutter.

Selanjutnya uji dengan token Firebase nyata: jalankan aplikasi
(`flutter run --dart-define=…`, §5), lalu pakai contoh curl §7 dengan
`Authorization: Bearer <token Firebase>`.

### 2.6 Titik periksa tiap tahap

| Setelah langkah | Lewat CLI | Lewat Dashboard |
|---|---|---|
| 4 (migrasi) | `supabase migration list` tidak menyisakan kolom remote kosong | Table Editor: ada `bookings`, `payments`, `user_devices`, `media_assets`; `cities` 17 baris |
| 5 (secrets) | `supabase secrets list` memuat 4–6 nama yang diisi | Edge Functions → Manage secrets menampilkan daftar yang sama |
| 6 (deploy) | `supabase functions list` menampilkan 10 fungsi `ACTIVE` | Edge Functions: 10 fungsi `ACTIVE`, “Verify JWT” semuanya OFF |
| 7 (setelan) | `select current_setting('app.settings.notify_endpoint', true);` tidak kosong | SQL Editor: jalankan `select current_setting('app.settings.notify_endpoint', true);` |
| 8 (verifikasi) | `bash tools/setup_supabase.sh --step 8` | perintah PowerShell §2.5.6 |

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

### 3.1 Kunci Supabase yang dibutuhkan

Supabase mengganti penamaan kunci pada 2025–2026; **keduanya diterima** oleh
kode di repositori ini.

| Kunci | Bentuk | Aman di aplikasi? | Dipakai untuk |
|---|---|---|---|
| **publishable** (baru) | `sb_publishable_…` | **ya** | aplikasi Flutter (`SUPABASE_ANON_KEY`) |
| `anon` (lama) | JWT `eyJ…` | ya | idem, penamaan lama |
| **secret** (baru) | `sb_secret_…` | **tidak** | Edge Function (akses database, melewati RLS) |
| `service_role` (lama) | JWT `eyJ…` | tidak | idem, penamaan lama |

Dashboard → **Settings → API Keys** (proyek lama: tombol *Create new API keys*;
kunci lama tetap berlaku sampai dimatikan). Kunci publik juga bisa diambil dari
tombol **Connect** di dashboard.

Yang **tidak** dibutuhkan: JWT secret, password database (hanya untuk
`supabase link`/CLI), `SUPABASE_DB_URL`, dan kunci lain di halaman Settings →
API. Edge Function menerima `SUPABASE_URL` + kunci server **otomatis** dari
platform (`SUPABASE_SERVICE_ROLE_KEY`, atau `SUPABASE_SECRET_KEYS`/
`SUPABASE_SECRET_KEY` pada proyek berkunci baru) — lihat §2.5.3.

### 3.2 Mengisi secrets

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
| `SUPABASE_URL` | otomatis | alamat proyek (platform sudah menyediakan) |
| `SUPABASE_SERVICE_ROLE_KEY` | otomatis | akses database dari Edge Function; proyek berkunci baru memakai `SUPABASE_SECRET_KEYS` / `SUPABASE_SECRET_KEY` (keduanya dikenali kode ini) |
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
Tanpa CLI? Pakai berkas siap tempel `supabase/deploy-dashboard/<nama>.ts` — lihat §2.5.4.
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
| `SUPABASE_ANON_KEY` | `sb_publishable_…` (baru) atau `eyJ…` (anon lama) | kunci publik — aman di aplikasi |
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

Nama `--dart-define=SUPABASE_PUBLISHABLE_KEY=…` juga diterima (nilai yang sama).

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
node tools/e2e/run_e2e.mts               # Edge Function DIJALANKAN (18 skenario)
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
impor admin, batas peran pelanggan vs staf, serta penerimaan kunci Supabase
model lama (`service_role`) maupun baru (`sb_secret_…`).

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
| `tools/setup_supabase.sh` | penyiapan proyek via CLI: migrasi, secrets, deploy, verifikasi |
| `supabase/deploy-dashboard/*.ts` | 10 fungsi siap tempel untuk Dashboard (hasil bundel) |
| `tools/paste_migrations.ps1` | panduan Windows: salin 11 migrasi ke papan klip satu per satu |
| `tools/verify_supabase.ps1` | pemeriksa kesiapan proyek (REST, migrasi, Storage, 10 fungsi) |
| `tools/bundle_functions.js` | membuat ulang berkas siap tempel |
| `.env.supabase.example` | contoh setelan lokal (salin jadi `.env.supabase`) |
| `tools/db_smoke_test.sql` | 17 kelompok uji database (jalankan lokal) |
| `tools/generate_catalog_seed.py` | membuat ulang seed katalog dari `dummy_data.dart` |
| `lib/config/backend_config.dart` | sakelar migrasi di sisi aplikasi |
| `lib/repositories/*.dart` | jembatan aplikasi → Edge Function |
| `PANDUAN_FIREBASE.md` | setup Firebase (Auth, FCM, Firestore) |
