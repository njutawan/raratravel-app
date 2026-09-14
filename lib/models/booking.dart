import 'dart:convert';

import '../utils/formatters.dart';
import 'booking_status.dart';

/// Model pemesanan kursi travel.
///
/// Sumber data:
///   * Lokal (SharedPreferences) — riwayat offline, format lama tetap dibaca.
///   * Server (Edge Function `create-booking` / `manage-booking`) — memuat
///     UUID, kode status, dan status pembayaran.
///
/// Field `status` sengaja tetap berupa label bahasa Indonesia
/// ("Menunggu Konfirmasi", dst.) agar seluruh tampilan tidak perlu berubah.
/// Gunakan [statusCode] untuk logika program.
class Booking {
  final String kode;
  final String asal;
  final String tujuan;
  // "2026-09-12" untuk booking baru; data lama berisi "12 Sep 2026".
  // Selalu tampilkan via getter [tanggalDisplay], jangan langsung.
  final String tanggal;
  final String jam;
  final String nama;
  final String wa;
  final String jemput;
  final String antar;
  final int kursi;
  final int totalHarga;
  final String metodeBayar;
  final String catatan;
  final String status; // Menunggu Konfirmasi / Dikonfirmasi / Dibatalkan / ...
  final String createdAt; // ISO datetime
  final String userId; // uid Firebase pemilik ('' = pesanan lokal/offline)
  final String promo; // kode promo dipakai ('' = tanpa promo)
  final int diskon; // rupiah dipotong (0 = tanpa promo)

  // ---- Field baru dari server (kosong untuk data lama) ----
  final String id; // UUID pesanan di PostgreSQL
  final String statusCode; // pending/confirmed/completed/cancelled/expired
  final String paymentStatus; // unpaid/pending/partial/paid/failed/expired/refunded

  const Booking({
    required this.kode,
    required this.asal,
    required this.tujuan,
    required this.tanggal,
    required this.jam,
    required this.nama,
    required this.wa,
    required this.jemput,
    required this.antar,
    required this.kursi,
    required this.totalHarga,
    required this.metodeBayar,
    this.catatan = '',
    this.status = 'Menunggu Konfirmasi',
    required this.createdAt,
    this.userId = '',
    this.promo = '',
    this.diskon = 0,
    this.id = '',
    this.statusCode = '',
    this.paymentStatus = '',
  });

  Booking copyWith({
    String? status,
    String? statusCode,
    String? paymentStatus,
    String? userId,
    String? promo,
    int? diskon,
    String? kode,
    int? totalHarga,
    String? id,
  }) => Booking(
    kode: kode ?? this.kode,
    asal: asal,
    tujuan: tujuan,
    tanggal: tanggal,
    jam: jam,
    nama: nama,
    wa: wa,
    jemput: jemput,
    antar: antar,
    kursi: kursi,
    totalHarga: totalHarga ?? this.totalHarga,
    metodeBayar: metodeBayar,
    catatan: catatan,
    status: status ?? this.status,
    createdAt: createdAt,
    userId: userId ?? this.userId,
    promo: promo ?? this.promo,
    diskon: diskon ?? this.diskon,
    id: id ?? this.id,
    statusCode: statusCode ?? this.statusCode,
    paymentStatus: paymentStatus ?? this.paymentStatus,
  );

  Map<String, dynamic> toMap() => {
    'kode': kode,
    'asal': asal,
    'tujuan': tujuan,
    'tanggal': tanggal,
    'jam': jam,
    'nama': nama,
    'wa': wa,
    'jemput': jemput,
    'antar': antar,
    'kursi': kursi,
    'totalHarga': totalHarga,
    'metodeBayar': metodeBayar,
    'catatan': catatan,
    'status': status,
    'createdAt': createdAt,
    'userId': userId,
    'promo': promo,
    'diskon': diskon,
    'id': id,
    'statusCode': statusCode,
    'paymentStatus': paymentStatus,
  };

  /// Parsing toleran: field hilang / tipe meleset → default aman,
  /// bukan layar error. (Data cloud bisa diedit manual dari Console.)
  static String _str(Map<String, dynamic> m, String k) =>
      (m[k] ?? '').toString();
  static int _num(Map<String, dynamic> m, String k) =>
      (m[k] as num?)?.toInt() ?? (int.tryParse('${m[k] ?? ''}') ?? 0);
  static double _dbl(Map<String, dynamic> m, String k) =>
      (m[k] as num?)?.toDouble() ?? (double.tryParse('${m[k] ?? ''}') ?? 0);

  factory Booking.fromMap(Map<String, dynamic> m) {
    final status = _str(m, 'status');
    final createdAt = _str(m, 'createdAt');
    final statusCode = _str(m, 'statusCode');
    return Booking(
      kode: _str(m, 'kode'),
      asal: _str(m, 'asal'),
      tujuan: _str(m, 'tujuan'),
      tanggal: _str(m, 'tanggal'),
      jam: _str(m, 'jam'),
      nama: _str(m, 'nama'),
      wa: _str(m, 'wa'),
      jemput: _str(m, 'jemput'),
      antar: _str(m, 'antar'),
      kursi: _num(m, 'kursi'),
      totalHarga: _num(m, 'totalHarga'),
      metodeBayar: _str(m, 'metodeBayar'),
      catatan: _str(m, 'catatan'),
      status: status.isEmpty ? 'Menunggu Konfirmasi' : status,
      createdAt: createdAt.isEmpty
          ? DateTime.now().toIso8601String()
          : createdAt,
      userId: _str(m, 'userId'),
      promo: _str(m, 'promo'),
      diskon: _num(m, 'diskon'),
      id: _str(m, 'id'),
      statusCode: statusCode.isEmpty ? BookingStatus.code(status) : statusCode,
      paymentStatus: _str(m, 'paymentStatus'),
    );
  }

