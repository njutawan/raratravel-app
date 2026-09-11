import 'dart:convert';

import '../utils/formatters.dart';

/// Model pemesanan kursi travel. Disimpan lokal (SharedPreferences).
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
  final String status; // Menunggu Konfirmasi / Dikonfirmasi / Dibatalkan
  final String createdAt; // ISO datetime
  final String userId; // uid Firebase pemilik ('' = pesanan lokal/offline)
  final String promo; // kode promo dipakai ('' = tanpa promo)
  final int diskon; // rupiah dipotong (0 = tanpa promo)

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
  });

  Booking copyWith({
    String? status,
    String? userId,
    String? promo,
    int? diskon,
  }) => Booking(
    kode: kode,
    asal: asal,
    tujuan: tujuan,
    tanggal: tanggal,
    jam: jam,
    nama: nama,
    wa: wa,
    jemput: jemput,
    antar: antar,
    kursi: kursi,
    totalHarga: totalHarga,
    metodeBayar: metodeBayar,
    catatan: catatan,
    status: status ?? this.status,
    createdAt: createdAt,
    userId: userId ?? this.userId,
    promo: promo ?? this.promo,
    diskon: diskon ?? this.diskon,
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
  };

  /// Parsing toleran: field hilang / tipe meleset → default aman,
  /// bukan layar error. (Data cloud bisa diedit manual dari Console.)
  static String _str(Map<String, dynamic> m, String k) =>
      (m[k] ?? '').toString();
  static int _num(Map<String, dynamic> m, String k) =>
      (m[k] as num?)?.toInt() ?? 0;

  factory Booking.fromMap(Map<String, dynamic> m) {
    final status = _str(m, 'status');
    final createdAt = _str(m, 'createdAt');
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
    );
  }

  String toJson() => jsonEncode(toMap());
  factory Booking.fromJson(String s) =>
      Booking.fromMap(jsonDecode(s) as Map<String, dynamic>);

  /// Tanggal siap tampil ("12 Sep 2026") — mendukung data lama & baru.
  String get tanggalDisplay => Formatters.displayShort(tanggal);

  /// Pesan WhatsApp siap kirim ke admin untuk konfirmasi booking.
  String toWhatsAppMessage() {
    final b = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya mau konfirmasi booking:')
      ..writeln('')
      ..writeln('Kode: *$kode*')
      ..writeln('Rute: $asal → $tujuan')
      ..writeln('Tanggal: $tanggalDisplay • Jam: $jam WIB')
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
