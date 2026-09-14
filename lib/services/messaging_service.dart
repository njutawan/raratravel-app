import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app.dart';
import '../config/backend_config.dart';
import 'edge_client.dart';
import 'firestore_service.dart';

/// Handler pesan saat aplikasi MATI TOTAL (isolate background).
/// Wajib top-level + entry-point agar tidak dibuang tree-shaker/obfuscator.
@pragma('vm:entry-point')
Future<void> _pesanBackground(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Payload `notification` otomatis tampil di tray oleh sistem Android.
  // Payload `data` dibaca saat pengguna mengetuk notifikasi.
}

/// FCM: izin + token + terima/ketuk notifikasi (depan, belakang, mati).
/// Murni push (nol polling, nol timer) → dampak baterai praktis nol.
class MessagingService {
  static const _tokenKey = 'rara_fcm_token_v1';
  static const _appVersion = '1.0.0+1';

  /// Panggil sekali saat start (hanya bila Firebase siap).
  static Future<void> init() async {
    try {
      FirebaseMessaging.onBackgroundMessage(_pesanBackground);
      // Ketuk notifikasi saat app hidup di background.
      FirebaseMessaging.onMessageOpenedApp.listen(_bukaPesanan);
      // Ketuk notifikasi saat app mati total → diproses splash nanti.
      final awal = await FirebaseMessaging.instance.getInitialMessage();
      if (awal != null) _tapTertunda = awal;
      // Pesan masuk saat app dibuka → snackbar ringan (tanpa bunyi sistem).
      FirebaseMessaging.onMessage.listen(_pesanDepan);
      // Token berganti mid-session → simpan ulang (anti notif nyasar).
      FirebaseMessaging.instance.onTokenRefresh.listen(_simpanTokenBaru);
    } catch (e) {
      debugPrint('FCM init gagal: $e');
    }
  }

  static RemoteMessage? _tapTertunda;

  /// Diambil splash: true bila user membuka app via ketuk notifikasi.
  static bool ambilTapTertunda() {
    final ada = _tapTertunda != null;
    _tapTertunda = null;
    return ada;
  }

  /// Ketuk notifikasi → langsung tab Pesananku.
  static void _bukaPesanan(RemoteMessage m) {
    try {
      AppNavigator.key.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainNav(initialIndex: 2)),
        (_) => false,
      );
    } catch (_) {}
  }

  static void _pesanDepan(RemoteMessage m) {
    try {
      final ctx = AppNavigator.key.currentContext;
      if (ctx == null) return;
      final judul = m.notification?.title ?? 'Info pesanan';
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(judul),
          action: SnackBarAction(
            label: 'Lihat',
            onPressed: () => _bukaPesanan(m),
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _simpanTokenBaru(String token) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return; // tamu → didaftar saat login berikutnya
      final prefs = await SharedPreferences.getInstance();
      if (BackendConfig.writeFirestore) {
        await FirestoreService.addFcmToken(uid, token);
      }
      await _daftarkanPerangkatSupabase(token);
      await prefs.setString(_tokenKey, token);
    } catch (_) {}
  }

  /// Simpan token FCM ke `public.user_devices` (langkah 8 migrasi).
  ///
  /// Aman gagal: notifikasi lama (Firestore) tetap jalan sampai langkah
  /// Firestore dimatikan.
  static Future<void> _daftarkanPerangkatSupabase(String token) async {
    if (!EdgeClient.ready) return;
    try {
      await EdgeClient.invoke(
        'register-device',
        body: {
          'action': 'register',
          'fcm_token': token,
          'platform': _platform,
          'app_version': _appVersion,
          'locale': Platform.localeName,
        },
        auth: true,
      );
    } catch (e) {
      debugPrint('Daftar perangkat Supabase gagal: $e');
    }
  }

  static String get _platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Pascalogin: buat/perbarui profil Supabase + daftarkan perangkat.
  ///
  /// Edge Function `auth-user-sync` menyatukan keduanya sehingga login hanya
  /// menambah satu perjalanan ke server.
  static Future<void> sinkronSupabase() async {
    if (!EdgeClient.ready) return;
    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      final hasil = await EdgeClient.invoke(
        'auth-user-sync',
        body: {
          'action': 'sync',
          if (token != null) 'fcm_token': token,
          'platform': _platform,
          'app_version': _appVersion,
          'locale': Platform.localeName,
        },
        auth: true,
      );
      if (token != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_tokenKey, token);
      }
      debugPrint(
        'Supabase: profil tersinkron (${hasil['is_new'] == true ? 'akun baru' : 'akun lama'})',
      );
    } catch (e) {
      debugPrint('Supabase: sinkron profil gagal ($e)');
    }
  }

  static Future<void> registerToken(String uid) async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token == null) return;
      // Token sama seperti sebelumnya → tidak perlu menulis ulang.
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_tokenKey) == token) return;
      if (BackendConfig.writeFirestore) {
        await FirestoreService.addFcmToken(uid, token);
      }
      await _daftarkanPerangkatSupabase(token);
      await prefs.setString(_tokenKey, token);
    } catch (e) {
      debugPrint('FCM register gagal: $e');
    }
  }

  /// Minta izin notifikasi sistem (dipakai layar primer onboarding).
  /// Kembalikan true bila diizinkan. Aman dipanggil kapan pun.
  static Future<bool> requestPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('FCM permission gagal: $e');
      return false;
    }
  }
}
