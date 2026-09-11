import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';

/// Inisialisasi Firebase saat aplikasi dimulai.
/// Aman gagal: jika belum dikonfigurasi, aplikasi jalan MODE OFFLINE
/// (pesanan lokal + WA) dan [ready] bernilai false.
class FirebaseBootstrap {
  static bool ready = false;

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
      ready = true;
      debugPrint('Firebase: terhubung (mode cloud)');
    } catch (e) {
      ready = false;
      debugPrint('Firebase: mode offline ($e)');
    }
  }
}
