// File ini dihasilkan dari android/app/google-services.json
// (tools/gen_firebase_options.py). Jangan edit manual — generate ulang
// jika json diganti (SHA baru / app baru).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Rara Travel belum dikonfigurasi untuk web.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'Rara Travel hanya dikonfigurasi untuk Android.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB3R5px0yYPiZajVIuVGixD6xWOTRV7Ego',
    appId: '1:132948234436:android:9959a4c5fa8a42f4fbf991',
    messagingSenderId: '132948234436',
    projectId: 'raratravel-apk',
    storageBucket: 'raratravel-apk.firebasestorage.app',
  );
}
