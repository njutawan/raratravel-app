# 🔥 Panduan Firebase — Login OTP + Database Cloud

Panduan klik-per-klik: dari nol sampai login OTP SMS jalan dan pesanan
masuk database real-time. Estimasi **1–2 jam**.

**Yang kamu dapat:** login/daftar OTP SMS, database Firestore (`users`,
`bookings`), pesanan terlihat admin real-time, token notifikasi siap.

**Prasyarat:** akun Google, Node.js LTS (nodejs.org), HP Android fisik
(emulator bisa, tapi OTP asli lebih mudah dites di HP).

> Aplikasi tetap jalan **mode offline** (pesanan lokal + WA) selama panduan
> ini belum selesai — tidak ada yang rusak di tengah jalan.

---

## 0️⃣ Install perkakas CLI (sekali saja)

```bash
node -v                                  # pastikan Node.js terinstall
npm install -g firebase-tools
dart pub global activate flutterfire_cli
```

Tutup-buka terminal lagi, lalu cek:

```bash
firebase --version
flutterfire --version
```

> `command not found`? Tambahkan folder pub-cache ke PATH lalu restart
> terminal — Windows: `%LOCALAPPDATA%\Pub\Cache\bin`, Mac/Linux:
> `~/.pub-cache/bin`. Lihat tabel troubleshooting di bawah.

Login ke Firebase:

```bash
firebase login
```

---

## 1️⃣ Buat project Firebase

1. Buka <https://console.firebase.google.com> → **Add project**
2. Nama: `rara-travel` (bebas) → Continue
3. Google Analytics: **OFF** saja (biar cepat) → Create project
4. Catat **Project ID** (mis. `rara-travel-a1b2c`) — dipakai langkah 2

---

## 2️⃣ Hubungkan ke Flutter (`flutterfire configure`)

Dari folder `raratravel_app/`:

```bash
flutterfire configure --project=PROJECT_ID_KAMU
```

- Pilih platform: **Android** (spasi → Enter)
- Package `com.raratravel.app` terdeteksi otomatis → Enter

Perintah ini otomatis mengisi `lib/firebase_options.dart` dan mengunduh
`android/app/google-services.json`. **Jangan edit manual file-file itu.**

> Plugin google-services Gradle (v4.5.0) **sudah terpasang** di proyek
> ini. Jika `flutterfire` menambah baris plugin duplikat, hapus saja
> duplikatnya hingga tersisa satu. Catatan: sejak plugin ini ada, build
> gagal dengan pesan `google-services.json is missing` sampai langkah 2
> ini selesai — itu normal, bukan kerusakan.

Verifikasi:

```bash
ls lib/firebase_options.dart android/app/google-services.json
flutter pub get
```

---

## 3️⃣ Aktifkan login nomor HP + nomor uji

1. Console → **Build → Authentication → Sign-in method → Phone → Enable → Save**
2. Masih di Authentication → tab **Settings → Phone numbers for testing**:
   tambah mis. `+62 812 0000 0001` dengan kode `123456`
   (boleh beberapa nomor). Nomor uji **gratis unlimited** — pakai ini
   selama development agar tidak boros SMS asli.

---

### 3b. Aktifkan login Google (tombol "Lanjut dengan Google")

1. Masih di **Authentication → Sign-in method** → **Google → Enable → Save**
2. Tidak ada kode tambahan — cukup SHA-1 (langkah 4) agar jalan di HP fisik
3. Di emulator tanpa Play Services, login Google gagal → pakai nomor uji

---

## 4️⃣ Daftarkan SHA-1 Android (wajib untuk OTP asli!)

Tanpa ini, OTP nomor asli gagal dengan error `app-not-authorized`.
Nomor uji (langkah 3) tetap jalan tanpa SHA — jadi langkah ini boleh
belakangan, tapi wajib sebelum rilis.

**Ambil SHA-1 debug (development):**

