# ✅ Checklist Rilis Produksi — Rara Travel & Tour

**Cara pakai:** kerjakan dari atas ke bawah, centang satu per satu. Semua poin
di sini **tidak bisa dikerjakan dari dalam kode** — butuh Firebase/Supabase
Console, Play Console, atau HP fisik. Rincian latar belakang tiap langkah ada
di `LAPORAN_KEAMANAN.md`, `PANDUAN_FIREBASE.md`, `MIGRASI_SUPABASE.md`, dan
`AUDIT_RILIS.md`.

---

## 0. Mulai di sini: gerbang rilis (2 menit, tanpa kredensial) 🟢

```bash
bash tools/release_gate.sh          # semua pemeriksaan lokal + tabel status
```

Skrip ini menjalankan seluruh pemeriksaan yang bisa dikerjakan dari dalam repo
(rahasia tidak bocor, 19 skenario e2e Edge Function, 12 migrasi + kecocokan 31
RPC, `firestore.rules` + job CI-nya, sidik jari keystore, artefak Play) lalu
mencetak **6 tugas rilis** beserta perintah berikutnya untuk masing-masing:

| # | Tugas | Perintah berikutnya |
|---|---|---|
| 1 | Deploy 12 migrasi + 10 Edge Function | `gh workflow run deploy-supabase.yml -f dry_run=true` → tanpa `dry_run` |
| 2 | Publish `firestore.rules` (H-1) | `gh workflow run deploy-firebase.yml` → `bash tools/verify_published_rules.sh` |
| 3 | App Check + token debug | `bash tools/appcheck_admin.sh --status` → `--from-logcat` → `--enforce all` |
| 4 | SMS region policy / kuota | `bash tools/sms_region_policy.sh --status` → `--allow ID` |
| 5 | Backup keystore | `bash tools/backup_keystore.sh create --keystore <rilis.jks>` |
| 6 | Data Safety Play Console | isi formulir dari `DATA_SAFETY.md` + terbitkan `docs/hapus-akun.html` |

Poin 1–5 butuh kredensial (Firebase/Supabase/Play) sehingga **tidak bisa**
dikerjakan dari dalam repo; yang disediakan di sini adalah jalur satu perintah
untuk tiap poin. Kredensial yang dibutuhkan tiap workflow ada di judul
workflow-nya (`.github/workflows/deploy-*.yml`).

Bagian terakhir skrip memeriksa **kesiapan deploy**: kedua workflow deploy ada
dan bisa dipanggil, tidak ada rahasia yang tertanam di dalamnya, serta
secrets/variables Actions sudah terpasang (bila `gh` tersedia dan tokenmu boleh
membacanya). Dengan begitu kekurangan kredensial ketahuan **sebelum** workflow
dijalankan, bukan di tengah jalan.

- [ ] `bash tools/release_gate.sh` → **SEMUA PEMERIKSAAN LOKAL LULUS**

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

**Jalur satu perintah (tanpa buka Console)** — workflow ini menjalankan gate
13 uji emulator dulu, baru publish, lalu memverifikasi ke proyek nyata:

```bash
gh workflow run deploy-firebase.yml                 # rules + indexes
gh run watch                                        # pantau
bash tools/verify_published_rules.sh                # bukti rules sudah berlaku
```

Butuh secret `FIREBASE_SERVICE_ACCOUNT_JSON` (isi berkas service account, satu
baris) atau `FIREBASE_TOKEN` (hasil `firebase login:ci`). Jalur lokal:
`bash tools/setup_firebase.sh --step 6`.

`tools/verify_published_rules.sh` memeriksa proyek NYATA (bukan emulator):
isi rules di server dibandingkan dengan `firestore.rules` di repo, lalu empat
permintaan **tanpa login** (buat pesanan atas nama orang lain, list pesanan,
baca profil, baca `rateLimits`) harus **ditolak semua**. Bila belum dipublish,
skrip ini mencetak selisihnya.

