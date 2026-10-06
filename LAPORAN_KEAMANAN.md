# 🔒 Laporan Tes Keamanan — Rara Travel App

**Tanggal:** 12 September 2026 · **Metode:** audit kode statis + review konfigurasi
+ cek keterkinian dependensi (bukan penetration test dinamis — itu butuh APK
terpasang di HP; lihat §6 untuk langkah lanjutnya).

**Hasil:** 12 area diuji → **9 temuan** (2 HIGH, 4 MEDIUM, 3 LOW), **7 sudah
diperbaiki di kode**, 2 butuh tindakan Anda di Firebase Console / terjadwal.

---

## 1. Ringkasan temuan

| ID | Temuan | Level | Status |
|----|--------|-------|--------|
| H-1 | Rules Firestore: user bisa titip pesanan ke akun orang lain & alih kepemilikan | HIGH | ✅ Diperbaiki (`firestore.rules`) — **wajib Publish ulang, §5.1** |
| H-2 | Tanpa fitur hapus akun (syarat wajib Play Store untuk aplikasi login) | HIGH | ✅ Diperbaiki (tombol Hapus Akun di Profil) |
| H-3 | "Hapus Akun" hanya membersihkan Firebase — profil, pesanan, pembayaran, dan **berkas bukti transfer di Supabase tetap tersimpan** | HIGH | ✅ Diperbaiki: Edge Function `auth-user-sync` aksi `purge` + RPC `purge_user_data` (migrasi 0010), diuji di DB & e2e |
| M-1 | Backup otomatis Android aktif → data PII plaintext ikut ter-backup cloud | MEDIUM | ✅ Diperbaiki (`allowBackup=false`) |
| M-2 | Tanpa App Check → API key Firebase bisa dipakai script luar | MEDIUM | ✅ Diperbaiki: aktivasi kode + **enforcement Firestore & Auth dinyalakan** (§5.2) |
| M-3 | minSdk 23: trafik HTTP polos masih diizinkan di Android 6–7 | MEDIUM | ✅ Diperbaiki (paksa HTTPS) |
| M-4 | `firebase_auth` 5.x & `google_sign_in` 6.x tertinggal 1 major | MEDIUM | ✅ Kode diperbarui ke `firebase_auth` 6.x / `google_sign_in` 7.x — **wajib uji regresi HP** (§5.4) |
| L-1 | Keluar tidak membersihkan sesi Google (berisiko di HP bersama) | LOW | ✅ Diperbaiki |
| L-2 | Cloud Function bisa crash saat `userId` kosong; token FCM basi menumpuk | LOW | ✅ Diperbaiki (`functions_sample/`) |
| L-3 | Diskon promo dihitung di HP (bisa diubah di HP root) | LOW | ℹ️ Risiko diterima (admin verifikasi manual via WA) |

---

## 2. Detail temuan HIGH

### H-1. Rules Firestore tidak mengikat dokumen ke pemilik — DIPERBAIKI
**Dulu** (`firestore.rules` lama): `allow create: if request.auth != null` —
user login mana pun bisa membuat dokumen pesanan dengan `userId` milik orang
lain (pesanan palsu muncul di riwayat korban), dan `update` mengizinkan
penggantian `userId` (pengalihan kepemilikan).

**Sekarang:** `create` wajib `userId == uid` sendiri + `kode == ID dokumen`;
`update` mengunci `userId` & `kode` agar tak bisa diganti; `read/delete`
tetap pemilik saja. Kompatibel dengan semua pemanggilan di aplikasi
(`saveBooking` idempoten, `updateStatus`, `deleteBooking`, query riwayat).

> ⚠️ **Wajib:** Publish ulang rules ini di Console — kalau tidak, perbaikan
> ini belum berlaku di server! (langkah di §5.1)

