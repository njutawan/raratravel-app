import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/backend_config.dart';
import '../models/app_user.dart';
import '../models/booking.dart';
import '../repositories/booking_repository.dart';
import '../utils/formatters.dart';
import 'booking_storage.dart';
import 'edge_client.dart';
import 'firebase_bootstrap.dart';
import 'firestore_service.dart';
import 'messaging_service.dart';

/// Login/daftar via OTP SMS (Firebase Phone Auth).
class AuthService {
  static FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Stream status login (null = tamu). Aman dipanggil walau offline.
  static Stream<User?> authStateChanges() =>
      FirebaseBootstrap.ready ? _auth.authStateChanges() : Stream.value(null);

  /// User saat ini (null bila tamu / mode offline).
  static User? get currentUser =>
      FirebaseBootstrap.ready ? _auth.currentUser : null;

  /// User saat ini, menunggu sesi pulih dulu (maks 3 detik).
  /// Dipakai splash agar user lama tak disangka tamu.
  static Future<User?> currentUserAsync() async {
    if (!FirebaseBootstrap.ready) return null;
    try {
      return await _auth.authStateChanges().first.timeout(
        const Duration(seconds: 3),
      );
    } on TimeoutException {
      return _auth.currentUser;
    } catch (_) {
      return _auth.currentUser;
    }
  }

  /// Normalisasi: 0812... / 62812... / +62812... → +62812...
  static String normalizePhone(String input) {
    var p = input.replaceAll(RegExp(r'[\s\-.()]'), '');
    if (p.startsWith('+')) return p;
    if (p.startsWith('62')) return '+$p';
    if (p.startsWith('0')) return '+62${p.substring(1)}';
    return '+62$p';
  }

