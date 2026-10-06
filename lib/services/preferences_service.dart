import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferensi onboarding & kota asal favorit. Tersimpan lokal di HP.
class PreferencesService {
  static const _doneKey = 'rara_onboarding_done_v1';
  static const _kotaKey = 'rara_kota_asal_v1';

  /// Sudah pernah melewati layar selamat datang?
  static Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_doneKey) ?? false;
  }

  /// Tandai onboarding selesai (+ simpan kota asal bila dipilih).
  static Future<void> setOnboardingDone({String? kotaAsal}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
    if (kotaAsal != null) await prefs.setString(_kotaKey, kotaAsal);
  }

  /// Kota asal favorit (null bila pengguna memilih "Lewati").
  static Future<String?> getKotaAsal() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kotaKey);
  }

  // --- Preferensi dasar (mata uang & bahasa) yang benar-benar DIPAKAI -------
  //
  // Pilihan disimpan di HP, dimuat sekali saat start ke [mataUang]/[bahasa]
  // sehingga widget lain bisa mendengarkan perubahan tanpa FutureBuilder:
  //   * mata uang → format harga (Formatters.idr)
  //   * bahasa    → locale MaterialApp (nama hari/bulan + dialog tanggal)
  //
  // Daftar pilihan sengaja hanya berisi yang benar-benar didukung. Saat
  // multi-bahasa ditambahkan: tambahkan 'en' di daftarBahasa + berkas
  // terjemahan, lalu pakai [bahasa] di widget.

  static const String defaultMataUang = 'IDR';
  static const String defaultBahasa = 'id';

  /// Pilihan yang tersedia (layar preferensi & Profil).
  static const List<String> daftarMataUang = ['IDR'];
  static const List<String> daftarBahasa = ['id'];

  /// Nilai terkini untuk UI (listener) — diisi [muatPreferensi] saat start.
  static final ValueNotifier<String> mataUang = ValueNotifier(defaultMataUang);
  static final ValueNotifier<String> bahasa = ValueNotifier(defaultBahasa);

  static const _mataUangKey = 'rara_mata_uang_v1';
  static const _bahasaKey = 'rara_bahasa_v1';

  /// Simpan pilihan dari layar preferensi.
  static Future<void> setPreferensiDasar({
    required String mataUang,
    required String bahasa,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mataUangKey, mataUang);
    await prefs.setString(_bahasaKey, bahasa);
  }

  /// Muat preferensi tersimpan ke notifier (panggil sekali di awal aplikasi).
  /// Aman gagal: nilai bawaan tetap dipakai bila terjadi masalah.
  static Future<void> muatPreferensi() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      mataUang.value = prefs.getString(_mataUangKey) ?? defaultMataUang;
      bahasa.value = prefs.getString(_bahasaKey) ?? defaultBahasa;
    } catch (_) {}
  }

  /// Baca preferensi tersimpan sekaligus (layar preferensi & Profil).
  static Future<({String mataUang, String bahasa})> getPreferensi() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      mataUang: prefs.getString(_mataUangKey) ?? defaultMataUang,
      bahasa: prefs.getString(_bahasaKey) ?? defaultBahasa,
    );
  }

  /// Ubah mata uang saja (dipakai Profil) — langsung diterapkan ke UI.
  static Future<void> setMataUang(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mataUangKey, kode);
    mataUang.value = kode;
  }

  /// Ubah bahasa saja (dipakai Profil) — langsung diterapkan ke UI.
  static Future<void> setBahasa(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bahasaKey, kode);
    bahasa.value = kode;
  }

  // --- Primer notifikasi ---
  static const _notifDoneKey = 'rara_notif_primer_done_v1';
  static const _notifSnoozeKey = 'rara_notif_primer_snooze_v1';

  /// Perlu tampilkan layar primer notifikasi?
  /// Tidak, bila sudah disetujui — atau "Nanti Saja" < 3 hari lalu.
  static Future<bool> shouldShowNotifPrimer() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_notifDoneKey) ?? false) return false;
    final snooze = prefs.getString(_notifSnoozeKey);
    if (snooze != null) {
      final at = DateTime.tryParse(snooze);
      if (at != null && DateTime.now().difference(at).inDays < 3) {
        return false;
      }
    }
    return true;
  }

  /// Pengguna menyetujui → jangan tampilkan lagi.
  static Future<void> setNotifPrimerDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifDoneKey, true);
  }

  /// Pengguna menunda → tanya lagi 3 hari kemudian.
  static Future<void> snoozeNotifPrimer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_notifSnoozeKey, DateTime.now().toIso8601String());
  }
}