Windows (PowerShell):

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
```

Mac / Linux:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

Salin baris **SHA1**, lalu Console → **Project Settings → Your apps →
aplikasi Android → Add fingerprint** → paste (tambah SHA-256 juga
disarankan). Terakhir unduh ulang `google-services.json` dari halaman
itu dan timpa file di `android/app/` (atau jalankan ulang
`flutterfire configure`).

> Saat rilis Play Store, ulangi dengan keystore rilis
> (`upload-keystore.jks`) + SHA dari Play Console (App integrity).

---

## 5️⃣ Buat database Firestore + rules

1. Console → **Build → Firestore Database → Create database**
2. **Start in production mode** → Location: **asia-southeast2 (Jakarta)**
   (terdekat, tercepat) → Enable
3. Tab **Rules** → hapus isi → paste seluruh `firestore.rules` dari proyek
   ini → **Publish**

Struktur yang dipakai aplikasi (otomatis terbentuk saat ada data):

| Koleksi | ID dokumen | Isi |
|---|---|---|
| `users` | uid Firebase | `phone`, `name`, `fcmTokens`, `createdAt` |
| `bookings` | kode booking | semua field pesanan + `userId`, `status` |

> Rules di atas artinya: user hanya bisa akses datanya sendiri; admin
> lewat Console memakai hak admin (bebas). Aplikasi tidak butuh
> composite index (sort dilakukan di HP).

---

## 6️⃣ Jalankan & uji end-to-end

```bash
flutter run
```

1. Buka tab **Pesananku** → **Masuk / Daftar** → pakai **nomor uji** +
   kode uji → berhasil masuk
2. Buat booking travel → tekan **Buat Pesanan** (nama/WA terisi otomatis
   sebagian) → konfirmasi WA seperti biasa
3. Buka Console → **Firestore → bookings** → dokumen pesananmu muncul
   **real-time** 🎉
4. Uji sinkron: install di 2 HP, login nomor sama → riwayat sama persis
5. Uji keluar: tab **Profil → Keluar** → Pesananku kembali minta login

---

## 7️⃣ Cara admin melihat & memproses pesanan

- Console → **Firestore → bookings**: semua pesanan semua user, update
  otomatis tanpa refresh. Klik dokumen untuk detail + jemput/antar.
- Ubah status manual: klik field `status` → ganti `Menunggu Konfirmasi`
  menjadi `Dikonfirmasi` → badge di HP user ikut berubah otomatis
  (stream real-time).
- Cari pesanan: tombol filter di tabel → mis. `status == Menunggu Konfirmasi`.
- Nanti bisa dibuatkan **panel admin web** terpisah bila pesanan ramai.

---

## 8️⃣ Notifikasi push (opsional, fase 2)

Token FCM tiap HP **sudah tersimpan otomatis** di `users/{uid}.fcmTokens`
saat login. Tinggal deploy 1 Cloud Function contoh:

```bash
# di folder proyek Firebase (bukan folder Flutter)
firebase init functions     # pilih JavaScript, install otomatis
# timpa functions/index.js + package.json dengan isi functions_sample/
cd functions && npm install && cd ..
firebase deploy --only functions
```

Cara kerja: admin ubah `status` di Console → function
`notifStatusPesanan` kirim notifikasi *"Pesanan RARA-XXXX: Dikonfirmasi"*
ke HP user.

File contoh sudah mencakup **rate limiting anti-spam**: endpoint callable
`mintaPenawaran` dibatasi per IP + per user login, dan trigger notifikasi
dibatasi 1x/menit per kode booking (atur angkanya di tabel `BATAS` dalam
`index.js`). Setelah deploy, aktifkan **TTL policy** Firestore untuk koleksi
`rateLimits` pada field `kedaluwarsa` agar dokumen hitungan terhapus otomatis.

> Butuh paket **Blaze** (pay-as-you-go). Free tier Functions (2 juta
> pemanggilan/bulan) sangat cukup untuk skala travel.

---

## 💰 Ringkas biaya (cek halaman pricing resmi untuk angka terbaru)

- **Nomor uji**: gratis unlimited ♾️
- **SMS OTP asli**: kuota gratis harian kecil di paket Spark; selebihnya
  ratusan–ribuan rupiah per SMS (butuh Blaze). Selama testing pakai
  nomor uji = Rp0.
- **Firestore**: ±50rb baca + 20rb tulis/hari gratis — cukup untuk
  ratusan pesanan per hari.
- Saran: mulai di **Spark** (gratis); naik ke Blaze saat SMS/produk live.

---

## 6️⃣ Troubleshooting

| Gejala | Solusi |
|---|---|
| `flutterfire: command not found` | PATH pub-cache belum diset (langkah 0). Restart terminal setelah set PATH |
| `invalid-api-key` / app force close saat login | `google-services.json` salah project / belum `flutterfire configure`. Ulangi langkah 2 |
| `app-not-authorized` / DEVELOPER_ERROR | SHA-1 belum didaftarkan (langkah 4). Sementara pakai nomor uji |
| SMS tidak datang-datang | Pakai nomor uji dulu; cek format +62; cek kuota Spark; sinyal HP |
| Kode uji selalu salah | Nomor + kode harus **persis** seperti di Console (termasuk +62) |
| `PERMISSION_DENIED` Firestore | Rules belum dipublish (langkah 5). Tunggu ±1 mnt setelah Publish |
| Build error `minSdk` / `play-services` | Pastikan `flutterfire configure` selesai penuh; `flutter clean` lalu build ulang |
| Stream pesanan tidak update | Cek internet; pastikan login nomor yang sama; cek Console → bookings ada datanya |
| Login berputar terus | Biasanya jaringan emulator lambat — coba HP fisik |

---

## ⚡ Cheatsheet

```bash
flutterfire configure --project=PROJECT_ID   # hubungkan Firebase
flutter pub get && flutter run               # jalan + uji
firebase deploy --only firestore:rules       # publish rules via CLI (alternatif)
```

Selamat — aplikasimu sekarang punya backend sungguhan! 🚀
Kalau mentok, tempel pesan error-nya ke sini.

---

## Lampiran: Index Firestore untuk Riwayat Cepat (opsional, disarankan)

File `firestore.indexes.json` berisi composite index `bookings(userId, createdAt)`
agar tab Pesananku memakai `orderBy` server + `limit(50)` (hemat baca, anti-jebol
saat user punya 100+ pesanan). Tanpa index, aplikasi otomatis fallback ke query
biasa — tetap jalan, tapi pasang indexnya:

**Cara 1 — Firebase CLI (sekali saja):**

```bash
npm i -g firebase-tools
firebase login
firebase init firestore   # pilih proyekmu, Enter saja (pakai firestore.indexes.json yg ada)
firebase deploy --only firestore:indexes
```

**Cara 2 — Klik link dari error:** buka tab Pesananku saat online → bila index
belum ada, salin link `console.firebase.google.com/.../create_composite` dari
log, buka di browser → Create. Atau manual: Firestore → Indexes → Add:
collection `bookings`, field `userId` Ascending + `createdAt` Descending,
query scope Collection.
