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

## 2. Menyiapkan proyek Supabase

```bash
# sekali saja
supabase login
supabase link --project-ref <project-ref>
supabase db push          # menjalankan supabase/migrations/*.sql berurutan
```

Bila `supabase db push` tidak dipakai, jalankan berkas migrasi secara manual
lewat SQL Editor **dengan urutan nama berkas** (`…_0000` → `…_0009`).

Ekstensi yang dipakai (aktifkan di Dashboard → Database → Extensions):

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

## 6. Uji cepat setelah deploy

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

## 7. Memindahkan data lama

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

## 8. Sebelum langkah 12 (matikan tulisan Firestore)

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

## 9. Peta status

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

## 10. Berkas terkait

| Berkas | Isi |
|---|---|
| `supabase/migrations/*.sql` | skema, RPC, trigger, seed, storage, admin |
| `supabase/functions/README.md` | daftar Edge Function + contoh panggilan |
| `tools/db_smoke_test.sql` | 17 kelompok uji database (jalankan lokal) |
| `tools/generate_catalog_seed.py` | membuat ulang seed katalog dari `dummy_data.dart` |
| `lib/config/backend_config.dart` | sakelar migrasi di sisi aplikasi |
| `lib/repositories/*.dart` | jembatan aplikasi → Edge Function |
| `docs/PANDUAN_FIREBASE.md` | setup Firebase (Auth, FCM, Firestore) |
