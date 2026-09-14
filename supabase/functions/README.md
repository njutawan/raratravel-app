# Edge Function — Rara Travel & Tour

Sepuluh fungsi Deno yang menjadi jembatan antara aplikasi Flutter (login
Firebase) dan database PostgreSQL. Semuanya **tidak** memakai Supabase Auth:
token Firebase dikirim pada header `Authorization: Bearer <idToken>` dan
diverifikasi di dalam fungsi (kunci publik Google, cache 6 jam).

`supabase/config.toml` menetapkan `verify_jwt = false` untuk setiap fungsi —
tanpa itu Supabase akan menolak token Firebase sebelum kode kita berjalan.

| Fungsi | Akses | Guna |
|---|---|---|
| `auth-user-sync` | login | Firebase UID → baris `users`, sekaligus daftar perangkat |
| `register-device` | login | simpan/hapus token FCM di `user_devices` |
| `search-routes` | publik | katalog rute/paket dengan pagination |
| `create-booking` | login | buat pesanan (transaksi, harga & kursi divalidasi server) |
| `manage-booking` | login / staf | riwayat, detail, batal, status bayar + aksi admin |
| `notify-booking-status` | webhook / staf | kirim notifikasi FCM untuk perubahan status |
| `payment-intent` | login / staf | buat tagihan (Midtrans Snap atau transfer manual) |
| `payment-webhook` | publik (bertanda tangan) | callback provider pembayaran |
| `storage-sign` | login | tautan unggah/unduh Storage (gambar katalog, bukti transfer) |
| `admin-import` | staf | impor katalog, impor data lama, unggah gambar, statistik |

Semua fungsi membalas JSON. Galat berbentuk:

```json
{"error": {"code": "price_mismatch", "message": "…", "details": {"expected_total": 790000}}}
```

## Deploy

```bash
supabase link --project-ref <ref>
supabase secrets set SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… FIREBASE_PROJECT_ID=…
for fn in auth-user-sync register-device search-routes create-booking manage-booking \
          notify-booking-status payment-intent payment-webhook storage-sign admin-import; do
  supabase functions deploy "$fn"
done
```

Secret lengkap (termasuk FCM & pembayaran) ada di
[`MIGRASI_SUPABASE.md`](../../MIGRASI_SUPABASE.md) §3.

## Contoh panggilan

Semua contoh memakai `-H "apikey: $ANON"` (kunci publik proyek) dan, untuk
fungsi yang butuh login, `-H "Authorization: Bearer $TOKEN"`.

### Katalog (publik, bisa GET)

```bash
curl "$REF/functions/v1/search-routes?action=search&origin=Surabaya&destination=Jakarta&passengers=2&sort=price_asc" \
  -H "apikey: $ANON"

curl "$REF/functions/v1/search-routes?action=detail&slug=surabaya-jakarta" -H "apikey: $ANON"
curl "$REF/functions/v1/search-routes?action=cities" -H "apikey: $ANON"
```

Balasan `search`: `{items:[…], total, limit, offset, has_more, filters}`.
Setiap item memuat `schedules[]` (harga & sisa kursi per jam; `schedule_id`
null berarti jadwal pola/virtual).

### Log masuk & perangkat

```bash
curl -X POST "$REF/functions/v1/auth-user-sync" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"sync","full_name":"Budi","fcm_token":"…","platform":"android","app_version":"1.0.0+1"}'
# → {"ok":true,"user":{…},"is_new":false,"device":{…},"is_staff":false}

curl -X POST "$REF/functions/v1/auth-user-sync" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"unregister-device","fcm_token":"…"}'
```

### Buat pesanan

```bash
curl -X POST "$REF/functions/v1/create-booking" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"idempotency_key":"app-1234","origin":"Surabaya","destination":"Jakarta",
       "travel_date":"2026-10-01","departure_time":"06:00","seats":2,
       "contact_name":"Budi","contact_phone":"08123456789",
       "pickup_address":"Jl. Diponegoro 1","dropoff_address":"Mangga Dua",
       "notes":"bawa anak","promo_code":"RARAHEMAT","payment_method":"Transfer Bank",
       "client_total":810000}'
```

* `201` → `{ok, booking, idempotent, pricing:{…,remaining_seats}}`
* `409 price_mismatch` → `details.expected_total` (aplikasi menawarkan hitung ulang)
* `409 seats_unavailable` → `details.available`
* `429 rate_limited` → maksimal 8 pesanan/jam per pengguna

### Pesanan saya / aksi staf

```bash
curl -X POST "$REF/functions/v1/manage-booking" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"action":"list","limit":20,"offset":0}'
# action lain: detail|kode, cancel|kode, payment-status|kode
# staf: admin-list, admin-set-status {kode,status,note}, admin-stats
```

