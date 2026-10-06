import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/booking.dart';
import '../models/booking_status.dart';
import '../repositories/payment_repository.dart';
import '../services/edge_client.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';

/// Lembar pembayaran pesanan.
///
/// Tiga hal yang bisa dilakukan pengguna:
///   * melihat tagihan (total, sudah dibayar, sisa) dan riwayatnya,
///   * bayar online lewat tautan provider (QRIS/VA/e-wallet) — Midtrans,
///   * transfer manual lalu mengirim bukti ke admin via WhatsApp.
///
/// Hanya muncul bila build memakai Supabase + `PAYMENTS_ENABLED=true`
/// ([PaymentRepository.enabled]) dan pesanannya sudah ada di server
/// ([Booking.id] terisi).
class PaymentSheet extends StatefulWidget {
  final Booking booking;

  const PaymentSheet({super.key, required this.booking});

  /// Buka sebagai bottom sheet.
  static Future<void> show(BuildContext context, Booking booking) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: Adaptive.isWide(context)
          ? const BoxConstraints(maxWidth: 640)
          : null,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => PaymentSheet(booking: booking),
    );
  }

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  bool _memuat = true;
  bool _proses = false;
  String? _galat;
  Map<String, dynamic> _status = const {};
  String _metode = 'online';
  PaymentIntent? _tagihanManual;
  final ImagePicker _picker = ImagePicker();

  /// Path bukti transfer yang sudah terunggah ke Storage (dikirim ke admin).
  String? _pathBukti;
  bool _unggah = false;

  Booking get _booking => widget.booking;

  int get _total => (_status['total'] as num?)?.toInt() ?? _booking.totalHarga;
  int get _dibayar => (_status['paid_total'] as num?)?.toInt() ?? 0;
  int get _sisa {
    final sisa = (_status['remaining_amount'] as num?)?.toInt();
    if (sisa != null) return sisa < 0 ? 0 : sisa;
    final hitung = _total - _dibayar;
    return hitung < 0 ? 0 : hitung;
  }
  String get _statusBayar =>
      (_status['payment_status'] ?? _booking.paymentStatus).toString();
  bool get _lunas => _sisa <= 0 || PaymentStatus.isPaid(_statusBayar);

  List<Map<String, dynamic>> get _tagihan =>
      ((_status['payments'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  void initState() {
    super.initState();
    _muatStatus();
  }

  Future<void> _muatStatus() async {
    if (!PaymentRepository.enabled) {
      setState(() {
        _memuat = false;
        _galat = 'Pembayaran online belum diaktifkan pada build ini.';
      });
      return;
    }
    setState(() {
      _memuat = true;
      _galat = null;
    });
    try {
      final hasil = await PaymentRepository.status(_booking.kode);
      if (!mounted) return;
      setState(() {
        _status = hasil;
        _memuat = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = e.message.isEmpty ? 'Gagal memuat tagihan.' : e.message;
        _memuat = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _galat = 'Gagal memuat tagihan. Periksa koneksi lalu coba lagi.';
        _memuat = false;
      });
    }
  }

  void _pesan(String teks) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(teks)));
  }

  /// Bayar online: buat tagihan provider lalu buka halaman pembayarannya.
  Future<void> _bayarOnline() async {
    setState(() {
      _proses = true;
      _galat = null;
    });
    try {
      final tagihan = await PaymentRepository.create(
        kode: _booking.kode,
        provider: 'midtrans',
      );
      if (!mounted) return;
      if (tagihan.sudahLunas) {
        _pesan('Tagihan ini sudah lunas.');
        await _muatStatus();
        return;
      }
      if (tagihan.adaTautanBayar) {
        final dibuka = await PaymentRepository.bukaTautanBayar(
          tagihan.checkoutUrl!,
        );
        _pesan(
          dibuka
              ? 'Selesaikan pembayaran di browser, lalu kembali ke aplikasi.'
              : 'Tautan pembayaran tidak bisa dibuka. Hubungi admin ya.',
        );
      } else {
        _pesan(
          'Tautan pembayaran belum tersedia. Pakai transfer manual atau hubungi admin.',
        );
      }
      await _muatStatus();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = e.message.isEmpty ? 'Gagal membuat tagihan.' : e.message;
      });
    } catch (_) {
      if (mounted) setState(() => _galat = 'Gagal membuat tagihan. Coba lagi.');
    } finally {
      if (mounted) setState(() => _proses = false);
    }
  }

  /// Transfer manual: catat tagihan supaya admin bisa mencocokkan dana masuk.
  Future<void> _buatTagihanManual() async {
    setState(() {
      _proses = true;
      _galat = null;
    });
    try {
      final tagihan = await PaymentRepository.create(
        kode: _booking.kode,
        provider: 'manual',
      );
      if (!mounted) return;
      setState(() => _tagihanManual = tagihan);
      await _muatStatus();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = e.message.isEmpty ? 'Gagal mencatat transfer.' : e.message;
      });
    } catch (_) {
      if (mounted) setState(() => _galat = 'Gagal mencatat transfer. Coba lagi.');
    } finally {
      if (mounted) setState(() => _proses = false);
    }
  }

  /// Pilih foto bukti transfer (galeri/kamera) lalu unggah ke Storage.
  ///
  /// Berkas masuk bucket privat `payment-proofs` dan hanya bisa dibuka admin,
  /// jadi bukti transfer tidak pernah nongkrong di ruang publik.
  Future<void> _pilihUnggahBukti() async {
    final sumber = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pilih dari Galeri'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Ambil Foto'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (sumber == null) return;

    setState(() {
      _unggah = true;
      _galat = null;
    });
    try {
      final berkas = await _picker.pickImage(
        source: sumber,
        // Kompres di HP: bukti transfer cukup jelas di 1600px, hemat kuota.
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (berkas == null) return; // pengguna membatalkan
      final Uint8List bytes = await berkas.readAsBytes();
      if (bytes.isEmpty) {
        setState(() => _galat = 'Berkas kosong. Coba pilih ulang.');
        return;
      }
      final path = await PaymentRepository.unggahBuktiTransfer(
        kode: _booking.kode,
        bytes: bytes,
        filename: berkas.name,
        contentType: berkas.mimeType,
      );
      if (!mounted) return;
      setState(() => _pathBukti = path);
      _pesan('Bukti transfer terunggah. Kirim ke admin lewat WhatsApp.');
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _galat = e.message.isEmpty ? 'Gagal mengunggah bukti.' : e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _galat = 'Gagal mengunggah bukti transfer. Coba lagi.');
      }
    } finally {
      if (mounted) setState(() => _unggah = false);
    }
  }

  void _kirimBukti() {
    final nominal = _tagihanManual?.amount ?? _sisa;
    final referensi = _tagihanManual?.providerReference;
    final b = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya sudah transfer:')
      ..writeln('')
      ..writeln('Kode booking: *${_booking.kode}*')
      ..writeln('Rute: ${_booking.asal} → ${_booking.tujuan}')
      ..writeln('Tanggal: ${_booking.tanggalDisplay} • ${_booking.jam} WIB')
      ..writeln('Nominal: ${Formatters.idr(nominal)}');
    if (referensi != null && referensi.isNotEmpty) {
      b.writeln('Referensi: $referensi');
    }
    if (_pathBukti != null && _pathBukti!.isNotEmpty) {
      b.writeln('Bukti transfer: sudah diunggah ke aplikasi ($_pathBukti).');
    }
    b
      ..writeln('')
      ..writeln('Bukti transfer saya lampirkan di chat ini. Mohon dicek ya.');
    ExternalService.openWhatsApp(b.toString());
  }

  void _hubungiAdmin() {
    ExternalService.openWhatsApp(
      'Halo *Rara Travel & Tour*, saya mau tanya pembayaran pesanan '
      '${_booking.kode} (sisa ${Formatters.idr(_sisa)}).',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Pembayaran',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                StatusBadge(
                  status: _statusBayar.isEmpty
                      ? 'Belum Dibayar'
                      : PaymentStatus.label(_statusBayar),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Pesanan ${_booking.kode} • ${_booking.asal} → ${_booking.tujuan}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const Divider(height: 24),

            if (_memuat)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_galat != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: Colors.orange.shade800,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _galat!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // ----- Ringkasan tagihan -----
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      InfoRow(label: 'Total pesanan', value: Formatters.idr(_total)),
                      InfoRow(
                        label: 'Sudah dibayar',
                        value: Formatters.idr(_dibayar),
                      ),
                      const Divider(height: 18),
                      Row(
                        children: [
                          const Text(
                            'Sisa tagihan',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Text(
                            _lunas ? 'LUNAS' : Formatters.idr(_sisa),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: _lunas ? Colors.green.shade700 : AppTheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              if (_lunas)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified, color: Colors.green.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Pembayaran sudah diterima. Terima kasih!',
                          style: TextStyle(fontSize: 12, color: Colors.green.shade900),
                        ),
                      ),
                    ],
                  ),
                )
              else if (PaymentRepository.enabled) ...[
                // ----- Pilih cara bayar -----
                const Text(
                  'Cara Bayar',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'online',
                      icon: Icon(Icons.qr_code_2, size: 18),
                      label: Text('Online'),
                    ),
                    ButtonSegment(
                      value: 'manual',
                      icon: Icon(Icons.account_balance, size: 18),
                      label: Text('Transfer'),
                    ),
                  ],
                  selected: {_metode},
                  onSelectionChanged: (v) => setState(() {
                    _metode = v.first;
                    _galat = null;
                  }),
                ),
                const SizedBox(height: 12),

                if (_metode == 'online') ...[
                  Text(
                    'Bayar dengan QRIS, Virtual Account, atau e-wallet pada halaman '
                    'pembayaran yang terbuka di browser. Status pesanan diperbarui '
                    'otomatis setelah dana masuk.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _proses ? null : _bayarOnline,
                      icon: _proses
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.payment),
                      label: Text(
                        _proses ? 'Memproses…' : 'Bayar ${Formatters.idr(_sisa)}',
                      ),
                    ),
                  ),
                ] else ...[
                  Text(
                    'Bayar lewat transfer bank/QRIS manual, lalu kirim bukti '
                    'transfer ke admin. Pesanan ditandai lunas setelah dana '
                    'diverifikasi.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  if (_tagihanManual != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Nominal: ${Formatters.idr(_tagihanManual!.amount)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          if ((_tagihanManual!.providerReference ?? '').isNotEmpty)
                            Text(
                              'Referensi: ${_tagihanManual!.providerReference}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            '${_tagihanManual!.instructions?['note'] ?? 'Kirim bukti transfer ke admin via WhatsApp.'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _unggah || _proses ? null : _pilihUnggahBukti,
                      icon: _unggah
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _pathBukti == null
                                  ? Icons.upload_file
                                  : Icons.check_circle,
                              size: 18,
                              color: _pathBukti == null ? null : Colors.green,
                            ),
                      label: Text(
                        _unggah
                            ? 'Mengunggah…'
                            : (_pathBukti == null
                                  ? 'Unggah Bukti Transfer'
                                  : 'Bukti Terunggah — Ganti'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.waGreen,
                      ),
                      onPressed: _proses
                          ? null
                          : (_tagihanManual == null
                                ? _buatTagihanManual
                                : _kirimBukti),
                      icon: Icon(
                        _tagihanManual == null ? Icons.receipt_long : Icons.chat,
                        size: 18,
                      ),
                      label: Text(
                        _tagihanManual == null
                            ? 'Catat Transfer Manual'
                            : 'Kirim Bukti via WhatsApp',
                      ),
                    ),
                  ),
                ],
              ],

              const SizedBox(height: 16),

              // ----- Riwayat tagihan -----
              if (_tagihan.isNotEmpty) ...[
                const Text(
                  'Riwayat Tagihan',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 6),
                ..._tagihan.map(
                  (t) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_providerLabel(t['provider'])} • '
                            '${Formatters.displayShort((t['created_at'] ?? '').toString())}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        Text(
                          Formatters.idr((t['amount'] as num?)?.toInt() ?? 0),
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          PaymentStatus.label((t['status'] ?? '').toString()),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: PaymentStatus.isPaid((t['status'] ?? '').toString())
                                ? Colors.green.shade700
                                : Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _memuat ? null : _muatStatus,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Perbarui Status'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _hubungiAdmin,
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: const Text('Tanya Admin'),
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  static String _providerLabel(Object? provider) {
    switch ((provider ?? '').toString().toLowerCase()) {
      case 'midtrans':
        return 'Online (Midtrans)';
      case 'manual':
        return 'Transfer manual';
      default:
        final teks = (provider ?? '').toString();
        return teks.isEmpty ? 'Tagihan' : teks;
    }
  }
}
