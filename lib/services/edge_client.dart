import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import '../config/supabase_config.dart';
import 'firebase_bootstrap.dart';
import 'supabase_bootstrap.dart';

/// Error dari Edge Function/Supabase dengan pesan siap tampil ke pengguna.
class ApiException implements Exception {
  final String code;
  final String message;
  final int status;
  final Map<String, dynamic> details;

  const ApiException({
    required this.code,
    required this.message,
    this.status = 0,
    this.details = const {},
  });

  /// Harga berubah sejak form dibuka (server menolak total lama).
  bool get isPriceMismatch => code == 'price_mismatch';

  /// Kursi sudah habis / tidak cukup.
  bool get isSeatsUnavailable => code == 'seats_unavailable';

  /// Sesi login tidak sah/kedaluwarsa.
  bool get isUnauthorized => code == 'unauthorized' || status == 401;

  /// Kode promo tidak berlaku.
  bool get isPromoInvalid => code == 'promo_invalid';

  int get expectedTotal =>
      (details['expected_total'] as num?)?.toInt() ?? 0;

  int get remainingSeats => (details['available'] as num?)?.toInt() ?? 0;

  @override
  String toString() => 'ApiException($code): $message';
}

/// Pemanggil Edge Function Supabase dengan otentikasi Firebase.
///
/// Aplikasi tidak memakai Supabase Auth (login tetap Firebase), jadi setiap
/// panggilan menyertakan Firebase ID token pada header Authorization. Token
/// di-cache dan diperbarui otomatis sebelum kedaluwarsa.
class EdgeClient {
  static const _functionsPath = '/functions/v1';

  static String? _cachedToken;
  static DateTime? _cachedTokenExpiry;
  static String? _cachedTokenUid;

  /// Supabase siap dipakai?
  static bool get ready => SupabaseBootstrap.ready || SupabaseConfig.isConfigured;

  static Uri _endpoint(String functionName, [String? path]) {
    final base = SupabaseConfig.url.endsWith('/')
        ? SupabaseConfig.url.substring(0, SupabaseConfig.url.length - 1)
        : SupabaseConfig.url;
    final suffix = path == null || path.isEmpty ? '' : path;
    return Uri.parse('$base$_functionsPath/$functionName$suffix');
  }

  /// Firebase ID token terbaru (otomatis refresh saat hampir kedaluwarsa).
  static Future<String?> _idToken() async {
    if (!FirebaseBootstrap.ready) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final masihBerlaku = _cachedToken != null &&
        _cachedTokenUid == user.uid &&
        _cachedTokenExpiry != null &&
        _cachedTokenExpiry!.isAfter(DateTime.now().add(const Duration(minutes: 2)));
    if (masihBerlaku) return _cachedToken;

    try {
      final token = await user.getIdToken();
      _cachedToken = token;
      _cachedTokenUid = user.uid;
      _cachedTokenExpiry = DateTime.now().add(const Duration(minutes: 55));
      return token;
    } catch (e) {
      debugPrint('EdgeClient: gagal mengambil token ($e)');
      return _cachedToken;
    }
  }

  /// Kosongkan cache token (dipanggil saat logout / ganti akun).
  static void resetToken() {
    _cachedToken = null;
    _cachedTokenExpiry = null;
    _cachedTokenUid = null;
  }

  /// Panggil Edge Function dan kembalikan body JSON.
  ///
  /// [auth] true = wajib login (token Firebase dikirim). Endpoint publik
  /// (katalog) tetap mengirim token bila kebetulan sudah login.
  static Future<Map<String, dynamic>> invoke(
    String functionName, {
    String? action,
    Map<String, dynamic>? body,
    bool auth = false,
    String? path,
    Duration? timeout,
  }) async {
    if (!ready) {
      throw const ApiException(
        code: 'not_configured',
        message: 'Supabase belum dikonfigurasi pada build aplikasi ini.',
      );
    }

    final payload = <String, dynamic>{
      if (action != null) 'action': action,
      ...?body,
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'apikey': SupabaseConfig.anonKey,
    };

    final token = await _idToken();
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    } else if (auth) {
      throw const ApiException(
        code: 'unauthorized',
        message: 'Silakan login terlebih dahulu.',
        status: 401,
      );
    }

    final client = http.Client();
    try {
      final response = await client
          .post(_endpoint(functionName, path), headers: headers, body: jsonEncode(payload))
          .timeout(timeout ?? const Duration(seconds: BackendConfig.callTimeoutSeconds));

      return _decode(response);
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'Server tidak merespons. Periksa koneksi lalu coba lagi.',
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        code: 'network_error',
        message: 'Tidak bisa menghubungi server. Periksa koneksi internet.',
        details: {'error': e.toString()},
      );
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> data = const {};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        } else {
          data = {'data': decoded};
        }
      } catch (_) {
        data = {'raw': response.body};
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }

    final error = data['error'];
    if (error is Map<String, dynamic>) {
      throw ApiException(
        code: (error['code'] ?? 'server_error').toString(),
        message: (error['message'] ?? 'Terjadi kesalahan di server').toString(),
        status: response.statusCode,
        details: error['details'] is Map
            ? Map<String, dynamic>.from(error['details'] as Map)
            : const {},
      );
    }

    throw ApiException(
      code: 'server_error',
      message: 'Terjadi kesalahan di server (${response.statusCode}).',
      status: response.statusCode,
    );
  }
}