- [ ] Job *Aturan Firestore (emulator)* hijau di CI.
- [ ] Rules ter-publish & 4 simulasi di atas sesuai harapan.
- [ ] `bash tools/verify_published_rules.sh` → **LOLOS** (bukti H-1 berlaku di server).

---

## 2. App Check — Play Integrity (30 menit, sangat disarankan) 🟠

Tanpa ini, API key Firebase yang tertanam di APK bisa dipakai script luar untuk
spam OTP (biaya SMS) dan spam database.

Semua langkah di bawah bisa dikerjakan lewat API (tidak perlu klik Console),
asal ada `gcloud auth login` **atau** `GOOGLE_APPLICATION_CREDENTIALS` yang
menunjuk service account ber-peran **Firebase Admin**:

```bash
bash tools/appcheck_admin.sh --status        # provider, debug token, enforcement
bash tools/appcheck_debug_token.sh --watch   # ambil token debug dari logcat HP
bash tools/appcheck_admin.sh --from-logcat   # → langsung terdaftar di proyek
bash tools/appcheck_admin.sh --enforce all   # Firestore + Auth + Storage (ENFORCED)
bash tools/appcheck_admin.sh --unenforce all --yes   # rollback cepat bila ada masalah
```

- [ ] **Play Integrity** aktif (`--status` menampilkan *provider Play Integrity terdaftar*).
- [ ] Token debug HP development terdaftar **sebelum** enforcement
      (`--from-logcat`, atau `--register <UUID> --name hp-uji`).
- [ ] **Enforcement** dinyalakan untuk **Firestore** dan **Authentication**
      (`--enforce all` → `--status` menunjukkan `ENFORCED`).
- [ ] **SMS region policy** dibatasi ke negara yang benar-benar dilayani:
      ```bash
      bash tools/sms_region_policy.sh --status      # lihat kebijakan sekarang
      bash tools/sms_region_policy.sh --allow ID    # hanya Indonesia (17 kota dilayani)
      bash tools/sms_region_policy.sh --metrik      # nama metrik untuk memantau
      ```
      Ini pembatas **nyata** biaya SMS bila APK disalahgunakan. Kuota harian
      SMS tidak bisa diubah dari API — batas tetapnya tercetak oleh `--status`
      (3.000 SMS/hari di paket Blaze, 900/menit, 50/menit per IP). Pasang
      **budget alert** di Console → Usage & billing.
- [ ] Uji: login OTP + buat pesanan di HP fisik → harus tetap jalan.

> Urutan penting: token debug dulu, enforcement kemudian. Kalau terbalik,
> build debug Anda sendiri ikut terblokir.
>
> Catatan: cooldown kirim-ulang OTP 60 detik di aplikasi hanya lapis tampilan.
> Cloud Function `functions_sample/` (koleksi `rateLimits`) **tidak dipanggil
> aplikasi**, jadi jangan mengandalkannya sebagai pembatas server. Yang bekerja:
> App Check + kuota/policy SMS Firebase di atas.

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
- [ ] **Backup keystore** dibuat sebagai bundel terenkripsi dan disalin ke DUA
      tempat berbeda (AUDIT_RILIS.md §3.5):
      ```bash
      bash tools/backup_keystore.sh create --keystore ~/upload-keystore.jks --alias rara-travel
      bash tools/backup_keystore.sh verify  ~/rara-keystore-backup/<bundel>.tar.gz.enc
      bash tools/backup_keystore.sh checklist      # daftar periksa lengkap
      ```
      Bundel berisi keystore, `key.properties` siap pakai, sidik jari
      SHA-1/SHA-256/MD5, masa berlaku sertifikat, dan `PANDUAN_PULIHKAN.md`.
      Sandi bundel disimpan **terpisah** (password manager). Jangan taruh di
      dalam repositori.
      > Dengan **Play App Signing** (AAB), kunci upload yang hilang masih bisa
      > dipulihkan lewat *Request upload key reset* di Play Console — tapi jangan
      > mengandalkan itu: backup tetap wajib, dan tanpa Play App Signing kunci
      > yang hilang bersifat fatal.
