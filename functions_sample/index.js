// CONTOH Cloud Functions: notifikasi status pesanan + rate limiting anti-spam.
//
// Cara pakai (lihat PANDUAN_FIREBASE.md langkah 8):
//   1. firebase init functions  (di folder proyek Firebase, pilih JavaScript)
//   2. Timpa functions/index.js hasil init dengan file ini
//   3. npm install && firebase deploy --only functions
//
// WAJIB setelah deploy (1 menit, sekali saja):
//   Firebase Console → Firestore → TTL policies → aktifkan TTL untuk
//   koleksi `rateLimits` pada field `kedaluwarsa`, agar dokumen hitungan
//   kedaluwarsa otomatis terhapus dan tidak menumpuk/makan biaya baca.
//
// Catatan: butuh paket Blaze (pay-as-you-go). Free tier Functions
// (2 juta pemanggilan/bulan) lebih dari cukup untuk skala travel.
const {onDocumentUpdated} = require('firebase-functions/v2/firestore');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();

// ─── Konfigurasi batas laju ─────────────────────────────────────────────
// Format: {maks: jumlah request, perDetik: jendela waktu (detik)}.
// Ubah angka di sini saja untuk mengencangkan/melonggarkan batas.
const BATAS = {
  // Endpoint callable `mintaPenawaran`: tiap HP (IP) 20x/menit,
  // tiap akun login 5x/menit.
  penawaranPerIP: {maks: 20, perDetik: 60},
  penawaranPerUser: {maks: 5, perDetik: 60},
  // Trigger notifikasi: maks 1x/menit per kode booking (mencegah
  // status yang di-flap berulang membanjiri HP user + tagihan FCM).
  notifPerBooking: {maks: 1, perDetik: 60},
};

// ─── Helper rate limit (fixed window, transaksional) ────────────────────
// Kunci bebas, mis. `namaFn:ip:1.2.3.4` atau `namaFn:user:UID`.
// Memakai transaksi Firestore sehingga aman walau banyak instance
// Functions berjalan paralel (variabel in-memory TIDAK aman).
// Mengembalikan {lolos: bool, sisa: sisa kuota di jendela ini}.
async function cekBatas(kunci, {maks, perDetik}) {
  const ref = db.collection('rateLimits').doc(kunci);
  const sekarang = Date.now();
  return db.runTransaction(async (t) => {
    const snap = await t.get(ref);
    const data = snap.exists ? snap.data() : null;
    const kedaluwarsa = admin.firestore.Timestamp.fromMillis(
        sekarang + perDetik * 1000 + 3600 * 1000, // jendela + grace 1 jam (TTL)
    );
    // Jendela baru (belum ada / sudah lewat) → reset hitungan.
    if (!data || sekarang - data.awalJendela >= perDetik * 1000) {
      t.set(ref, {jumlah: 1, awalJendela: sekarang, kedaluwarsa});
      return {lolos: true, sisa: maks - 1};
    }
    // Kuota habis → tolak.
    if (data.jumlah >= maks) return {lolos: false, sisa: 0};
    // Masih ada kuota → tambah hitungan.
    t.update(ref, {jumlah: data.jumlah + 1});
    return {lolos: true, sisa: maks - data.jumlah - 1};
  });
}

// ─── CONTOH endpoint callable ber-rate-limit ────────────────────────────
// Dipanggil dari aplikasi via FirebaseFunctions.instance.httpsCallable().
// Terproteksi 3 lapis: App Check (tolak script luar) + batas per IP +
// batas per user login. Untuk memproteksi endpoint lain, cukup salin
// pola cekBatas() di bawah dengan kunci berbeda.
exports.mintaPenawaran = onCall({enforceAppCheck: true}, async (req) => {
  // Lapis 1: batas per IP (menangkap spam dari HP tanpa login).
  // Best-effort: IP bisa dipalsukan/di-NAT, jadi selalu pasang juga
  // batas per user / App Check sebagai lapis utama.
  const ip = (req.rawRequest && req.rawRequest.ip) || 'tak-dikenal';
  const cekIP = await cekBatas(`mintaPenawaran:ip:${ip}`,
      BATAS.penawaranPerIP);
  if (!cekIP.lolos) {
    throw new HttpsError('resource-exhausted',
        'Terlalu banyak permintaan. Coba lagi semenit lagi.');
  }

  // Lapis 2: batas per user (hanya jika sudah login).
  const uid = req.auth ? req.auth.uid : null;
  if (uid) {
    const cekUser = await cekBatas(`mintaPenawaran:user:${uid}`,
        BATAS.penawaranPerUser);
    if (!cekUser.lolos) {
      throw new HttpsError('resource-exhausted',
          'Terlalu banyak permintaan dari akun ini. Coba lagi nanti.');
    }
  }

  // Lolos semua lapis → jalankan logika normal (contoh: simpan pesan).
  const {nama, pesan} = req.data || {};
  if (!nama || !pesan) {
    throw new HttpsError('invalid-argument', 'Nama & pesan wajib diisi.');
  }
  await db.collection('penawaran').add({
    nama: String(nama).slice(0, 100),
    pesan: String(pesan).slice(0, 2000),
    uid: uid,
    dibuatPada: admin.firestore.FieldValue.serverTimestamp(),
  });
  return {ok: true, sisaKuota: uid ? undefined : cekIP.sisa};
});

// ─── Trigger: notifikasi saat status pesanan berubah ────────────────────
// Terpicu setiap dokumen bookings/{kode} berubah.
exports.notifStatusPesanan = onDocumentUpdated('bookings/{kode}',
    async (event) => {
      const before = event.data.before.data();
      const after = event.data.after.data();

      // Hanya bereaksi jika status berubah (abaikan edit lain).
      if (before.status === after.status) return;
      // Data tak lengkap → abaikan (jangan sampai crash).
      if (!after.userId) return;

      // Anti-spam trigger: abaikan jika booking ini baru saja
      // dinotifikasi (< 60 detik). Status tetap tersimpan di Firestore
      // sebagai sumber kebenaran; user melihat versi terbaru saat buka app.
      const cek = await cekBatas(`notif:${event.params.kode}`,
          BATAS.notifPerBooking);
      if (!cek.lolos) {
        console.log(`notif ${event.params.kode} dilewati (rate limit)`);
        return;
      }

      // Ambil token FCM milik user.
      const userRef = db.collection('users').doc(after.userId);
      const userDoc = await userRef.get();
      const tokens = (userDoc.data() && userDoc.data().fcmTokens) || [];
      if (!tokens.length) return;

      // Kirim notifikasi ke semua HP user tersebut.
      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: `Pesanan ${event.params.kode}: ${after.status}`,
          body: `${after.asal} → ${after.tujuan}, ` +
            `${after.tanggal} jam ${after.jam}`,
        },
        // Data utk deep-link + prioritas tinggi
        // (bangun Doze hanya saat ada event).
        data: {screen: 'orders', kode: event.params.kode},
        android: {priority: 'high'},
      });

      // Bersihkan token basi/invalid agar daftar tidak menumpuk selamanya.
      const basi = [];
      res.responses.forEach((r, i) => {
        if (!r.success && r.error &&
        (r.error.code === 'messaging/registration-token-not-registered' ||
         r.error.code === 'messaging/invalid-registration-token')) {
          basi.push(tokens[i]);
        }
      });
      if (basi.length) {
        await userRef.update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...basi),
        });
      }
    });