  /// Kirim kode OTP ke [phone] (format +62...).
  static Future<void> sendOtp({
    required String phone,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(UserCredential credential) onAutoVerified,
    required void Function(String message) onError,
    int? forceResendingToken,
  }) async {
    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        forceResendingToken: forceResendingToken,
        verificationCompleted: (cred) async {
          // Verifikasi otomatis (umum di Android) → langsung masuk.
          try {
            onAutoVerified(await _auth.signInWithCredential(cred));
          } catch (e) {
            onError(friendlyError(e));
          }
        },
        verificationFailed: (e) {
          // Log lengkap untuk diagnosis (logcat): kode saja tak cukup,
          // detail server ada di message (mis. INVALID_APP_CREDENTIAL).
          debugPrint('OTP verificationFailed: [${e.code}] ${e.message}');
          onError(friendlyError(e));
        },
        codeSent: (vid, token) => onCodeSent(vid, token),
        codeAutoRetrievalTimeout: (_) {},
      );
    } catch (e) {
      debugPrint('OTP sendOtp error: $e');
      onError(friendlyError(e));
    }
  }

  /// Tukar kode OTP 6 digit menjadi sesi login.
  static Future<UserCredential> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) => _auth.signInWithCredential(
    PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode.trim(),
    ),
  );

  static Future<void> signOut() async {
    EdgeClient.resetToken(); // token lama tidak boleh dipakai akun berikutnya
    // Bersihkan juga sesi Google (penting di HP yang dipakai bersama).
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  /// Hapus akun permanen: seluruh data cloud + sesi login + riwayat lokal.
  /// Lempar [FirebaseAuthException] `requires-recent-login` bila sesi sudah
  /// tua — panggil lagi setelah pengguna login ulang.
  static Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (FirebaseBootstrap.ready && BackendConfig.writeFirestore) {
      try {
        await FirestoreService.deleteAllUserData(user.uid);
      } catch (_) {}
    }
    if (EdgeClient.ready) {
      try {
        await EdgeClient.invoke(
          'auth-user-sync',
          body: {'action': 'unregister-device'},
          auth: true,
        );
      } catch (_) {}
    }
    await user.delete();
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await BookingStorage.clear();
    EdgeClient.resetToken();
  }

  /// Login dengan akun Google. Kembalikan credential,
  /// atau null bila pengguna membatalkan.
  static Future<UserCredential?> signInWithGoogle() async {
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) return null; // dibatalkan pengguna
    final googleAuth = await googleUser.authentication;
    if (googleAuth.idToken == null && googleAuth.accessToken == null) {
      // Seharusnya tak terjadi bila google-services.json benar; tanpa token
      // Firebase pasti menolak, jadi gagalkan lebih awal dengan pesan jelas.
      throw StateError('Token Google kosong (konfigurasi client).');
    }
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      ),
    );
  }

  /// True bila error login Google berarti "pengguna membatalkan"
  /// (tombol back di pemilih akun) — jangan hitung sebagai kegagalan.
  static bool isGoogleCancel(Object e) {
    if (e is PlatformException && e.code == 'sign_in_canceled') return true;
    final t = e.toString();
    // ApiException 12501 = SIGN_IN_CANCELLED.
    return t.contains('12501') || t.contains('sign_in_canceled');
  }

  /// Terjemahkan error login Google menjadi bahasa manusia.
  /// Plugin google_sign_in melempar PlatformException (bukan
  /// FirebaseAuthException), jadi dipetakan terpisah dari [friendlyError].
  static String friendlyGoogleError(Object e) {
    debugPrint('Google sign-in error: $e');
    if (e is FirebaseAuthException) return friendlyError(e);
    final text = e.toString();
    if (e is PlatformException) {
      if (e.code == 'network_error' ||
          text.contains('ApiException: 7') ||
          text.contains('NETWORK_ERROR')) {
        return 'Tidak ada koneksi internet.';
      }
      // ApiException 10 = DEVELOPER_ERROR (SHA-1 belum terdaftar);
      // 12500 = SIGN_IN_FAILED (konfigurasi OAuth salah).
      if (text.contains('ApiException: 10') ||
          text.contains('DEVELOPER_ERROR') ||
          text.contains('12500') ||
          text.contains('SIGN_IN_FAILED')) {
        return 'Login Google gagal: SHA-1 APK belum terdaftar di Firebase. Hubungi admin.';
      }
      if (text.contains('ApiException: 8') ||
          text.contains('INTERNAL_ERROR')) {
        return 'Layanan Google Play bermasalah. Update Google Play Services lalu coba lagi.';
      }
      if (e.code == 'sign_in_failed') return 'Login Google gagal. Coba lagi.';
      return 'Login Google gagal (${e.code}). Coba lagi.';
    }
    if (text.contains('Token Google kosong')) {
      return 'Konfigurasi login Google belum lengkap. Hubungi admin.';
    }
    if (text.toLowerCase().contains('network')) {
      return 'Tidak ada koneksi internet.';
    }
    return 'Login Google gagal. Coba lagi.';
  }

  /// Pascaproses login: profil + migrasi riwayat lokal + FCM.
  /// Aman gagal sebagian (try/catch di dalam).
  ///
  /// Sejak migrasi Supabase, fungsi ini juga:
  ///   * membuat/memperbarui baris `public.users` (Firebase UID → UUID internal),
  ///   * mengirim ulang pesanan lokal yang belum tersinkron,
  ///   * menyimpan token FCM ke `public.user_devices`.
  static Future<void> completeSignIn(User user) async {
    // Supabase: satu panggilan untuk profil + perangkat (langkah 4 & 8).
    await _sinkronSupabase();

    if (!BackendConfig.writeFirestore && !BackendConfig.firestoreIsSourceOfTruth) {
      // Firestore sudah tidak dipakai; cukup sinkronkan ke server baru.
      await _sinkronPesananSupabase();
      return;
    }

    try {
      final existing = await FirestoreService.getUser(user.uid);
      await FirestoreService.saveUser(
        existing ??
            AppUser(
              uid: user.uid,
              phone: user.phoneNumber ?? '',
              name: user.displayName ?? '',
              email: user.email ?? '',
            ),
      );
      // Sinkron pesanan + FCM jalan PARALEL (login terasa lebih cepat).
      await Future.wait([
        _sinkronPesanan(user.uid),
        MessagingService.registerToken(user.uid),
      ]);
    } catch (_) {}
  }

  /// Daftarkan profil ke Supabase (idempoten; aman dipanggil berkali-kali).
  static Future<void> _sinkronSupabase() async {
    if (!BackendConfig.useSupabaseBooking && !BackendConfig.useSupabaseCatalog) {
      return;
    }
    try {
      await MessagingService.sinkronSupabase();
    } catch (_) {}
  }

  /// Kirim pesanan lokal yang belum ada di server baru.
  ///
  /// Pesanan yang sudah pernah tersinkron ditandai di riwayat HP
  /// (`rara_migrated_v1`), jadi proses ini hanya mengirim yang baru/tertinggal.
  static Future<void> _sinkronPesananSupabase() async {
    try {
      final sudah = await BookingStorage.migratedCodes();
      final lokal = await BookingStorage.loadAll();
      final hariIni = _hariIni();
      for (final booking in lokal) {
        if (sudah.contains(booking.kode)) continue;
        // Tanggal lampau ditolak server (memang dirancang begitu) — cukup
        // tinggal di riwayat HP. Tandai "sudah" agar tidak dicoba ulang
        // tanpa henti tiap login.
        final tanggal = Formatters.tryParseDate(booking.tanggal);
        if (tanggal != null && tanggal.isBefore(hariIni)) {
          await BookingStorage.markMigrated(booking.kode);
          continue;
        }
        try {
          await BookingRepository.create(
            draft: booking,
            idempotencyKey: 'migrasi-${booking.kode}',
          );
        } catch (_) {
          await BookingStorage.markDirty(booking.kode);
        }
      }
    } catch (_) {}
  }

  /// Tengah malam hari ini (untuk membandingkan tanggal keberangkatan).
  static DateTime _hariIni() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Sinkron pesanan lokal → cloud: migrasi yang baru + outbox offline.
  /// Tiap dokumen ditulis paralel (bukan satu-satu) agar cepat.
  static Future<void> _sinkronPesanan(String uid) async {
    try {
      final migrated = await BookingStorage.migratedCodes();
      final lokal = await BookingStorage.loadAll();
      await Future.wait([
        for (final b in lokal)
          if (!migrated.contains(b.kode)) _migrasiSatu(b, uid),
        for (final kode in await BookingStorage.dirtyCodes())
          _outboxSatu(kode, uid),
      ]);
    } catch (_) {}
  }

  static Future<void> _migrasiSatu(Booking b, String uid) async {
    try {
      await FirestoreService.saveBooking(b, uid);
      await BookingStorage.markMigrated(b.kode);
    } catch (_) {}
  }

  static Future<void> _outboxSatu(String kode, String uid) async {
    try {
      final lokal = await BookingStorage.findByKode(kode);
      if (lokal == null) {
        await FirestoreService.deleteBooking(kode);
      } else {
        await FirestoreService.saveBooking(lokal, uid);
      }
      await BookingStorage.unmarkDirty(kode);
    } catch (_) {}
  }

  /// Terjemahkan error teknis menjadi bahasa manusia.
  static String friendlyError(Object e) {
    if (e is FirebaseAuthException) {
      debugPrint('Auth error: [${e.code}] ${e.message}');
      switch (e.code) {
        case 'invalid-phone-number':
          return 'Nomor HP tidak valid. Cek lagi ya.';
        case 'too-many-requests':
          return 'Terlalu sering. Tunggu beberapa menit lalu coba lagi.';
        case 'invalid-verification-code':
          return 'Kode OTP salah. Cek SMS lalu coba lagi.';
        case 'session-expired':
          return 'Kode kedaluwarsa. Minta kode baru.';
        case 'app-not-authorized':
        case 'invalid-app-credential':
          return 'Verifikasi aplikasi gagal: SHA-1 APK belum terdaftar di Firebase. Hubungi admin.';
        case 'operation-not-allowed':
          return 'Login nomor HP belum diaktifkan di server. Hubungi admin.';
        case 'captcha-check-failed':
          return 'Verifikasi keamanan gagal. Update Google Play Services lalu coba lagi.';
        case 'quota-exceeded':
          return 'Kuota SMS hari ini habis. Coba lagi besok.';
        case 'network-request-failed':
          return 'Tidak ada koneksi internet.';
        case 'unknown':
          // 'unknown' menyembunyikan sebab asli di message server —
          // petakan kata kuncinya agar pengguna/admin tahu tindakan berikutnya.
          final m = (e.message ?? '').toUpperCase();
          if (m.contains('INVALID_APP_CREDENTIAL')) {
            return 'Verifikasi aplikasi gagal: SHA-1 APK belum terdaftar di Firebase. Hubungi admin.';
          }
          if (m.contains('QUOTA_EXCEEDED')) {
            return 'Kuota SMS hari ini habis. Coba lagi besok.';
          }
          if (m.contains('BILLING_NOT_ENABLED')) {
            return 'SMS butuh paket Blaze di Firebase. Hubungi admin.';
          }
          return 'Gagal mengirim OTP. Cek koneksi, lalu coba lagi.';
        default:
          return 'Gagal (${e.code}). Coba lagi.';
      }
    }
    return 'Terjadi kesalahan. Coba lagi.';
  }
}