- [ ] Naikkan `versionCode` di `pubspec.yaml` setiap upload.

---

## 4. Supabase — fungsi & notifikasi (sekali saja)

- [ ] 12 migrasi + 10 Edge Function ter-deploy **ulang** (fungsi `auth-user-sync` berubah: aksi `purge` untuk hapus akun)

      Jalur satu perintah lewat CI (tanpa memasang Supabase CLI):
      ```bash
      gh workflow run deploy-supabase.yml -f dry_run=true    # lihat dulu apa yang jalan
      gh workflow run deploy-supabase.yml                    # migrasi + 10 fungsi
      gh workflow run deploy-supabase.yml -f fungsi=auth-user-sync   # satu fungsi saja
      gh run watch
      ```
      Butuh secret `SUPABASE_ACCESS_TOKEN` + `SUPABASE_DB_PASSWORD`, dan
      variable `SUPABASE_PROJECT_REF` (+ `SUPABASE_ANON_KEY` untuk verifikasi).
      Workflow ini menjalankan `tools/setup_supabase.sh` langkah 3–4–6–7–8, jadi
      hasilnya sama dengan jalur lokal dan ditutup pemeriksaan REST/Storage.

      Alternatif lokal: `bash tools/setup_supabase.sh`; jalur Dashboard (tanpa
      CLI sama sekali): `MIGRASI_SUPABASE.md` §2.5 — **jangan lupa migrasi
      ke-12** `202609140010_purge_user.sql`, tanpa itu tombol Hapus Akun tidak
      menghapus data di server (temuan H-3).
      Periksa: `.\tools\verify_supabase.ps1 -ServiceKey "<kunci server>"` →
      baris *RPC purge_user_data* harus ✔.
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
      `.\tools\set_actions_variables.ps1 -Build`; (Linux/macOS/Git Bash):
      `bash tools/set_actions_variables.sh --build`.
      Perintah itu menolak kunci rahasia (`service_role`) supaya tidak ikut ke APK.
      Untuk memastikan URL + kunci benar-benar diterima proyek (sebelum menunggu
      build): `bash tools/set_actions_variables.sh --url … --key … --verify` —
      bila kunci ditolak, variables tidak diubah sama sekali.
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
| **Hapus Akun** (Profil → Hapus Akun) | Pesan sukses muncul; login ulang dengan akun itu membuat akun baru yang **kosong** (tanpa pesanan lama) — tanda data benar-benar terhapus |
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
- [ ] Formulir **Data Safety** diisi dari lembar jawab **`DATA_SAFETY.md`**
      (per tipe data: collected/shared, tujuan, opsional, terenkripsi, bisa
      dihapus — lengkap dengan bukti berkasnya). Ringkasan lama ada di
      `LAPORAN_KEAMANAN.md` §5.3.
- [ ] **Tautan web hapus akun** (WAJIB bila aplikasi punya pendaftaran akun):
      terbitkan `docs/hapus-akun.html` ke `https://raratravel.id/hapus-akun/`,
      uji dari browser HP tanpa login, lalu tulis URL itu di formulir Data
      Safety bagian *Data deletion*. Jalur dalam aplikasi (Profil → Hapus Akun)
      sudah ada; Google meminta **keduanya**.
- [ ] Screenshot HP + feature graphic + deskripsi bahasa Indonesia.
- [ ] Kuesioner rating konten & target audiens.
- [ ] Rilis bertahap: internal testing → tertutup → produksi 20% → 100%.

---

## 9. Setelah rilis

- [ ] Pantau **Android Vitals** (Play Console: ANR/crash rate) **dan
      Crashlytics** (Firebase Console → Crashlytics: crash & non-fatal, sudah
      dipasang — lihat catatan di bawah); balas review pengguna.
