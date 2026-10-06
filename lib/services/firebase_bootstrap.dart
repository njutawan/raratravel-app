import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';

/// Inisialisasi Firebase saat aplikasi dimulai.
/// Aman gagal: jika belum dikonfigurasi, aplikasi jalan MODE OFFLINE
/// (pesanan lokal + WA) dan [ready] bernilai false.
class FirebaseBootstrap {
  static bool ready = false;

  /// Pelaporan crash aktif? Dipakai kartu "Ringkasan Backend" di Profil agar
  /// keadaan ini bisa diperiksa dari HP saat uji rilis.
  static bool crashReporting = false;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      // App Check: tolak trafik dari aplikasi palsu / API key yang bocor.
      // Butuh enforcement di Console agar efektif (lihat LAPORAN_KEAMANAN.md).
      try {
        await FirebaseAppCheck.instance.activate(
          androidProvider: kDebugMode
              ? AndroidProvider.debug
              : AndroidProvider.playIntegrity,
        );
      } catch (e) {
        debugPrint('App Check: nonaktif ($e)');
      }
      // Crashlytics: kumpulkan crash HANYA di build rilis (build debug tetap
      // bersih, jadi tidak ada laporan palsu saat pengembangan).
      try {
        await FirebaseCrashlytics.instance
            .setCrashlyticsCollectionEnabled(!kDebugMode);
        crashReporting = !kDebugMode;
      } catch (e) {
        debugPrint('Crashlytics: nonaktif ($e)');
      }
      ready = true;
      debugPrint('Firebase: terhubung (mode cloud)');
    } catch (e) {
      ready = false;
      debugPrint('Firebase: mode offline ($e)');
    }
  }

  /// Lapor galat fatal ke Crashlytics (aman walau Firebase belum siap —
  /// galatnya hanya dicetak, tidak pernah menggagalkan aplikasi).
  ///
  /// Dipakai dari handler di `main.dart`; sengaja tidak memakai
  /// `flutter/foundation` saja supaya laporan tetap terkirim walau UI crash.
  static Future<void> catatGalatFatal(
    Object error,
    StackTrace? stack, {
    bool fatal = true,
  }) async {
    if (!ready) return;
    try {
      if (fatal) {
        await FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } else {
        await FirebaseCrashlytics.instance.recordError(error, stack);
      }
    } catch (_) {
      // Jangan pernah melempar dari jalur pelaporan galat.
    }
  }
}