### Pembayaran

```bash
# tagihan online (tautan Snap)
curl -X POST "$REF/functions/v1/payment-intent" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"create","kode":"RARA-9X2K7Q","provider":"midtrans","amount":400000}'

# transfer manual sudah diterima (staf/finance)
curl -X POST "$REF/functions/v1/payment-intent" -H "apikey: $ANON" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"manual-confirm","kode":"RARA-9X2K7Q","amount":400000,"reference":"BCA-01/10"}'
```

URL callback yang didaftarkan di dashboard provider:

```
Midtrans : https://<ref>.supabase.co/functions/v1/payment-webhook?provider=midtrans
Xendit   : https://<ref>.supabase.co/functions/v1/payment-webhook?provider=xendit
Lainnya  : ….supabase.co/functions/v1/payment-webhook?provider=hmac   (header x-signature)
```

Webhook **selalu** membalas HTTP 200 + JSON supaya provider tidak mengirim
ulang tanpa henti; kegagalan tercatat pada tabel `payments.raw`.

### Notifikasi

```bash
# dipanggil trigger PostgreSQL (pg_net) — header wajib cocok
curl -X POST "$REF/functions/v1/notify-booking-status" \
  -H 'Content-Type: application/json' -H "x-webhook-secret: $NOTIFY_WEBHOOK_SECRET" \
  -d '{"job_id":"<uuid>"}'

# drain (Scheduled Function tiap 5 menit bila pg_cron tidak dipakai)
curl -X POST "$REF/functions/v1/notify-booking-status" \
  -H 'Content-Type: application/json' -H "x-webhook-secret: $NOTIFY_WEBHOOK_SECRET" \
  -d '{"drain":true,"limit":50}'
```

Balasan drain: `{ok, processed, sent, skipped, results:[{job_id,ok,reason,…}]}`.
Token FCM yang ditolak (`UNREGISTERED`) otomatis dinonaktifkan di `user_devices`.

### Storage

```bash
# 1) minta tautan unggah
curl -X POST "$REF/functions/v1/storage-sign" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"upload-url","kind":"payment_proof","kode":"RARA-9X2K7Q","filename":"bukti.jpg"}'

# 2) PUT berkas ke upload_url (tanpa apikey)
# 3) PUT/POST path ke payment-intent atau admin-import untuk dicatat
```

`kind`: `route|tour|rental|vehicle|avatar|payment_proof|other`.
Bukti transfer hanya bisa diunggah untuk pesanan milik pemanggil; tipe berkas
dibatasi (jpg/png/webp) dan ukuran 2 MB (avatar) / 5 MB (lainnya).

### Admin

```bash
# impor katalog (kota, armada, rute, jadwal, paket)
curl -X POST "$REF/functions/v1/admin-import" -H "apikey: $ANON" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"catalog","payload":{"cities":[{"name":"Surabaya"}]}}'

# impor riwayat Firestore — pakai dry_run dulu!
curl -X POST "$REF/functions/v1/admin-import" -H "apikey: $ANON" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"legacy-bookings","dry_run":true,"items":[…maks 500…]}'
```

## Struktur kode

```
_shared/env.ts        → semua konfigurasi dari Secrets (tidak ada kredensial di repo)
_shared/http.ts       → CORS, baca JSON, SQLSTATE → kode galat + HTTP
_shared/db.ts         → rpc(), selectOne(), signed URL, unggah Storage
_shared/firebase.ts   → verifikasi ID token Firebase (RS256, cache kunci Google)
_shared/fcm.ts        → HTTP v1 push (OAuth2 service account)
_shared/payments.ts   → tanda tangan Midtrans/Xendit/HMAC + Midtrans Snap
```

Perubahan skema mengikuti berkas `supabase/migrations/*.sql`; uji lokalnya
`tools/db_smoke_test.sql` (`SEMUA OK (11 migrasi)` = seluruh migrasi + 17
kelompok uji lulus).

## Catatan operasional

* **Idempotensi**: `create-booking` memakai `idempotency_key`; pembayaran
  memakai `(provider, provider_reference)` + `event_id`; impor memakai `kode`.
* **Peran staf** disimpan di `users.role` (`operator|finance|admin|super_admin`).
  Naikkan peran lewat SQL Editor, bukan dari aplikasi:
  `update public.users set role='admin' where phone='+628122503894';`
* **Jangan** pernah menaruh `SUPABASE_SERVICE_ROLE_KEY` di aplikasi Flutter.
* Edge Function berjalan di Deno; impor antar-berkas memakai jalur relatif
  (`../_shared/db.ts`) dan wajib menyertakan ekstensi `.ts`.
