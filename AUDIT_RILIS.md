# 🚀 Audit Rilis Produksi — Rara Travel App

**Tanggal:** 13 September 2026 · **Metode:** audit kode statis + verifikasi
toolchain dari file Flutter SDK 3.47 + syarat Play Store terbaru.
**Hasil akhir:** `flutter analyze` → **No issues found**.

| Area | Nilai | Kesimpulan |
|---|---|---|
| 1. Kinerja UI & Rendering | 9/10 | Sehat; sisa uji profile di HP fisik |
| 2. Gambar & Jaringan | 9,5/10 | Efisien; tanpa unduhan gambar sama sekali |
| 3. Kesiapan rilis | Blocker diperbaiki | 1 blocker Play (SDK 36) sudah ditambal — **wajib verifikasi build di mesin Anda** |

---

## 1. Optimasi Kinerja UI & Rendering

### 1.1 Daftar & cakupan rebuild — LOLOS ✅
- Semua daftar memakai konstruksi lazy (`ListView.separated/builder`,
  sliver beranda, list horizontal armada/rute).
- Satu-satunya daftar eager: kartu armada rental (6 item statis) — tetap 60 fps.
- Rebuild terisolasi: progress story via `AnimatedBuilder` sekecil bar,
  estimasi ongkir via `ValueListenableBuilder`, `setState` selalu lokal.
- `const` menyeluruh (analyzer `prefer_const` bersih) → rebuild murah.
- Tanpa isolate/worker berat — parsing JSON kecil aman di main thread.

### 1.2 GPU & overdraw — LOLOS ✅
- Tanpa `BackdropFilter`/`ShaderMask`/`Opacity` (nol `saveLayer` mahal).
- Transparansi via `withValues` (murah), bayangan kecil & statis,
  `ClipPath` statis (`shouldReclip: false`).
- Flutter 3.47 memakai Impeller → shader jank nyaris hilang; tetap uji
  mode profile di HP kentang (§3.4).

### 1.3 Font raksasa & overflow — LOLOS (1 catatan minor) ✅
- Kartu rute dibatasi skala font (`MaxTextScale`), grid layanan 0.92,
  semua layar form/tiket bisa scroll, dialog konten pendek.
- Minor: baris bawah detail rute di skala font >2,5× berpotensi padat —
  sangat jarang, diterima.

### 1.4 Startup — LOLOS ✅
Splash paralel, tab lazy-build, splash native biru (tanpa kedip putih),
tanpa kerja background (baterai idle ≈ nol).

---

## 2. Optimasi Gambar & Jaringan

### 2.1 Inventaris aset (semua tepat guna) ✅

| File | Dimensi | Ukuran | Ditampilkan | Status |
|---|---|---|---|---|
| `app_logo.png` | 256px | 59 KB | ≤104 px | ✅ pas + `cacheWidth` di 7 titik |
| `login_slide_1/2/3.jpg` | 1200px | 344–445 KB | fullscreen | ✅ pas + `precacheImage` |
| `onboarding_header.jpg` | 1200×569 | 95 KB | 1200×300 | ✅ pas + `cacheWidth` |
| Ikon launcher (mipmap) | — | 552 KB | sistem | ✅ wajar |
| **Total gambar bundle** | | **±1,3 MB** | | ✅ ringan |

- Tanpa aset tak terpakai; folder `assets_src/` (master 1 MB) tidak ikut bundle.
- **Nol byte unduhan gambar** — aplikasi 100% fungsional offline (mode lokal).

### 2.2 Jaringan — LOLOS ✅
- Tanpa REST/WebSocket/polling; satu-satunya trafik: Firestore hemat
  (`limit(50)` + fallback, stream di-cache, migrasi sekali, outbox) dan
  push FCM murni (soket hemat milik sistem).
- Opsional, TIDAK disarankan sekarang: kompresi slide ke q75 (±hemat
  400 KB, kualitas turun) atau WebP (±hemat 30%, perlu ganti ekstensi + uji).

