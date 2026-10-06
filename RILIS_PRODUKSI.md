# ✅ Checklist Rilis Produksi — Rara Travel & Tour

**Cara pakai:** kerjakan dari atas ke bawah, centang satu per satu. Semua poin
di sini **tidak bisa dikerjakan dari dalam kode** — butuh Firebase/Supabase
Console, Play Console, atau HP fisik. Rincian latar belakang tiap langkah ada
di `LAPORAN_KEAMANAN.md`, `PANDUAN_FIREBASE.md`, `MIGRASI_SUPABASE.md`, dan
`AUDIT_RILIS.md`.

---

## 1. Firestore Rules — WAJIB, 5 menit 🔴

Perbaikan keamanan H-1 (pesanan tidak bisa lagi dititipkan ke akun orang lain)
**belum berlaku di server** sebelum rules dipublikasikan ulang.

> ✅ Rules-nya sudah **diuji otomatis** di Firestore Emulator — job
> *Aturan Firestore (emulator)* di workflow **Backend check** menjalankan 13
> pengujian keamanan (`tools/firestore/rules_test.mjs`): titip pesanan ke akun
> lain, alih kepemilikan, ubah kode, akses pesanan orang lain, sampai
> `rateLimits` yang hanya boleh diakses server. Pastikan job itu **hijau**
> sebelum publish. Bisa juga dijalankan di komputer sendiri:
> `bash tools/check_firestore_rules.sh` (butuh Java, sudah ada bersama Android
> Studio).

