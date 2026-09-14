import 'dart:io';
import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';

import '../config/backend_config.dart';
import '../models/booking_status.dart';
import '../services/edge_client.dart';

/// Tagihan yang siap dibayar.
class PaymentIntent {
  final String? paymentId;
  final String status;
  final int amount;
  final int remainingAmount;
  final String? checkoutUrl;
  final String? providerReference;
  final Map<String, dynamic>? instructions;

  const PaymentIntent({
    required this.paymentId,
    required this.status,
    required this.amount,
    required this.remainingAmount,
    this.checkoutUrl,
    this.providerReference,
    this.instructions,
  });

  bool get adaTautanBayar => checkoutUrl != null && checkoutUrl!.isNotEmpty;

  bool get sudahLunas => PaymentStatus.isPaid(status);

  factory PaymentIntent.fromApi(Map<String, dynamic> json) {
    final payment = json['payment'] is Map
        ? Map<String, dynamic>.from(json['payment'] as Map)
        : const <String, dynamic>{};
    return PaymentIntent(
      paymentId: payment['id']?.toString(),
      status: (payment['status'] ?? 'pending').toString(),
      amount: ((payment['amount'] as num?) ?? 0).toInt(),
      remainingAmount: ((json['remaining_amount'] as num?) ?? 0).toInt(),
      checkoutUrl: (json['checkout_url'] ?? payment['checkout_url'])?.toString(),
      providerReference: payment['provider_reference']?.toString(),
      instructions: json['instructions'] is Map
          ? Map<String, dynamic>.from(json['instructions'] as Map)
          : null,
    );
  }
}

/// Pembayaran lewat Edge Function (langkah 10 migrasi).
///
/// Dua jalur yang didukung aplikasi:
///   * `midtrans` — tautan pembayaran (QRIS/VA/e-wallet) dibuka di browser.
///   * `manual`   — instruksi transfer; admin memverifikasi dana masuk.
class PaymentRepository {
  static bool get enabled => BackendConfig.paymentsEnabled && EdgeClient.ready;

  /// Buat tagihan (boleh sebagian/DP; nominal kosong = sisa tagihan).
  static Future<PaymentIntent> create({
    required String kode,
    String provider = 'midtrans',
    String? method,
    int? amount,
  }) async {
    final hasil = await EdgeClient.invoke(
      'payment-intent',
      body: {
        'action': 'create',
        'kode': kode,
        'provider': provider,
        if (method != null) 'method': method,
        if (amount != null) 'amount': amount,
      },
      auth: true,
    );
    return PaymentIntent.fromApi(hasil);
  }

  /// Status pembayaran + daftar tagihan sebuah pesanan.
  static Future<Map<String, dynamic>> status(String kode) => EdgeClient.invoke(
    'manage-booking',
    body: {'action': 'payment-status', 'kode': kode},
    auth: true,
  );

  /// Staf menandai transfer manual sudah diterima (tercatat idempoten).
  static Future<Map<String, dynamic>> konfirmasiManual({
    required String kode,
    required int amount,
    String? method,
    String? reference,
  }) => EdgeClient.invoke(
    'payment-intent',
    body: {
      'action': 'manual-confirm',
      'kode': kode,
      'amount': amount,
      if (method != null) 'method': method,
      if (reference != null) 'reference': reference,
    },
    auth: true,
  );

  /// Buka halaman pembayaran provider di browser HP.
  static Future<bool> bukaTautanBayar(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// Unggah bukti transfer: minta tautan bertanda tangan, lalu kirim berkas.
  ///
  /// Mengembalikan path berkas di Storage (untuk dicatat admin).
  static Future<String> unggahBuktiTransfer({
    required String kode,
    required Uint8List bytes,
    String filename = 'bukti-transfer.jpg',
    String contentType = 'image/jpeg',
  }) async {
    final tender = await EdgeClient.invoke(
      'storage-sign',
      body: {
        'action': 'upload-url',
        'kind': 'payment_proof',
        'kode': kode,
        'filename': filename,
        'content_type': contentType,
      },
      auth: true,
    );

    final uploadUrl = (tender['upload_url'] ?? '').toString();
    final path = (tender['path'] ?? '').toString();
    if (uploadUrl.isEmpty) {
      throw const ApiException(
        code: 'upload_failed',
        message: 'Tautan unggah tidak diterima dari server.',
      );
    }

    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(uploadUrl));
      request.headers.set('Content-Type', contentType);
      request.add(bytes);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          code: 'upload_failed',
          message: 'Gagal mengunggah bukti transfer (${response.statusCode}).',
          status: response.statusCode,
        );
      }
    } finally {
      client.close(force: true);
    }

    return path;
  }
}
