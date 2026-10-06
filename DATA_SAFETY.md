# 🛡️ Data Safety Play Console — Lembar Jawab Rara Travel & Tour

**Untuk:** pengisian formulir *Play Console → Policy → App content → Data safety*.
**Dasar:** pembacaan kode aplikasi (bukan perkiraan) — setiap jawaban di bawah
menyebut berkas buktinya. Diperbarui: 6 Oktober 2026.

> Cara pakai: buka formulirnya di Play Console, lalu isi **berurutan** dari
> §2 → §3 → §4 → §5 → §6. Bagian §7 adalah daftar periksa sebelum *Submit*.
> Bila ada jawaban yang berubah karena fitur baru, lihat §8.

---

## 1. Ringkasan 30 detik

| Pertanyaan besar Play | Jawaban | Alasan singkat |
|---|---|---|
| Apakah aplikasi mengumpulkan/membagikan data pengguna? | **Ya** | Nama, no. HP, alamat jemput/antar, email (opsional), riwayat pesanan, foto bukti bayar, token FCM, log crash |
| Semua data terenkripsi saat dikirim? | **Ya** | Hanya HTTPS; `usesCleartextTraffic="false"` + `network_security_config.xml` |
| Ada cara meminta penghapusan data? | **Ya** | Profil → **Hapus Akun** (menghapus Firebase + Supabase + berkas) **dan** halaman web `docs/hapus-akun.html` |
| Ada iklan / SDK iklan? | **Tidak** | Tidak ada paket iklan di `pubspec.yaml` → pertanyaan advertising dijawab *No* |
| Data dijual ke pihak ketiga? | **Tidak** | Tidak ada penjualan data; pihak ketiga hanya pemroses (Firebase, Supabase, Midtrans) |

---

## 2. Tiga pertanyaan pembuka formulir

1. **"Does your app collect or share any of the required user data types?"** → **Yes**
2. **"Is all of the user data collected by your app encrypted in transit?"** → **Yes**
   Bukti: `android/app/src/main/AndroidManifest.xml`
   (`android:usesCleartextTraffic="false"`), `android/app/src/main/res/xml/network_security_config.xml`,
   dan semua URL di `lib/utils/constants.dart` berawalan `https://`.
3. **"Do you provide a way for users to request that their data is deleted?"** → **Yes**
   Lihat §3 (dua jalur: di dalam aplikasi **dan** tautan web — keduanya wajib).

---

## 3. Bagian *Data deletion* (wajib diisi, sering bikin ditolak)

Google mensyaratkan **dua jalur** untuk aplikasi yang punya pendaftaran akun:
jalur di dalam aplikasi **dan** tautan web yang bisa dipakai tanpa memasang
aplikasi. Aplikasi ini sudah punya jalur dalam-aplikasi; **tautan web masih
harus kamu terbitkan**.

| Isian formulir | Jawaban / isi |
|---|---|
| Does your app allow users to request deletion of their account? | **Yes** |
| In-app deletion path (deskripsi) | "Buka aplikasi → tab **Profil** → kartu akun → **Hapus Akun** → konfirmasi. Aplikasi menghapus profil, seluruh pesanan, pembayaran, token perangkat, dan berkas bukti transfer di server, lalu menghapus akun login." |
| **Web link for account/data deletion** (kolom URL) | `https://raratravel.id/hapus-akun/` ← terbitkan dulu `docs/hapus-akun.html` ke alamat ini |
| Is the deletion path discoverable? | Ya — di layar Profil, tanpa perlu menggali menu |

**Yang benar-benar dihapus** (bukti: `lib/utils/hapus_akun.dart`,
`lib/services/auth_service.dart` → `deleteAccount`,
`supabase/migrations/202609140010_purge_user.sql`,
`supabase/functions/auth-user-sync/index.ts` aksi `purge`):

| Tempat | Yang dihapus |
|---|---|
| Supabase Storage | berkas di bucket `avatars` + `payment-proofs` milik pengguna |
| Supabase (PostgreSQL) | baris `public.users` → `bookings`, `payments`, `user_devices`, antrean notifikasi ikut terhapus (cascade) |
| Firestore | semua dokumen `bookings` milik `userId` + dokumen `users/{uid}` |
| Firebase Auth | akun login (OTP/Google) dihapus |
| Perangkat | riwayat pesanan lokal + preferensi |

