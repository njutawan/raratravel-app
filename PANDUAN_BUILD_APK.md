# 📦 Panduan Build APK — Rara Travel & Tour

Panduan lengkap dari nol sampai APK terinstall di HP, plus persiapan
upload ke Google Play Store. Semua perintah dijalankan dari folder
`raratravel_app/` di komputermu (bukan di sini).

---

## 🗺️ Peta Jenis Build

| Jenis | Perintah | Ukuran | Untuk apa |
|---|---|---|---|
| **APK Debug** | `flutter build apk --debug` | ±30–50 MB | Testing internal, bisa debug |
| **APK Release** | `flutter build apk --release` | ±25–40 MB | Dibagikan via WA/GDrive, install langsung |
| **APK Split ABI** | `... --release --split-per-abi` | ±10–18 MB/arsitektur | Dibagikan — kecil, pilih sesuai HP |
| **AAB Release** | `flutter build appbundle --release` | ±20–30 MB | **Wajib** untuk upload Play Store |

> HP Android modern (2018+) hampir semuanya `arm64-v8a` — jika pakai split,
> bagikan file `app-arm64-v8a-release.apk`.

---

## ⚡⚡ Cara tercepat: build di GitHub Actions (tanpa install apa pun)

Repo ini punya workflow `.github/workflows/build-apk.yml`. Setiap push ke
`master` atau branch `arena/**` (dan setiap perubahan kode Flutter) otomatis
membangunkan APK release di server GitHub lalu:

1. menaruh APK di **folder `apk/`** branch tersebut → cukup `git pull` untuk ambil;
2. mengunggahnya sebagai **artifact** di tab *Actions* → bisa diunduh dari browser.

Memicu build manual dari komputer mana saja (butuh `gh` login):

```bash
gh workflow run build-apk.yml --ref NAMA-BRANCH   # atau klik "Run workflow" di tab Actions
gh run watch                                       # pantau proses build
git pull                                           # ambil APK hasilnya di folder apk/
```

APK hasil cara ini ditandatangani debug key (sama seperti langkah 2 di bawah):
siap di-install & dibagikan, tapi belum untuk Play Store.

---

## 0️⃣ Prasyarat (sekali saja)

```bash
flutter doctor
```

Pastikan minimal 3 ini centang hijau:

- ✅ Flutter SDK (≥ 3.32)
- ✅ Android toolchain (SDK + cmdline-tools)
- ✅ Android Studio
- ✅ JDK 17+ (bawaan Android Studio — jangan pakai JDK 8, Gradle 9 menolak)

Jika ada keluhan lisensi:

```bash
flutter doctor --android-licenses
```

(Enter + ketik `y` untuk semua pertanyaan.)

Lalu siapkan proyek:

```bash
cd raratravel_app
flutter pub get
flutter analyze        # harusnya 0 error (warning info boleh)
```

---

## 1️⃣ APK Debug — untuk testing

```bash
flutter build apk --debug
```

Hasilnya:

```
build/app/outputs/flutter-apk/app-debug.apk
```

Kirim file itu ke HP (WA/kabel/GDrive) → tap → Install.
Cocok untuk: cek tampilan, coba booking, tes tombol WA.

---

## 2️⃣ APK Release — untuk dibagikan ke pengguna

```bash
# Universal (semua HP, 1 file)
flutter build apk --release

# ATAU versi hemat ukuran (3 file per arsitektur CPU)
flutter build apk --release --split-per-abi
```

Hasilnya:

```
build/app/outputs/flutter-apk/app-release.apk            # universal
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  # HP modern → bagikan ini
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk # HP lama (32-bit)
build/app/outputs/flutter-apk/app-x86_64-release.apk      # emulator/tablet Intel
```

> Tanpa `key.properties` (langkah 3), APK release ditandatangani debug key:
> **bisa diinstall langsung, tapi ditolak Play Store.** Untuk dibagikan ke
> sopir/karyawan/pelanggan via WA — ini sudah cukup.

---

## 3️⃣ Signing Rilis + AAB — untuk Google Play Store

Lakukan sekali saja. **Backup file `.jks` + catat password-nya — kalau hilang,
kamu TIDAK BISA update aplikasi di Play Store selamanya.**

### 3a. Buat keystore (kunci rilis)

**Cara otomatis (disarankan)** — skrip membuat keystore + `android/key.properties`
sekaligus, lalu mencetak SHA-1/SHA-256 yang harus didaftarkan ke Firebase &
Play Console:

```bash
bash tools/check_sha.sh --gen-keystore        # Mac/Linux/Git Bash
```
```powershell
.\tools\check_sha.ps1 -GenKeystore            # Windows PowerShell
```

Catat password yang dicetak skrip ke password manager, lalu lanjut ke
langkah 3c (`key.properties` sudah dibuat otomatis). Cek kapan saja dengan
`bash tools/check_sha.sh` — skrip juga memverifikasi SHA mana yang sudah
terdaftar di `google-services.json`.

**Cara manual:**

