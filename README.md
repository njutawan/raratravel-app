# Rara Travel & Tour — Aplikasi Android (Flutter)

Aplikasi booking travel antar kota **Rara Travel & Tour (raratravel.id)**:
travel reguler door-to-door, sewa mobil, paket wisata, kirim paket kilat,
riwayat pesanan offline, dan konfirmasi otomatis via WhatsApp admin
(**0812-2509-3894**).

> Data rute, harga, jadwal, armada, dan kontak disalin dari website resmi
> raratravel.id (diakses September 2026). Sesuaikan lagi sebelum rilis.

---

## ✨ Fitur

| Fitur | Keterangan |
|---|---|
| 🏠 Beranda | Pencarian (dari–ke–tanggal), menu layanan, rute populer, armada, promo, kontak 24 jam |
| 🔍 Cari Travel | Filter asal/tujuan/tanggal, urut termurah–termahal |
| 📄 Detail Rute | Jadwal, armada, fasilitas, deskripsi, pilih tanggal & jam |
| 📝 Booking | Form nama, WA, alamat jemput/antar, jumlah kursi, metode bayar, hitung total otomatis |
| 🎫 Tiket | Kode booking unik + tombol **konfirmasi via WhatsApp** (pesan terisi otomatis) |
| 🧾 Pesananku | Riwayat tersimpan di HP (offline), detail, batalkan, hapus |
| 🚗 Sewa Mobil | Calya–Elf Long, harga +sopir & lepas kunci, pesan via WA |
| 🏝️ Paket Wisata | Bromo, Ijen, Bali, Nusa Penida, Papuma + tombol tanya via WA |
| 📦 Kirim Paket | Estimasi ongkir otomatis + pesan jemput via WA |
| 👤 Profil | Tentang kami, ketentuan/refund, kontak, sosmed, website |

**Tanpa server / tanpa login** — cocok sebagai MVP. Semua pesanan masuk ke
WhatsApp admin dalam format rapi. Nanti bisa disambung ke Firebase/API.

---

## 📁 Struktur Proyek

```
raratravel_app/
├── pubspec.yaml                 # nama app + dependencies
├── lib/
│   ├── main.dart                # entry point
│   ├── app.dart                 # MaterialApp + bottom navigation
│   ├── theme/app_theme.dart     # warna & gaya (biru + oranye)
│   ├── utils/
│   │   ├── constants.dart       # ⭐ NOMOR WA, ALAMAT, KOTA — ubah di sini
│   │   └── formatters.dart      # format Rp & tanggal Indonesia
│   ├── config/
│   │   ├── supabase_config.dart # URL + anon key (dari --dart-define)
│   │   └── backend_config.dart  # ⭐ sakelar migrasi (katalog/pesanan/bayar)
│   ├── models/                  # TravelRoute, Armada, WisataPaket, Booking
│   ├── data/dummy_data.dart     # ⭐ RUTE, HARGA, JADWAL (sumber data lokal)
│   ├── repositories/            # jembatan ke Edge Function Supabase
│   │   ├── booking_repository.dart
│   │   ├── catalog_repository.dart
│   │   └── payment_repository.dart
│   ├── services/
│   │   ├── booking_storage.dart # simpan riwayat (SharedPreferences)
│   │   ├── edge_client.dart     # panggil Edge Function + token Firebase
│   │   └── whatsapp_service.dart# buka WA / telepon / email / link
│   ├── widgets/                 # kartu rute, judul seksi, badge, dll.
│   └── screens/                 # 11 layar (splash → profil)
└── android/                     # konfigurasi Android (Manifest, Gradle)
```

---

## 🚀 Cara Menjalankan

### Konfigurasi Supabase (opsional selama migrasi)

Firebase Auth dan FCM **tetap** digunakan; Supabase menggantikan Firestore
sebagai tempat data (katalog, pesanan, perangkat, pembayaran).

Menyiapkan proyek Supabase (migrasi database, secrets, deploy 10 Edge Function,
verifikasi) — sekali jalan dan aman diulang:

```bash
cp .env.supabase.example .env.supabase   # isi project ref, password DB, project Firebase
bash tools/setup_supabase.sh             # ada juga --check dan --step <n>
```

Tanpa Supabase CLI? Semua bisa lewat Dashboard: tempel 11 berkas
`supabase/migrations/*.sql` di SQL Editor, lalu 10 berkas siap tempel
`supabase/deploy-dashboard/*.ts` di Edge Functions (matikan “Verify JWT”).
Langkah bergambarnya (termasuk tips PowerShell) ada di `MIGRASI_SUPABASE.md` §2.5.