  /// Bangun dari balasan server (`booking_json` di PostgreSQL).
  factory Booking.fromApi(Map<String, dynamic> json, {String userId = ''}) {
    final statusCode = (json['status'] ?? 'pending').toString();
    return Booking(
      kode: (json['kode'] ?? '').toString(),
      asal: (json['origin'] ?? '').toString(),
      tujuan: (json['destination'] ?? '').toString(),
      tanggal: (json['travel_date'] ?? '').toString(),
      jam: _jamTampilan((json['departure_time'] ?? '').toString()),
      nama: (json['contact_name'] ?? '').toString(),
      wa: _waLokal((json['contact_phone'] ?? '').toString()),
      jemput: (json['pickup_address'] ?? '').toString(),
      antar: (json['dropoff_address'] ?? '').toString(),
      kursi: (json['seats'] as num?)?.toInt() ?? 1,
      totalHarga: _dbl(json, 'total').round(),
      metodeBayar: (json['payment_method'] ?? '').toString(),
      catatan: (json['notes'] ?? '').toString(),
      status: (json['status_label'] ??
              BookingStatus.label(statusCode))
          .toString(),
      createdAt: (json['created_at'] ?? DateTime.now().toIso8601String())
          .toString(),
      userId: userId,
      promo: (json['promo_code'] ?? '').toString(),
      diskon: _dbl(json, 'discount').round(),
      id: (json['id'] ?? '').toString(),
      statusCode: statusCode,
      paymentStatus: (json['payment_status'] ?? '').toString(),
    );
  }

  String toJson() => jsonEncode(toMap());
  factory Booking.fromJson(String s) =>
      Booking.fromMap(jsonDecode(s) as Map<String, dynamic>);

  /// Tanggal siap tampil ("12 Sep 2026") — mendukung data lama & baru.
  String get tanggalDisplay => Formatters.displayShort(tanggal);

  /// Jam siap tampil ("06.00") — server memakai "06:00".
  String get jamDisplay => _jamTampilan(jam);

  /// Status dalam kode server (pending/confirmed/...).
  String get statusKode =>
      statusCode.isEmpty ? BookingStatus.code(status) : statusCode;

  bool get bisaDibatalkan => BookingStatus.isActive(statusKode);

  bool get sudahDibayar => PaymentStatus.isPaid(paymentStatus);

  /// Payload untuk Edge Function `create-booking`.
  /// Harga (client_total) hanya dikirim sebagai pembanding — server tetap
  /// menghitung ulang, dan menolak (409) bila harga sudah berubah.
  Map<String, dynamic> toCreatePayload() => {
    if (kode.isNotEmpty) 'kode': kode,
    'origin': asal,
    'destination': tujuan,
    'travel_date': tanggal,
    'departure_time': jam,
    'seats': kursi,
    'contact_name': nama,
    'contact_phone': wa,
    'pickup_address': jemput,
    'dropoff_address': antar,
    'notes': catatan,
    'payment_method': metodeBayar,
    if (promo.isNotEmpty) 'promo_code': promo,
    'client_total': totalHarga,
  };

  /// "06:00" → "06.00" (gaya tampilan Indonesia), "06.00" tetap apa adanya.
  static String _jamTampilan(String jam) {
    if (jam.isEmpty) return jam;
    final bagian = jam.split(':');
    if (bagian.length < 2) return jam;
    return '${bagian[0].padLeft(2, '0')}.${bagian[1].padLeft(2, '0')}';
  }

  /// "+62812..." → "0812..." agar tampilan tetap seperti yang diketik pengguna.
  static String _waLokal(String wa) {
    if (wa.startsWith('+62')) return '0${wa.substring(3)}';
    return wa;
  }

  /// Pesan WhatsApp siap kirim ke admin untuk konfirmasi booking.
  String toWhatsAppMessage() {
    final b = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya mau konfirmasi booking:')
      ..writeln('')
      ..writeln('Kode: *$kode*')
      ..writeln('Rute: $asal → $tujuan')
      ..writeln('Tanggal: $tanggalDisplay • Jam: $jamDisplay WIB')
      ..writeln('Nama: $nama')
      ..writeln('No. WA: $wa')
      ..writeln('Jemput: $jemput')
      ..writeln('Antar: $antar')
      ..writeln('Kursi: $kursi')
      ..writeln('Pembayaran: $metodeBayar');
    if (promo.isNotEmpty) {
      b
        ..writeln('Promo: $promo')
        ..writeln('Diskon: ${Formatters.idr(diskon)}');
    }
    if (catatan.isNotEmpty) b.writeln('Catatan: $catatan');
    b.writeln('');
    b.writeln(
      'Mohon info ketersediaan kursi & total pembayaran. Terima kasih.',
    );
    return b.toString();
  }
}