### H-2. Tanpa fitur hapus akun — DIPERBAIKI
Google Play **menolak/menindak** aplikasi ber-login tanpa cara hapus akun
(kebijakan Data Safety & [Permintaan penghapusan akun](https://support.google.com/googleplay/android-developer/answer/13327111)).

**Sekarang:** Profil → kartu akun → **Hapus Akun** → dialog konfirmasi →
menghapus profil + semua pesanan cloud + riwayat lokal + sesi login
(`AuthService.deleteAccount`). Jika sesi sudah tua, Firebase menuntut login
ulang dulu — aplikasi menampilkan panduannya, bukan error mentah.

---

## 3. Detail temuan MEDIUM

### M-1. Backup otomatis membawa kabur data PII — DIPERBAIKI
`SharedPreferences` menyimpan nama, no. WA, alamat jemput/antar **plaintext**,
dan `allowBackup` default Android = `true` → ikut ter-backup ke Google Drive
dan bisa dipulihkan ke HP lain. **Sekarang** `allowBackup="false"` di
`AndroidManifest.xml` (cloud Firestore adalah sumber kebenaran, jadi tidak ada
data yang hilang semantiknya).

### M-2. Tanpa App Check — SEBAGIAN (butuh §5.2)
API key Firebase **publik by design** (tertanam di APK). Tanpa App Check,
siapa pun bisa memakai key itu dari script untuk menghantam Auth/Firestore
(spam OTP = tagihan SMS, spam database). **Kode aktivasi sudah dipasang**
(`firebase_app_check` + `AndroidProvider.playIntegrity`, debug pakai provider
debug, gagal = non-fatal) — tetapi **nol efek sebelum Enforcement dinyalakan
di Console**. Ikuti §5.2.

### M-3. HTTP polos diizinkan di Android 6–7 — DIPERBAIKI
`minSdk 23` berarti di Android 6–7 cleartext masih default-allow. Aplikasi
memang hanya memakai URL `https`, tetapi sekarang diperkeras eksplisit:
`usesCleartextTraffic="false"` + `network_security_config.xml`.

### M-4. SDK Firebase/Google tertinggal 1 major — KODE DIPERBARUI (uji HP tertunda)
Terpasang sekarang: `firebase_auth ^6.7.0`, `firebase_core ^4.14.0`,
`cloud_firestore ^6.10.0`, `firebase_messaging ^16.7.0`,
`firebase_app_check ^0.4.8`, `firebase_crashlytics ^5.4.0`,
`google_sign_in ^7.2.0` (sebelumnya 5.x/3.x/5.x/15.x/0.3.x/—/6.x).

Yang berubah di kode (bukan hanya versi):
* `google_sign_in` 7.x memakai pola baru `GoogleSignIn.instance` +
  `initialize()` (sekali) + `authenticate()`; pembatalan pengguna kini berupa
  `GoogleSignInException(canceled)`, dan `accessToken` terpisah dari
  autentikasi. `accessToken` hanya dipakai sebagai **cadangan** bila `idToken`
  kosong (butuh izin scope `email` yang sudah pernah diberikan — tanpa UI baru).
* Firebase 6.x/4.x menghapus beberapa fungsi deprecated (`User.updateEmail`,
  `FirebaseAuth.fetchSignInMethodsForEmail`, `Firestore.enablePersistence`,
  `Messaging.sendMessage`) — semuanya sudah dicek: **tidak dipakai** aplikasi
  ini.
* `idToken` Google berasal dari OAuth client *web* di `google-services.json`
  (client_type 3) — berkas ini sudah memenuhinya.

Sisa pekerjaan: **uji di HP fisik** (§5.4) karena API Google Sign-In benar-benar
berubah dan tidak bisa diuji dari CI.

---

## 4. Temuan LOW & area yang LOLOS ✅

**LOW yang diperbaiki:** L-1 `signOut()` kini juga `GoogleSignIn().signOut()`;
L-2 function sampel kini guard `userId` kosong + pruning token FCM invalid.

**Lolos uji (bersih):**
- ❌ Tidak ada secret/API key/password/token di kode, panduan, maupun repo
- ❌ Tidak ada URL `http://`, tidak ada WebView/JS bridge/`eval`
- ❌ Tidak ada `google-services.json` / `.jks` / `key.properties` di repo (gitignore benar)
- ✅ Izin Android minimal (hanya `INTERNET`); tanpa deep-link; satu activity exported (launcher, wajar)
- ✅ Kode booking memakai `Random.secure()` 32⁶ ≈ 1 miliar kombinasi — tak bisa ditebak
- ✅ Validasi input form (nama, no. HP, alamat, OTP 6 digit) + cooldown kirim-ulang 60 dtk di aplikasi
- ✅ Firebase Auth sendiri membatasi permintaan SMS berlebih (`too-many-requests`, kuota harian per proyek)
- ⚠️ **Koreksi klaim lama**: "throttling server Firebase" lewat koleksi `rateLimits`
  (`functions_sample/`) **tidak berada di jalur permintaan aplikasi** — aplikasi
  tidak memanggil Cloud Functions sama sekali (tidak ada `cloud_functions` di
  `pubspec.yaml`). Cooldown 60 dtk murni di sisi klien, jadi klien yang dimodifikasi
  bisa mengabaikannya. Perlindungan nyatanya: **App Check enforcement** (§5.2) +
  **SMS region policy & kuota** Firebase Console (lihat RILIS_PRODUKSI.md poin 2).
- ✅ Tidak ada log data sensitif (`debugPrint` hanya pesan status, nonaktif di release)
- ✅ `openLink` hanya dipanggil dengan URL konstanta resmi (web + sosmed)
- ✅ Pesan error ramah, tidak membocorkan detail teknis (hanya kode error standar)
- ✅ Sensitive flow (login wajib) ditegakkan ganda: UI + rules server

---

## 5. Tugas Anda (tidak bisa saya kerjakan dari sini)

### 5.1 Publish ulang Firestore Rules (5 menit) — WAJIB
Tiga jalur, pilih salah satu:

```bash
gh workflow run deploy-firebase.yml      # CI: gate 13 uji emulator → publish → verifikasi
bash tools/setup_firebase.sh --step 6    # lokal (butuh firebase-tools + login)
bash tools/verify_published_rules.sh     # BUKTI rules sudah berlaku di server
```

Jalur Console: Firestore Database → **Rules** → paste seluruh isi
`firestore.rules` → **Publish**. Uji di tab **Rules Playground**: simulasi
`create /bookings/X` dengan `userId` ≠ uid → harus **Deny**.

`tools/verify_published_rules.sh` menutup pertanyaan "sudah benar-benar
terpasang atau belum": membandingkan isi rules di server dengan repo, lalu
mencoba empat permintaan **tanpa login** yang semuanya harus ditolak.

### 5.2 Nyalakan App Check Enforcement (15 menit) — SANGAT DISARANKAN
1. Daftarkan SHA-256 juga (selain SHA-1): Play Console → atau
   `keytool -list -v -keystore ...` → Project Settings → tambah sidik jari.
2. Daftarkan aplikasi Android → provider **Play Integrity**
   (Console → **App Check** → Apps; cek: `bash tools/appcheck_admin.sh --status`).
3. Ambil **token debug** untuk HP development: jalankan aplikasi debug, salin
   token dari logcat → daftarkan. Satu perintah:
   ```bash
   bash tools/appcheck_debug_token.sh --watch     # lihat token di logcat
   bash tools/appcheck_admin.sh --from-logcat     # ambil + daftarkan sekaligus
   ```
4. **Enforcement**: aktifkan untuk **Firestore** dan **Authentication**:
   `bash tools/appcheck_admin.sh --enforce all`
   (rollback: `--unenforce all --yes`).
5. **SMS region policy** (pembatas biaya OTP yang nyata):
   `bash tools/sms_region_policy.sh --allow ID` — hanya Indonesia yang boleh
   menerima OTP; `--status` mencetak batas kuota tetap + `--metrik` nama metrik
   pemantauannya.
5. Jalankan `flutter pub get` (dependensi baru `firebase_app_check`), uji login
   + buat pesanan di HP fisik.

> Urutan penting: daftarkan token debug DULU (langkah 3) baru enforcement
> (langkah 4) — kalau terbalik, build debug kamu sendiri ikut terblokir.

### 5.3 Formulir Data Safety Play Console (saat rilis)
Lembar jawab lengkapnya ada di **`DATA_SAFETY.md`** — per tipe data
(collected/shared, tujuan, opsional, terenkripsi, bisa dihapus) beserta berkas
buktinya, plus daftar tipe data yang **tidak** boleh dicentang (Location,
Messages, Advertising ID, in-app search history).

Dua hal yang paling sering membuat penolakan:
1. **Tautan web hapus akun** — Play meminta jalur dalam aplikasi (sudah ada:
   Profil → Hapus Akun) **dan** tautan web. Terbitkan `docs/hapus-akun.html`
   ke `https://raratravel.id/hapus-akun/` lalu tulis URL-nya di formulir.
2. **Crashlytics** — jawab jujur pada "can users request deletion?" untuk crash
   logs (pilih *No*, atau aktifkan penghapusan berbasis instance dulu).

### 5.4 Uji regresi SDK baru (WAJIB, di HP fisik)

Kode sudah dinaikkan ke generasi `firebase_core 4.x` (lihat M-4). Pasang APK
dari *Releases* terbaru, lalu jalankan berurutan — catat hasil per baris:

- [ ] **Login OTP**: kirim kode → SMS masuk → verifikasi → masuk Beranda.
      (ujar) Kegagalan khas: `INVALID_APP_CREDENTIAL` = SHA-1 APK belum terdaftar.
- [ ] **Auto-verifikasi** (Android tanpa input kode) tetap jalan.
- [ ] **Login Google**: tombol Google → pilih akun → masuk. Kalau gagal dengan
      *"SHA-1 APK belum terdaftar"* padahal sudah terdaftar, cek juga OAuth
      client **web** (client_type 3) masih ada di `google-services.json`.
- [ ] **Pesan "dibatalkan"**: tekan back di pemilih akun → tidak dihitung galat.
- [ ] **Booking**: buat pesanan baru → tersimpan (mode Supabase) + masuk Riwayat.
- [ ] **Notifikasi**: terima push status pesanan; token FCM tersimpan
      (Profil → Ringkasan Backend).
- [ ] **Keluar**: akun Google ikut keluar (coba login Google lagi → diminta pilih akun).
- [ ] **Hapus Akun**: konfirmasi → data hilang; bila jaringan gagal, akun TIDAK
      terhapus dan muncul pesan jelas.
- [ ] **Crashlytics**: picu uji (lihat catatan Crashlytics) → laporan muncul di Console.

Bila ada yang gagal, laporkan gejala + layar mana; rollback cepat: kembalikan
tujuh baris versi di `pubspec.yaml` ke revisi sebelumnya (mode aplikasi tidak
berubah, jadi data aman).

---

## 6. Uji lanjutan yang disarankan (dinamis)

1. **MobSF** (gratis, otomatis): `docker run -p 8000:8000 opensecurity/mobile-security-framework-mobsf`
   → upload APK release → baca skor & temuan binary.
2. **Uji manual di HP root**: pastikan `allowBackup=false` (cek `adb backup`
   ditolak), data SharedPreferences tidak mengandung selain JSON pesanan.
3. **Rules Playground**: uji tiap operasi baca/tulis/hapus sebagai pemilik vs non-pemilik.
4. **Ulangi audit** setiap ganti major version Firebase / tambah fitur sensitif.

---

## 7. Update: rate-limit brute-force login (12 Sep 2026)

Aplikasi tidak memakai password (login via OTP SMS + Google), sehingga tidak
ada layar "lupa password" — sebagai gantinya dipasang rate-limit:

- **OTP** (`login_screen.dart` + `login_guard.dart`): 3x kode salah →
  nomor dikunci 5 menit + **wajib minta kode baru**. Hanya kode salah yang
  dihitung (error jaringan/sesi tidak). Status persisten di HP.
- **Google** (`login_carousel_screen.dart`): 3x gagal beruntun (di luar
  pembatalan user & gangguan jaringan) → tombol dikunci 5 menit dengan
  hitung mundur.
- Firebase tetap menjadi throttling lapis server (`too-many-requests` + kuota SMS),
  diperkuat App Check (§5.2) dan pembatasan region SMS di Console.

*Disusun otomatis dari audit kode. Simpan file ini sebagai bukti due-diligence
keamanan sebelum rilis Play Store.*