1. Buka [Firebase Console](https://console.firebase.google.com) → proyek
   `raratravel-apk` → **Firestore Database → Rules**.
2. Tempel seluruh isi `firestore.rules` dari repo ini → **Publish**.
3. Uji cepat di tab **Rules Playground**:
   | Simulasi | Hasil yang benar |
   |---|---|
   | `create /bookings/RARA-X` dengan `userId` ≠ uid pengirim | **Deny** |
   | `create /bookings/RARA-X` dengan `userId` = uid sendiri | Allow |
   | `update /bookings/RARA-X` yang mengganti `userId` | **Deny** |
   | `read /bookings/RARA-X` milik akun lain | **Deny** |
4. Uji nyata di HP: login → buat pesanan → pesanan **hanya** muncul di akun itu.

- [ ] Job *Aturan Firestore (emulator)* hijau di CI.
- [ ] Rules ter-publish & 4 simulasi di atas sesuai harapan.

---

## 2. App Check — Play Integrity (30 menit, sangat disarankan) 🟠

Tanpa ini, API key Firebase yang tertanam di APK bisa dipakai script luar untuk
spam OTP (biaya SMS) dan spam database.

- [ ] **Play Integrity** aktif di Console → **App Check** → aplikasi Android.
- [ ] Token debug HP development terdaftar **sebelum** enforcement:
      `bash tools/appcheck_debug_token.sh --watch` (salin token dari logcat).
- [ ] **Enforcement** dinyalakan untuk **Firestore** dan **Authentication**.
- [ ] Uji: login OTP + buat pesanan di HP fisik → harus tetap jalan.

> Urutan penting: token debug dulu, enforcement kemudian. Kalau terbalik,
> build debug Anda sendiri ikut terblokir.

---

## 3. Sidik jari SHA — kunci agar login Google tidak rusak 🔴

- [ ] **Sebelum upload pertama**: SHA-1 + SHA-256 **debug** terdaftar di Firebase
      (lihat `android/SHA_FINGERPRINTS.txt`, cocokkan dengan keluaran CI
      *Build APK* → step "Cetak SHA penanda tangan APK").
- [ ] **Setelah upload AAB pertama**: salin **SHA-1 + SHA-256 Play App Signing**
      (Play Console → *Test and release → Setup → App signing*) ke
      Firebase Console → Project Settings → aplikasi Android → *Add fingerprint*.
      **Kalau lupa, login Google & App Check versi Play Store akan rusak.**
- [ ] Unduh ulang `google-services.json` setelah menambah sidik jari, timpa di
      `android/app/`, lalu commit (tanpa ini Firebase masih menolak login).
- [ ] Ganti APK debug-key dengan AAB bertanda tangan rilis. Jalur CI sekali
      saja: `bash tools/set_keystore_secrets.sh --keystore <file.jks> --alias
      rara-travel`, lalu **Actions → Build APK → Run workflow → centang `aab`**
      dan unduh artifact `RaraTravel-v…-release-aab` (`app-release.aab` +
      `symbols-rara-*.zip`); alternatif lokal `flutter build appbundle
      --release --obfuscate --split-debug-info` (`PANDUAN_BUILD_APK.md` §3c/§7).
- [ ] Simpan `symbols-*.zip` per versi (untuk membaca crash rilis ter-obfuscate).
- [ ] Naikkan `versionCode` di `pubspec.yaml` setiap upload.

---

## 4. Supabase — fungsi & notifikasi (sekali saja)

- [ ] 11 migrasi + 10 Edge Function ter-deploy
      (`bash tools/setup_supabase.sh`, atau jalur Dashboard di
      `MIGRASI_SUPABASE.md` §2.5).
- [ ] Secrets Edge Function terisi (`MIGRASI_SUPABASE.md` §3): Firebase service
      account, FCM, Midtrans (bila pembayaran online dipakai).
- [ ] Uji kirim notifikasi: ubah status pesanan lewat `manage-booking`
      (`admin-set-status`) → **push FCM masuk ke HP**.
- [ ] `payment-webhook` menerima notifikasi uji Midtrans dan menandai `paid`.
- [ ] Budget alert Supabase/Firebase aktif (kuota & tagihan tak kejutan).

---

## 5. Pembayaran online (bila diaktifkan)

Aplikasi **hanya** menampilkan tombol pembayaran bila build memakai
`PAYMENTS_ENABLED=true` **dan** Supabase terkonfigurasi (URL + anon key).
Kunci yang diisi boleh kunci model baru **`sb_publishable_…`** (sama amannya
dengan `anon` lama) — asal **bukan** `service_role`/`sb_secret_…`.

> Cara memastikan tanpa buka kode: buka **Profil → Ringkasan Backend** di HP
> yang memakai APK itu. Baris *Supabase* harus **tersambung** dan *Pembayaran
> online* harus **AKTIF** (tombol *Salin ringkasan* untuk dilaporkan ke tim).

- [ ] Isi **Settings → Secrets and variables → Actions → Variables**:
      `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `CATALOG_SOURCE=supabase`,
      `BOOKING_WRITE=dual`, `PAYMENTS_ENABLED=true`.
      Cara satu perintah (Windows):
      `.	ools\set_actions_variables.ps1 -Build`; (Linux/macOS/Git Bash):
      `bash tools/set_actions_variables.sh --build`.
      Perintah itu menolak kunci rahasia (`service_role`) supaya tidak ikut ke APK.
- [ ] Jalankan ulang *Build APK* lalu buka **ringkasan workflow** → tabel
      **“Mode backend APK ini”** harus menulis `Pembayaran online: AKTIF`.
      Kalau masih *nonaktif*, tombol Bayar Sekarang tidak akan muncul di APK.
- [ ] Midtrans: server key + client key di secrets Edge Function, mode
      **sandbox** dulu, lalu produksi.
- [ ] Uji end-to-end di HP: buat pesanan → **Bayar Sekarang** → tautan Midtrans
      terbuka → bayar (sandbox) → status pesanan jadi **Lunas**.
- [ ] Cek **Profil → Ringkasan Backend**: Supabase *tersambung*, Pembayaran
      *AKTIF*, Notifikasi (FCM) *terdaftar*.
- [ ] Uji jalur transfer manual: **Unggah Bukti Transfer** (galeri/kamera) →
      kirim ke admin via WA → staf menandai lunas lewat `payment-intent`.
- [ ] Cek bukti transfer **tidak bisa** dibuka orang lain (bucket privat:
      `payment-proofs`).

---

## 6. Matriks uji HP fisik (wajib sebelum produksi) 📱

| Skenario | Lolos bila |
|---|---|
| HP low-end RAM 2 GB, mode profile | Tanpa jank parah / ANR |
| Android 6 (minSdk) & Android 16 (target) | Install + login + booking jalan |
| TalkBack + font maksimum + rotasi + dark mode sistem | Semua terbaca, tanpa overflow merah |
| Ganti **Mata Uang/Bahasa** di Profil | Harga & nama hari/bulan langsung berubah |
| Offline total (mode pesawat) | Pesanan lokal + WA jalan; saat online lagi, pesanan **tersinkron otomatis** (buka aplikasi sekali, login) |
| Interupsi: telepon saat OTP, putar layar saat loading | Tanpa crash / state aneh |
| Install fresh & upgrade (backup mati) | Login → riwayat cloud pulih |
| Batalkan pesanan | Status langsung "Dibatalkan", tombol Batalkan hilang |
| Unggah bukti transfer dari galeri & kamera | Terunggah, admin bisa membuka |

---

## 7. Langkah 12 migrasi: matikan tulisan Firestore

Jangan ubah `BOOKING_WRITE=supabase` sebelum **semua** poin ini tercentang
(rincian: `MIGRASI_SUPABASE.md` §9):

- [ ] Katalog dari server (`CATALOG_SOURCE=supabase`) dipakai ≥ 1 minggu tanpa keluhan.
- [ ] Jumlah pesanan harian di Firestore **dan** PostgreSQL sama
      (`admin_stats` vs Console Firestore). Ada selisih? Minta pengguna membuka
      aplikasi sekali dengan internet — outbox akan mengirim pesanan yang
      tertinggal, lalu periksa lagi.
- [ ] Impor data lama selesai (`total`, `inserted`, `skipped` cocok).
- [ ] Notifikasi FCM, pembayaran, dan alur admin (`admin-import`,
      `manage-booking`) sudah diuji.
- [ ] Baru setelah itu: `BOOKING_WRITE=supabase`.

---

## 8. Listing Play Store 🏪

- [ ] URL Kebijakan Privasi: `https://raratravel.id/privacy-policy/`
      (halaman tayang & diperbarui).
- [ ] Formulir **Data Safety** diisi sesuai `LAPORAN_KEAMANAN.md` §5.3
      (nama, no. HP, alamat, email opsional; dibagikan ke Firebase/Google &
      WhatsApp saat pengguna menekan konfirmasi; **hapus akun tersedia di
      aplikasi** → Profil → Hapus Akun).
- [ ] Screenshot HP + feature graphic + deskripsi bahasa Indonesia.
- [ ] Kuesioner rating konten & target audiens.
- [ ] Rilis bertahap: internal testing → tertutup → produksi 20% → 100%.

---

## 9. Setelah rilis

- [ ] Crashlytics + pantau Android Vitals/ANR, balas review pengguna.
- [ ] Ulangi audit (`AUDIT_RILIS.md`) setiap menambah fitur sensitif / naik
      major SDK.
- [ ] Upgrade SDK Firebase/Google terjadwal (catatan M-4) — butuh uji regresi
      OTP, Google login, booking, hapus akun.

---

## Catatan: kuota Actions

Setiap push ke branch menjalankan **Build APK** (menit Flutter) dan
**Backend check** (PostgreSQL + emulator Firestore). Agar hemat kuota:

- Job *Aturan Firestore (emulator)* hanya jalan bila `firestore.rules`,
  `firebase.json`, `tools/firestore/**`, atau workflow-nya berubah.
- Untuk build APK sekali jalan tanpa push: `gh workflow run build-apk.yml`.
- Riwayat pemakaian: **Settings → Billing → Actions usage** (atau
  `gh api /repos/{owner}/{repo}/actions/runs --paginate` lalu lihat `run_started_at`).