**Penting:** aplikasi hanya melanjutkan penghapusan akun bila server
mengonfirmasi data sudah hilang (`deleted: true` atau `user_not_found`).
Bila jaringan gagal, akun **tidak** dihapus dan pengguna diberi pesan jelas —
jadi tidak ada janji "terhapus" yang palsu.

**Retensi:** saat ini tidak ada data yang disimpan setelah penghapusan.
Bila kelak kamu perlu menyimpan bukti pembayaran untuk kewajiban pajak,
nyatakan di halaman web + kebijakan privasi ("disimpan X tahun untuk kewajiban
hukum") — jawaban formulirnya tetap *Yes*, tapi pengecualiannya wajib diungkap.

---

## 4. Tipe data yang **DIKUMPULKAN** (centang di formulir)

Isi per baris: *Collected* = data meninggalkan perangkat; *Shared* = diberikan
ke pihak ketiga untuk kepentingannya sendiri. Pemroses (hosting, auth, push)
**bukan** "shared" menurut definisi Google — tapi tetap dicantumkan di §6 agar
jelas.

| # | Kategori Play | Tipe data | Collected | Shared | Tujuan (*purposes*) | Opsional? | Terenkripsi | Bisa dihapus |
|---|---|---|---|---|---|---|---|---|
| 1 | Personal info | **Name** | ✅ | ❌ | App functionality, Account management | Wajib (untuk pesanan) | ✅ | ✅ |
| 2 | Personal info | **Phone number** | ✅ | ❌ | App functionality, Account management, Fraud prevention/security | Wajib (login OTP) | ✅ | ✅ |
| 3 | Personal info | **Email address** | ✅ | ❌ | Account management | **Opsional** (hanya bila login Google) | ✅ | ✅ |
| 4 | Personal info | **Address** (alamat jemput & antar) | ✅ | ❌ | App functionality | Wajib untuk layanan door-to-door | ✅ | ✅ |
| 5 | Personal info | **User IDs** (Firebase UID) | ✅ | ❌ | App functionality, Account management | Wajib | ✅ | ✅ |
| 6 | Financial info | **Purchase history** (pesanan, total harga, metode & status bayar) | ✅ | ❌ | App functionality | Wajib | ✅ | ✅ |
| 7 | Photos or videos | **Photos** (foto bukti transfer dari galeri/kamera) | ✅ | ❌ | App functionality | **Opsional** (hanya jalur transfer manual) | ✅ | ✅ |
| 8 | Files and docs | **Files** (PDF bukti transfer, bila diizinkan bucket) | ✅ | ❌ | App functionality | **Opsional** | ✅ | ✅ |
| 9 | Device or other IDs | **Device or other IDs** (token FCM, Firebase installation ID, platform + versi aplikasi) | ✅ | ❌ | App functionality (push notifikasi), Fraud prevention/security (Play Integrity) | Wajib untuk notifikasi | ✅ | ✅ |
| 10 | App info and performance | **Crash logs** & **Diagnostics** (Crashlytics, hanya build rilis) | ✅ | ❌ | Analytics, App functionality | Otomatis di rilis | ✅ | ⚠️ lihat catatan |
| 11 | App activity | **App interactions** (pesanan dibuat/dibatalkan, status berubah) | ✅ | ❌ | App functionality | Wajib | ✅ | ✅ |

Catatan baris 10: log Crashlytics terikat *instance* aplikasi, bukan akun
pengguna, dan tidak bisa dihapus lewat tombol Hapus Akun. Dua pilihan yang
sama-sama diterima Google:
* jawab **"No"** pada *"Can users request this data be deleted?"* untuk crash
  logs (jujur & umum dipakai), **atau**
* aktifkan penghapusan berbasis instance di Crashlytics lalu jawab *Yes*.
Jangan menjawab *Yes* tanpa mekanismenya — itu yang memicu penolakan.

**Financial info → Payment info: TIDAK dicentang.** Aplikasi tidak pernah
menerima/menyimpan nomor kartu, CVV, atau data rekening. Pembayaran online
(bila diaktifkan) membuka halaman Midtrans; data kartu diproses Midtrans,
bukan aplikasi. Bila kelak kamu menyimpan nomor VA/rekening pengguna di
database sendiri, tambahkan *Payment info* di tabel ini.

---

## 5. Tipe data yang **TIDAK** dikumpulkan (jangan dicentang)

| Kategori | Status | Alasan (bukti) |
|---|---|---|
| **Location** (approximate/precise) | ❌ Tidak | Tidak ada izin lokasi di `AndroidManifest.xml` (hanya `INTERNET` + `POST_NOTIFICATIONS`). Alamat jemput/antar adalah **teks yang diketik pengguna** → masuk *Personal info: Address*, bukan Location |
| **Messages** (SMS/email/chat) | ❌ Tidak | OTP dikirim Firebase Auth; aplikasi tidak membaca SMS (tidak ada `READ_SMS`/`RECEIVE_SMS`) |
| **Contacts** | ❌ Tidak | Tidak ada izin kontak |
| **Calendar** | ❌ Tidak | Tidak ada izin kalender |
| **Health and fitness** | ❌ Tidak | — |
| **Audio files** | ❌ Tidak | Tidak ada perekaman suara |
| **Web browsing history** | ❌ Tidak | Tidak ada WebView; `url_launcher` hanya membuka aplikasi/browser luar |
| **App activity → In-app search history** | ❌ Tidak | Kueri pencarian rute (`origin`, `destination`, `date`, `q`) dikirim ke Edge Function `search-routes` **hanya untuk dibaca** — tidak ada tabel/log yang menyimpannya (`supabase/functions/search-routes/index.ts` hanya memanggil RPC baca). Masuk pengecualian *ephemeral processing*. Bila kelak kueri disimpan, centang tipe ini |
| **Advertising ID** | ❌ Tidak | Tidak ada SDK iklan; `AD_ID` tidak dipakai |
| **Installed apps** | ❌ Tidak | Tidak ada kueri paket (`<queries>` di manifest hanya untuk `https`/`tel`/`mailto` agar `url_launcher` bisa membuka WA/telepon/email) |

---

## 6. Pihak ketiga yang terlibat (jawaban *sharing* = **No**, tapi sebutkan di kebijakan privasi)

| Pihak | Peran | Data yang diproses | Dasar |
|---|---|---|---|
| Google **Firebase Authentication** | login OTP SMS + Google | no. HP, email/nama dari Google, UID | pemroses (service provider) |
| Google **Cloud Firestore** | cadangan profil & pesanan | nama, no. HP, email, pesanan | pemroses |
| Google **Cloud Messaging (FCM)** | push notifikasi status pesanan | token FCM, platform, versi aplikasi | pemroses |
| Google **Crashlytics** | laporan crash (rilis saja) | log crash, info perangkat | pemroses |
| Google **App Check / Play Integrity** | anti-penyalahgunaan API key | sinyal integritas perangkat & aplikasi | pemroses (fraud prevention) |
| **Supabase** (hosting AWS) | database utama, Storage berkas | profil, pesanan, pembayaran, token perangkat, bukti transfer | pemroses |
| **WhatsApp / Meta** | pengguna menekan tombol konfirmasi → pesan terbuka di WA | isi pesan yang **diketik/dipilih pengguna** | transfer atas inisiatif pengguna (*user-initiated*) → bukan "sharing" |
| **Midtrans** (bila `PAYMENTS_ENABLED=true`) | pembayaran online | jumlah tagihan, kode pesanan; data kartu diproses Midtrans | pemroses pembayaran |

Karena tidak ada pihak yang memakai data ini untuk kepentingannya sendiri
(iklan, penjualan data, dsb.), jawaban **"Do you share user data with third
parties?" = No** adalah jawaban yang benar menurut definisi Google. Tetap
cantumkan daftar di atas pada Kebijakan Privasi (`https://raratravel.id/privacy-policy/`)
agar konsisten — ketidakcocokan formulir vs kebijakan privasi adalah penyebab
penolakan yang paling sering.

---

## 7. Checklist sebelum menekan *Submit*

- [ ] `docs/hapus-akun.html` sudah diunggah dan **tayang** di URL yang kamu
      tulis di formulir (uji dari browser HP, tanpa login, tanpa error).
- [ ] URL itu menyebut nama aplikasi **persis** seperti di listing
      ("Rara Travel & Tour") dan menyediakan cara meminta penghapusan
      (email `raratravel131@gmail.com` / WA `0812-2509-3894`).
- [ ] Kebijakan Privasi di `https://raratravel.id/privacy-policy/` memuat
      daftar data yang sama dengan §4 (nama, no. HP, alamat, email opsional,
      riwayat pesanan, foto bukti bayar, token perangkat, log crash).
- [ ] Tombol **Hapus Akun** benar-benar jalan di APK yang diunggah
      (uji: hapus → login ulang dengan nomor yang sama → riwayat kosong).
- [ ] Jawaban *encrypted in transit* = Yes **dan** tidak ada satu pun panggilan
      `http://` di kode (ditegakkan `usesCleartextTraffic="false"`).
- [ ] Tidak ada tipe data §5 yang tercentang (terutama **Location** — sering
      salah centang karena ada field alamat).
- [ ] Bila pembayaran online aktif: Midtrans disebutkan di kebijakan privasi.
- [ ] Bagian *App content* lain lengkap: privacy policy URL, target audience,
      content rating, ads = **No**.

---

## 8. Bila fitur berubah, perbarui jawaban ini

| Perubahan | Yang harus ditambah di formulir |
|---|---|
| Menambah analytics (mis. GA4/Firebase Analytics) | *App activity → Other in-app messages / App interactions* + *Analytics*; sebut SDK-nya di kebijakan privasi |
| Menambah iklan (AdMob dsb.) | *Device or other IDs → Advertising ID*, tujuan *Advertising or marketing*, dan *Ads = Yes* di App content |
| Menyimpan nomor VA/rekening pengguna | *Financial info → Payment info* |
| Menyimpan riwayat pencarian di server | *App activity → In-app search history* |
| Menambah izin lokasi (mis. tracking armada) | *Location → Precise/Approximate* + izin runtime + penjelasan tujuan |
| Menambah chat dalam aplikasi | *Messages → In-app messages* |

Perbarui berkas ini **bersamaan** dengan perubahan kodenya, lalu isi ulang
formulir Data Safety (Play meminta deklarasi ulang setiap ada perubahan
pengumpulan data, dan ketidakcocokan memicu peninjauan manual).

---

## 9. Bukti di kode (untuk audit internal)

| Klaim | Berkas |
|---|---|
| Hanya izin INTERNET + POST_NOTIFICATIONS | `android/app/src/main/AndroidManifest.xml` |
| Tanpa backup cloud & tanpa HTTP polos | `AndroidManifest.xml` (`allowBackup="false"`, `usesCleartextTraffic="false"`), `res/xml/network_security_config.xml` |
| Data profil: nama, no. HP, email, token FCM | `lib/models/app_user.dart` |
| Data pesanan: asal/tujuan, tanggal, alamat jemput-antar, kursi, harga, metode bayar, promo | `lib/models/booking.dart` |
| Foto/PDF bukti transfer | `lib/screens/payment_sheet.dart`, bucket `payment-proofs` di `supabase/migrations/202609140008_storage.sql` |
| Token FCM + platform + versi aplikasi | `lib/services/messaging_service.dart`, tabel `user_devices` |
| Crashlytics hanya di build rilis | `lib/services/firebase_bootstrap.dart` (`!kDebugMode`) |
| Hapus akun: server dulu, baru akun | `lib/utils/hapus_akun.dart`, `lib/services/auth_service.dart`, `supabase/migrations/202609140010_purge_user.sql` |
| Kueri pencarian tidak disimpan | `supabase/functions/search-routes/index.ts` |
| Kontak resmi & URL kebijakan privasi | `lib/utils/constants.dart` |

---

*Lembar ini pasangan dari `LAPORAN_KEAMANAN.md` §5.3 dan `RILIS_PRODUKSI.md`
poin 8. Simpan sebagai bukti due-diligence sebelum submit ke Play Store.*