Di Windows ada dua pembantu:

```powershell
.\tools\paste_migrations.ps1                              # panduan menempel 11 migrasi
.\tools\verify_supabase.ps1 -AnonKey "<kunci publik>"      # periksa kesiapan proyek
``` Jangan commit key ke repository — konfigurasi
aplikasi diberikan saat build:

```powershell
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://PROJECT.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=ANON_KEY `
  --dart-define=CATALOG_SOURCE=local `
  --dart-define=BOOKING_WRITE=dual
```

| Sakelar build | Pilihan | Arti |
|---|---|---|
| `SUPABASE_ANON_KEY` | `sb_publishable_…` / `eyJ…` | kunci publik proyek (aman di aplikasi) |
| `CATALOG_SOURCE` | `local` / `supabase` | asal data rute, jadwal, harga |
| `BOOKING_WRITE` | `dual` / `supabase` / `firestore` | tujuan penulisan pesanan |
| `PAYMENTS_ENABLED` | `false` / `true` | tampilkan pembayaran online |
| `EDGE_TIMEOUT` | detik (15) | batas tunggu panggilan server |

Selama `BOOKING_WRITE=dual`, pesanan **tetap** ditulis ke Firestore sehingga
tidak ada risiko kehilangan data; penulisan itu baru dimatikan (`supabase`)
setelah seluruh langkah migrasi lolos checklist.

Berkas terkait:

| Berkas | Isi |
|---|---|
| `MIGRASI_SUPABASE.md` | panduan lengkap: penyiapan, deploy, secrets, uji, impor data, rollback |
| `tools/setup_supabase.sh` | skrip penyiapan proyek (8 langkah, `--check`, `--step`) |
| `supabase/deploy-dashboard/` | 10 Edge Function siap tempel untuk Dashboard (tanpa CLI) |
| `tools/verify_supabase.ps1` | pemeriksa kesiapan proyek Supabase (Windows) |
| `.env.supabase.example` | contoh setelan lokal (salin jadi `.env.supabase`, jangan di-commit) |
| `supabase/migrations/*.sql` | 11 berkas migrasi (skema, RPC, trigger, seed, storage, admin) |
| `supabase/functions/` | 10 Edge Function (auth sync, katalog, booking, bayar, notifikasi, admin) |
| `lib/config/backend_config.dart` | sakelar migrasi di sisi aplikasi |
| `lib/repositories/` | jembatan aplikasi → Edge Function |

Uji backend tanpa Docker/Supabase CLI (butuh Python 3 + `pgserver`):

```bash
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install pgserver "psycopg[binary]"   # sekali saja
/tmp/venv/bin/python tools/db_check.py      # migrasi + 17 kelompok uji + kecocokan RPC
node tools/ts_check.js                      # impor & nama ekspor Edge Function
node tools/e2e/run_e2e.mts                  # Edge Function benar-benar dijalankan
```

`run_e2e.mts` menjalankan kesepuluh Edge Function di atas PostgreSQL 16 asli
(tiruan PostgREST + Storage) dengan token Firebase, FCM, dan Snap yang ditiru —
18 skenario: katalog, login, perangkat, pemesanan (harga/kursi/idempotensi),
pembayaran manual & webhook Midtrans, notifikasi FCM, unggah berkas, impor
admin, hingga pemeriksaan batas peran.

### 1. Installalat (sekali saja)

1. Install **Flutter SDK** (versi 3.32 atau lebih baru — disarankan stabil terbaru): <https://docs.flutter.dev/get-started/install>
2. Install **Android Studio** + **Android SDK** (API 34) + emulator/HP fisik.
3. Cek instalasi:
   ```bash
   flutter doctor
   ```
   Ikuti sarannya sampai semua centang hijau (terima lisensi: `flutter doctor --android-licenses`).

### 2. Buka proyek & install package

```bash
cd raratravel_app
flutter pub get
```

### 3. Jalankan

```bash
# lihat daftar HP/emulator yang tersambung
flutter devices

# jalankan (ganti chrome jika mau coba versi web)
flutter run
```

> **Tanpa HP Android?** Di Android Studio: *Device Manager → Create Device →
> Play*. Atau coba cepat versi web: `flutter run -d chrome`.

### 4. Build APK untuk dibagikan/diinstall

```bash
# APK debug (cepat, untuk testing ke HP)
flutter build apk --debug

# APK release (ukuran kecil, siap dibagikan)
flutter build apk --release

# App Bundle (untuk upload ke Google Play Store)
flutter build appbundle --release
```

