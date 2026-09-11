/// Konstanta global: info perusahaan, kontak, dan data statis.
///
/// Semua data kontak diambil dari website resmi raratravel.id.
/// Ubah di sini jika nomor / alamat berubah — otomatis dipakai seluruh aplikasi.
class AppConstants {
  static const String appName = 'Rara Travel & Tour';
  static const String appTagline =
      'Mitra Perjalanan Terbaik, Amanah, dan Tepat Waktu';
  static const String website = 'https://raratravel.id';
  static const String privacyPolicy = 'https://raratravel.id/privacy-policy/';

  // --- Kontak resmi ---
  static const String phoneDisplay = '0812-2509-3894';
  static const String phoneWa = '6281225093894'; // format WA (62...)
  static const String email = 'raratravel131@gmail.com';
  static const String address =
      'Jl. Raya By pass Juanda No.59, Sedati Gede, Kec. Sedati, Sidoarjo, Jawa Timur 61253';
  static const String openHours = '24 Jam Nonstop (Senin – Minggu)';

  // --- Sosial media ---
  static const String facebook = 'https://www.facebook.com/raratranstravel';
  static const String instagram = 'https://www.instagram.com/raratraveltour';
  static const String youtube = 'https://www.youtube.com/@raratraveltour';

  // --- Daftar kota yang dilayani ---
  static const List<String> cities = [
    'Jember',
    'Surabaya',
    'Bandara Juanda',
    'Malang',
    'Batu',
    'Banyuwangi',
    'Silo',
    'Jakarta',
    'Denpasar (Bali)',
    'Sidoarjo',
    'Gresik',
    'Mojokerto',
    'Pasuruan',
    'Probolinggo',
    'Lumajang',
    'Bondowoso',
    'Situbondo',
  ];

  // --- Kode promo: kode -> persen diskon (dibatasi promoMaxDiskon) ---
  static const Map<String, int> promoCodes = {'RARAHEMAT': 10};
  static const int promoMaxDiskon = 50000;

  // --- Metode pembayaran ---
  static const List<String> paymentMethods = [
    'Transfer Bank',
    'QRIS',
    'COD / Bayar di Armada',
  ];

  // --- Fasilitas standar travel reguler ---
  static const List<String> standardFacilities = [
    'Door-to-Door (jemput & antar alamat)',
    'AC + Reclining Seat',
    'Free 1x Bagasi',
    'Asuransi perjalanan',
    'Driver profesional',
  ];
}
