import 'dart:math';

import 'package:intl/intl.dart';

/// Helper format mata uang & tanggal Indonesia.
class Formatters {
  static final NumberFormat _idr = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp',
    decimalDigits: 0,
  );

  /// 450000 -> "Rp450.000"
  static String idr(num value) => _idr.format(value);

  // Di-cache agar tidak alokasi objek baru setiap format dipanggil.
  static final DateFormat _full = DateFormat('EEEE, d MMM yyyy', 'id_ID');
  static final DateFormat _short = DateFormat('d MMM yyyy', 'id_ID');

  /// DateTime -> "Sabtu, 12 Sep 2026"
  static String fullDate(DateTime date) => _full.format(date);

  /// DateTime -> "12 Sep 2026"
  static String shortDate(DateTime date) => _short.format(date);

  /// DateTime -> "2026-09-12" (format simpan di database).
  static String toISO(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// "2026-09-12" -> "12 Sep 2026".
  /// Data lama (sudah berupa "12 Sep 2026") dikembalikan apa adanya,
  /// sehingga riwayat pengguna lama tetap tampil benar tanpa migrasi.
  static String displayShort(String stored) {
    final parsed = DateTime.tryParse(stored);
    if (parsed == null) return stored;
    return _short.format(DateTime(parsed.year, parsed.month, parsed.day));
  }

  /// Kunci idempotency untuk permintaan pembuatan pesanan.
  ///
  /// Dikirim ke server: bila jaringan putus dan permintaan diulang, server
  /// mengenali kunci yang sama sehingga tidak membuat pesanan ganda.
  static String idempotencyKey() {
    final random = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buf.write(random.nextInt(16).toRadixString(16));
    }
    return 'app-${DateTime.now().millisecondsSinceEpoch}-${buf.toString()}';
  }

  /// Kode booking unik, mis. "RARA-9X2K7Q"
  static String bookingCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buf.write(chars[random.nextInt(chars.length)]);
    }
    return 'RARA-${buf.toString()}';
  }
}
