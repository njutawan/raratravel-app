import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:raratravel_app/utils/formatters.dart';

/// Uji format mata uang & tanggal (dipakai di seluruh layar).
void main() {
  // Formatter tanggal memakai locale id_ID — data locale harus dimuat dulu.
  setUpAll(() async => initializeDateFormatting('id_ID', null));

  group('Formatters', () {
    test('idr memakai gaya Indonesia (titik ribuan, tanpa desimal)', () {
      expect(Formatters.idr(450000), 'Rp450.000');
      expect(Formatters.idr(0), 'Rp0');
      expect(Formatters.idr(1250000), 'Rp1.250.000');
    });

    test('fullDate & shortDate memakai nama hari/bulan Indonesia', () {
      final tanggal = DateTime(2026, 9, 12);
      expect(Formatters.fullDate(tanggal), 'Sabtu, 12 Sep 2026');
      expect(Formatters.shortDate(tanggal), '12 Sep 2026');
    });

    test('toISO selalu dua digit', () {
      expect(Formatters.toISO(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('displayShort menerima format baru & lama', () {
      expect(Formatters.displayShort('2026-09-12'), '12 Sep 2026');
      // Data lama tersimpan sebagai teks siap tampil → dikembalikan apa adanya.
      expect(Formatters.displayShort('12 Sep 2026'), '12 Sep 2026');
    });

    test('tryParseDate menerima ISO dan teks lama', () {
      expect(Formatters.tryParseDate('2026-09-12'), DateTime(2026, 9, 12));
      expect(Formatters.tryParseDate('12 Sep 2026'), DateTime(2026, 9, 12));
      expect(Formatters.tryParseDate('bukan tanggal'), isNull);
    });

    test('kode booking unik, aman, dan berformat RARA-XXXXXX', () {
      final kode = Formatters.bookingCode();
      expect(RegExp(r'^RARA-[A-Z2-9]{6}$').hasMatch(kode), isTrue);
      expect(Formatters.bookingCode(), isNot(kode));
    });

    test('kunci idempotency berbeda tiap panggilan', () {
      final a = Formatters.idempotencyKey();
      final b = Formatters.idempotencyKey();
      expect(a, startsWith('app-'));
      expect(a, isNot(b));
    });
  });
}