- [ ] Ulangi audit (`AUDIT_RILIS.md`) setiap menambah fitur sensitif / naik
      major SDK.
- [ ] **Uji regresi SDK baru di HP** (`LAPORAN_KEAMANAN.md` §5.4): OTP, Google
      login, booking, notifikasi, keluar, hapus akun, Crashlytics.

---

## Catatan: Crashlytics (SUDAH DIPASANG)

`firebase_crashlytics` sudah ada di `pubspec.yaml` dan aktif di kode:
koleksi diaktifkan **hanya di build rilis** (`!kDebugMode`), dan galat fatal dari
`FlutterError.onError` + `PlatformDispatcher.instance.onError` diteruskan lewat
`FirebaseBootstrap.catatGalatFatal`. Kartu **Profil → Ringkasan Backend** punya
baris "Laporan crash" (aktif/nonaktif) untuk memastikan dari HP.

Cara memverifikasi sekali (butuh ±1 menit):

1. Pasang APK rilis dari *Releases*, buka aplikasi.
2. Firebase Console → **Crashlytics** → panel dashboard.
3. Di HP, setelah beberapa menit pakai aplikasi, laporan crash/ANR pertama akan
   muncul di tab **Crashes** (tanpa enforcement tambahan di Console).
4. Untuk uji sengaja (mis. `throw` dari tombol debug), cukup tambahkan
   `FirebaseCrashlytics.instance.crash()` di build uji — **jangan di rilis**.

Catatan: nomor baris pasti terbaca karena jalur AAB di poin 3 menghasilkan
`symbols-rara-*.zip` dan plugin Gradle Crashlytics mengunggah peta simbolnya
otomatis. Kalau log Crashlytics tampak "stack trace tidak jelas" pada build APK
(mode `--obfuscate`), pakai AAB/Play atau simpan `symbols-*.zip` dari artifact.

---

## Catatan: peninggalan Firebase (dibersihkan setelah langkah 12)

Setelah tulisan Firestore dimatikan (poin 7), sisa ini bisa dihapus:

| Sisa | Kapan aman dihapus | Cara |
|---|---|---|
| `functions_sample/` + blok `functions` di `firebase.json` | Setelah langkah 12 | Hapus folder + blok JSON (sudah ditandai LEGACY di berkasnya) |
| `cloud_firestore` di `pubspec.yaml`, `FirestoreService`, `firestore.rules` | Setelah yakin rollback tak diperlukan (±1 bulan produksi) | Hapus bertahap; jangan lupa hapus job rules di `backend-check.yml` |
| `firebase_app_check` tetap dipakai (login Firebase masih inti) | — | — |

**Jangan dihapus sekarang**: selama `BOOKING_WRITE` masih `dual`, Firestore
masih ditulis sebagai cadangan rollback.

---

## Catatan: kuota Actions

Setiap build menerbitkan **GitHub Release** berisi APK (dan AAB bila diminta) —
unduh lewat `gh release download <tag>` atau halaman *Releases*; berkas APK tidak
lagi disimpan di git agar riwayat repo tidak menggelembung (±60 MB/versi).

Setiap push ke branch menjalankan **Build APK** (menit Flutter) dan
**Backend check** (PostgreSQL + emulator Firestore). Agar hemat kuota:

- Job *Aturan Firestore (emulator)* hanya jalan bila `firestore.rules`,
  `firebase.json`, `tools/firestore/**`, atau workflow-nya berubah.
- Workflow **Deploy Firebase** & **Deploy Supabase** hanya jalan saat
  *workflow_dispatch* (tidak ikut terpicu tiap push), jadi tidak memakan kuota
  tanpa disengaja.
- Untuk build APK sekali jalan tanpa push: `gh workflow run build-apk.yml`.
- Riwayat pemakaian: **Settings → Billing → Actions usage** (atau
  `gh api /repos/{owner}/{repo}/actions/runs --paginate` lalu lihat `run_started_at`).