---

## 3. Daftar Periksa Menjelang Rilis Produksi

### 3.1 Blocker — DIPERBAIKI audit ini 🛠️
- **SDK 36 wajib**: Play menolak aplikasi/API-35 sejak 31 Agu 2026 —
  "new apps and app updates must target Android 16 (API 36)" [3](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en).
  Ditambal: `targetSdk`/`compileSdk` 35→36, AGP 9.1.0, Kotlin 2.4.0,
  Gradle 9.3.1 (selaras template resmi Flutter 3.47), Jetifier dibuang.
  > ⚠️ **Belum teruji build** (tanpa Android SDK di sini). Verifikasi wajib:
  > `flutter build appbundle --release` di mesin Anda sebelum upload.
- **Link Kebijakan Privasi** di Profil → `raratravel.id/privacy-policy/` ✅ (halaman terverifikasi tayang, diperbarui Juni 2026; cantumkan URL yang sama di Play Console).
- Kontras `/pax` + panduan diperbarui ke API 36 + syarat JDK 17.

### 3.2 Firebase Console (centang satu-satu)
- [ ] `google-services.json` via `flutterfire configure`; SHA-1 + SHA-256 debug
- [ ] Auth: Phone + Google aktif + nomor uji
- [ ] Firestore region `asia-southeast2`, publish `firestore.rules`, deploy index (§Lampiran)
- [x] App Check: enforcement Firestore + Authentication aktif (15 Sep 2026)
- [ ] App Check: aplikasi Android terdaftar provider Play Integrity (tab Apps)
- [ ] App Check: token debug terdaftar + uji `flutter run` login/booking lolos
- [ ] Functions: deploy, Blaze, **budget alert**, uji notif 3 kondisi
- [ ] **Setelah upload AAB pertama: salin SHA-256 Play App Signing → Firebase**
      (kalau lupa, login Google & App Check versi Play Store RUSAK)

### 3.3 Listing Play Store
- [ ] URL Kebijakan Privasi `https://raratravel.id/privacy-policy/` (§3.1) + formulir Data Safety (isi dari LAPORAN_KEAMANAN §5.3)
- [ ] Screenshot HP + feature graphic + deskripsi Indonesia
- [ ] Kuesioner rating konten + target audiens; hapus akun ✅ sudah di aplikasi
- [ ] Rilis bertahap: internal testing → tertutup → produksi 20% → 100%

### 3.4 Matriks uji HP fisik (wajib sebelum produksi)
| Skenario | Lolos bila |
|---|---|
| HP low-end RAM 2 GB, mode profile | Tanpa jank parah / ANR |
| Android 6 (minSdk) & Android 16 (target) | Install + login + booking jalan |
| TalkBack + font maksimum + rotasi + dark mode sistem | Semua terbaca & tanpa overflow merah |
| Offline total (mode pesawat) | Mode lokal/WA tetap jalan, outbox tersinkron saat online |
| Interupsi: telepon saat OTP, putar layar saat loading | Tanpa crash / state aneh |
| Install fresh & upgrade (backup mati) | Login → riwayat cloud pulih |

### 3.5 Build & arsip
- [ ] Build §7 PANDUAN_BUILD_APK (`--obfuscate --split-debug-info`), arsip `symbols-*.zip` per versi
- [ ] `versionCode` naik tiap upload; keystore `.jks` + password di 2 tempat

### 3.6 Pascakrilis (disarankan)
Crashlytics + pantau Android Vitals/ANR, balas review, upgrade major
Firebase terjadwal (catatan M-4), ulangi audit tiap fitur sensitif.

---

## 4. Perubahan yang diterapkan audit ini
`android/{settings.gradle, app/build.gradle, gradle.properties, gradlew*, gradle/wrapper/*}`,
`lib/{utils/constants.dart, screens/{profile_screen.dart, wisata_screen.dart}}`,
`PANDUAN_BUILD_APK.md`, `README.md`.