**Windows (PowerShell):**

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v -storetype JKS -keystore "$env:USERPROFILE\upload-keystore.jks" -keyalg RSA -keysize 2048 -validity 10000 -alias rara-travel
```

**Mac / Linux:**

```bash
keytool -genkeypair -v -storetype JKS -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias rara-travel
```

Isi nama/organisasi (bebas, mis. `Rara Travel`), catat 2 password yang diminta.
File `upload-keystore.jks` akan muncul di folder home → **backup ke 2 tempat**
(flashdisk + cloud).

### 3b. Daftarkan key ke proyek

> Kalau kamu pakai cara otomatis di 3a, langkah ini sudah dikerjakan skrip —
> lanjut langsung ke 3c.

Salin `android/key.properties.example` menjadi `android/key.properties`,
lalu isi:

```properties
storePassword=PASSWORD_YANG_TADI_DIBUAT
keyPassword=PASSWORD_YANG_TADI_DIBUAT
keyAlias=rara-travel
storeFile=C:/Users/NAMA-KAMU/upload-keystore.jks
```

> Pakai garis miring `/` (bukan `\`) walau di Windows.
> Di Mac/Linux: `storeFile=/Users/nama/upload-keystore.jks`.

### 3c. Build App Bundle (.aab)

```bash
flutter build appbundle --release
```

Hasilnya:

```
build/app/outputs/bundle/release/app-release.aab
```

File `.aab` inilah yang diupload ke **Play Console**
(play.google.com/console) → buat aplikasi → rilis produksi.
Saat pertama kali, aktifkan **Play App Signing** (disarankan Google).

---

## 4️⃣ Cara Install ke HP

Pilih salah satu:

1. **Kabel USB (paling gampang saat development)**
   Aktifkan *Developer Options → USB Debugging* di HP → colok kabel →
   ```bash
   flutter devices     # pastikan HP terdaftar
   flutter run         # install + jalankan langsung
   ```
2. **ADB manual** (HP tercolok USB debugging):
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```
3. **Kirim file APK** via WA / Google Drive / bluetooth → di HP tap file →
   izinkan *"Install unknown apps"* → Install.
4. **Emulator**: drag & drop file APK ke jendela emulator.

---

## 5️⃣ Menaikkan Versi (saat update aplikasi)

Di `pubspec.yaml`:

```yaml
version: 1.0.0+1
#        │       └─ versionCode (wajib NAIK tiap upload Play Store)
#        └─ versionName (yang dilihat pengguna)
```

Update bugfix → `1.0.1+2`. Fitur baru → `1.1.0+3`.
Lalu build ulang seperti biasa.

---

## 6️⃣ Troubleshooting

| Gejala | Penyebab & Solusi |
|---|---|
| `flutter.sdk not set` / `SDK location not found` | Buat `android/local.properties` berisi path SDK & Flutter (contoh ada di README), atau buka proyek sekali via Android Studio |
| Build pertama lama / download Gradle | Normal (±5–15 mnt, sekali saja, butuh internet). Jangan tutup terminal |
| `platform android-36 not found` | Android Studio → SDK Manager → centang **Android 16 (API 36)** → Apply |
| `keystore password was incorrect` | Password di `key.properties` salah ketik. Cek: `keytool -list -v -keystore upload-keystore.jks` |
| `keyAlias not found` | Alias salah — harus sama persis (`rara-travel`). Lihat daftar alias dengan perintah `keytool -list` di atas |
| **App not installed** di HP | 1) Uninstall versi lama dulu (beda tanda tangan), 2) storage penuh, 3) file APK corrupt (kirim ulang) |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Sama — uninstall dulu: `adb uninstall com.raratravel.app` |
| Play Console menolak APK | Play Store hanya terima **.aab** (langkah 3c), bukan `.apk` |
| `versionCode X already used` | Naikkan `+N` di `pubspec.yaml` (bagian 5) |
| Icon/nama tidak berubah setelah install | Cache launcher — uninstall total lalu install ulang |
| APK terlalu besar | Pakai `--split-per-abi`, bagikan yang `arm64-v8a` |
| `OutOfMemoryError` saat build | Sudah diset 4 GB di `android/gradle.properties`. Tutup aplikasi lain / tambah RAM |
| Tombol WA tidak bereaksi di emulator | Emulator tidak ada WhatsApp. Test di HP fisik |

---

## 7️⃣ Build Rilis Ringan & Ter-obfuscate (disarankan)

Perintah di langkah 2–3 bisa ditambah 2 flag ini:

```bash
# AAB untuk Play Store (kecil + kode Dart diacak)
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols

# APK split per-ABI (bagi via WA)
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols
```

- `--obfuscate`: mengacak nama class/fungsi di kode Dart → hasil build lebih
  kecil dan jauh lebih sulit di-reverse-engineer. **Aman untuk aplikasi ini**
  (tidak pakai `dart:mirrors`/refleksi; semua JSON ditulis manual).
- `--split-debug-info=build/symbols`: memisahkan peta debug agar tidak ikut
  masuk APK, sekaligus **wajib disimpan** — tanpa folder ini, stack trace crash
  dari Play Console tidak bisa dibaca. Arsipkan per versi (`symbols-1.0.0.zip`,
  `symbols-1.0.1.zip`, dst).
- Membaca crash ter-obfuscate:
  `flutter symbolize -i stacktrace.txt -d build/symbols/app.android-arm64.symbols`

> Catatan: R8/minify sisi Android (`minifyEnabled`) sengaja TIDAK dinyalakan —
> hematnya kecil untuk aplikasi ini (±1–2 MB) dan butuh uji rilis penuh di HP.
> Obfuscation Dart di atas sudah mencakup 95% manfaatnya.

---

## ⚡ Cheatsheet

```bash
flutter doctor                        # cek lingkungan
flutter pub get                       # install package
flutter analyze                       # cek error kode
flutter run                           # testing ke HP/emulator
flutter build apk --debug             # APK testing
flutter build apk --release           # APK rilis (bagi via WA)
flutter build apk --release --split-per-abi   # APK rilis kecil
flutter build appbundle --release     # AAB untuk Play Store
flutter install                       # install hasil build ke HP tercolok
```

Selamat merilis! 🚀 Kalau mentok di satu langkah, tempel pesan error-nya ke
sini — saya bantu sampai APK terinstall.
