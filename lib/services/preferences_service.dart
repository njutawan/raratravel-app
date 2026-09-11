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