Hasil APK ada di `build/app/outputs/flutter-apk/app-release.apk`.
Salin ke HP → tap file → Install.

---

## ✏️ Cara Ubah Data (penting!)

| Yang diubah | File | Cara |
|---|---|---|
| Nomor WA admin, alamat, email, sosmed | `lib/utils/constants.dart` | Ganti `phoneWa` (format `62...`), `phoneDisplay`, `address`, dll. |
| Rute, harga, jadwal, durasi | `lib/data/dummy_data.dart` | Edit/tambah item di list `routes` |
| Armada & harga sewa | `lib/data/dummy_data.dart` | Edit list `armada` |
| Paket wisata | `lib/data/dummy_data.dart` | Edit list `wisata` |
| Warna & tema | `lib/theme/app_theme.dart` | Ganti `primary` / `accent` |
| Nama & ID aplikasi | `pubspec.yaml` + `android/app/build.gradle` (`applicationId`) + `AndroidManifest.xml` (`android:label`) | |

Setelah mengubah, jalankan ulang (`flutter run`) — tidak perlu coding lain.

---

## 🎨 Icon & Splash Screen

- **Master logo**: `assets_src/icon_master.png` (logo pin+swoosh biru-orange).
- **Launcher icon**: otomatis tersedia untuk semua densitas
  (`mipmap-mdpi` … `xxxhdpi`), versi bulat (`ic_launcher_round`),
  adaptive icon (API 26+), dan Splash Screen API (Android 12+).
- **Splash berlapis**: splash native Android (logo di tengah layar biru)
  → splash Flutter (`lib/screens/splash_screen.dart`) → beranda.
- **Logo di dalam aplikasi**: splash, header beranda, dan profil memakai
  `assets/icon/app_logo.png`.

Mau ganti logo sendiri? Timpa `assets_src/icon_master.png` (persegi,
minimal 1024px) lalu jalankan:

```bash
pip install pillow
python3 tools/make_icons.py
flutter run
```

---

## 🔥 Firebase (Login OTP + Database Cloud)

Aplikasi mendukung mode cloud (opsional): login OTP SMS, pesanan tersimpan
di Firestore (koleksi `users` & `bookings`), dan siap notifikasi push.

- **Belum setup?** Aplikasi tetap jalan **mode offline** (pesanan lokal + WA).
- **Panduan klik-per-klik:** baca **`PANDUAN_FIREBASE.md`**.

---

## 🛠️ Troubleshooting

- **`flutter.sdk not set in local.properties`** → Buka proyek sekali via
  Android Studio, atau buat file `android/local.properties` berisi:
  ```
  sdk.dir=C\:\\Users\\NAMA\\AppData\\Local\\Android\\sdk
  flutter.sdk=C\:\\src\\flutter
  ```
  (sesuaikan path; di Mac/Linux gunakan `/Users/...` atau `/home/...`).
- **Error `CardThemeData` / API tidak ditemukan** → Flutter Anda terlalu
  lama. Jalankan `flutter upgrade` (proyek ini butuh Flutter ≥ 3.32).
- **`Permission denied` saat build (Mac/Linux)** → jalankan
  `chmod +x android/gradlew`, lalu ulangi build.
- **`platform android-36 not found`** → buka Android Studio → SDK Manager →
  centang **Android 16 (API 36)** → Apply.
- **`flutter pub get` gagal / versi conflict** → jalankan
  `flutter upgrade`, lalu `flutter pub get` lagi.
- **Tombol WA tidak membuka apa-apa (di emulator)** → emulator tidak ada
  aplikasi WhatsApp/browser. Coba di HP fisik.
- **Build release ditolak Play Store (signing)** → release bawaan memakai
  debug key. Untuk Play Store, buat keystore sendiri:
  <https://docs.flutter.dev/deployment/android#signing-the-app>.

---

## 🔮 Ide Pengembangan Lanjutan

1. **Firebase** — login OTP, database pesanan real-time, notifikasi.
2. **Payment gateway** (Midtrans/Xendit) — bayar QRIS/VA langsung di app.
3. **Panel admin web** — kelola rute, harga, jadwal tanpa update app.
4. **Lacak armada** — share live location driver via Google Maps.
5. **Multi-bahasa** (ID/EN) untuk turis Bali.

---

Dibuat dengan Flutter 💙 untuk **Rara Travel & Tour — raratravel.id**
*Mitra Perjalanan Terbaik, Amanah, dan Tepat Waktu.*
