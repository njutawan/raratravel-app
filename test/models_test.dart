import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:raratravel_app/models/booking.dart';
import 'package:raratravel_app/models/booking_status.dart';

/// Uji pemetaan status & format data pesanan.
void main() {
  // Formatter tanggal memakai locale id_ID — data locale harus dimuat dulu.
  setUpAll(() async => initializeDateFormatting('id_ID', null));

  group('BookingStatus', () {
    test('label kode server → tampilan Indonesia', () {
      expect(BookingStatus.label('pending'), 'Menunggu Konfirmasi');
      expect(BookingStatus.label('confirmed'), 'Dikonfirmasi');
      expect(BookingStatus.label('completed'), 'Selesai');
      expect(BookingStatus.label('cancelled'), 'Dibatalkan');
      expect(BookingStatus.label('expired'), 'Kedaluwarsa');
      expect(BookingStatus.label(null), 'Menunggu Konfirmasi');
    });

    test('kompatibel dengan data lama (label bebas → kode server)', () {
      expect(BookingStatus.code('Menunggu Konfirmasi'), 'pending');
      expect(BookingStatus.code('Dikonfirmasi'), 'confirmed');
      expect(BookingStatus.code('Lunas'), 'confirmed');
      expect(BookingStatus.code('Dibatalkan'), 'cancelled');
      expect(BookingStatus.code('kode aneh'), 'pending');
    });

    test('isActive hanya untuk pesanan yang masih berjalan', () {
      expect(BookingStatus.isActive('pending'), isTrue);
      expect(BookingStatus.isActive('confirmed'), isTrue);
      expect(BookingStatus.isActive('completed'), isFalse);
      expect(BookingStatus.isActive('Dibatalkan'), isFalse);
      expect(BookingStatus.isActive('expired'), isFalse);
    });
  });

  group('PaymentStatus', () {
    test('label status pembayaran', () {
      expect(PaymentStatus.label('unpaid'), 'Belum Dibayar');
      expect(PaymentStatus.label('partial'), 'Dibayar Sebagian');
      expect(PaymentStatus.label('paid'), 'Lunas');
      expect(PaymentStatus.label('refunded'), 'Dana Dikembalikan');
    });

    test('isPaid hanya untuk paid', () {
      expect(PaymentStatus.isPaid('paid'), isTrue);
      expect(PaymentStatus.isPaid('PAID'), isTrue);
      expect(PaymentStatus.isPaid('pending'), isFalse);
      expect(PaymentStatus.isPaid(null), isFalse);
    });
  });

  group('Booking', () {
    Booking contoh() => Booking(
      kode: 'RARA-ABC123',
      asal: 'Jember',
      tujuan: 'Surabaya',
      tanggal: '2026-09-12',
      jam: '06:00',
      nama: 'Budi',
      wa: '+6281234567890',
      jemput: 'Jl. Mawar No. 1, Jember',
      antar: 'Jl. Melati No. 2, Surabaya',
      kursi: 2,
      totalHarga: 900000,
      metodeBayar: 'Transfer Bank',
      createdAt: '2026-09-01T10:00:00.000',
    );

    test('status tanpa statusCode diturunkan dari label (data lama)', () {
      expect(contoh().statusKode, 'pending');
      expect(contoh().bisaDibatalkan, isTrue);
    });

    test('data server dipetakan apa adanya', () {
      final b = Booking.fromApi({
        'kode': 'RARA-XYZ789',
        'origin': 'Malang',
        'destination': 'Banyuwangi',
        'travel_date': '2026-09-20',
        'departure_time': '19:00',
        'contact_name': 'Sari',
        'contact_phone': '+628111222333',
        'pickup_address': 'Alamat jemput',
        'dropoff_address': 'Alamat antar',
        'seats': 3,
        'total': 1350000,
        'payment_method': 'QRIS',
        'status': 'confirmed',
        'status_label': 'Dikonfirmasi',
        'payment_status': 'partial',
        'id': 'uuid-1',
      }, userId: 'uid-1');

      expect(b.jamDisplay, '19.00');
      expect(b.wa, '08111222333');
      expect(b.statusKode, 'confirmed');
      expect(b.paymentStatus, 'partial');
      expect(b.sudahDibayar, isFalse);
      expect(b.bisaDibatalkan, isTrue);
      expect(b.userId, 'uid-1');
    });

    test('copyWith mengganti status & statusCode bersama-sama', () {
      final b = contoh().copyWith(
        status: 'Dibatalkan',
        statusCode: BookingStatus.cancelled,
      );
      expect(b.status, 'Dibatalkan');
      expect(b.statusKode, BookingStatus.cancelled);
      expect(b.bisaDibatalkan, isFalse);
    });

    test('payload server memakai harga sebagai pembanding (client_total)', () {
      final payload = contoh().toCreatePayload();
      expect(payload['origin'], 'Jember');
      expect(payload['seats'], 2);
      expect(payload['client_total'], 900000);
      expect(payload.containsKey('promo_code'), isFalse);
    });

    test('toJson/fromJson bolak-balik tanpa kehilangan data', () {
      final asli = contoh().copyWith(id: 'uuid-2', paymentStatus: 'paid');
      final lagi = Booking.fromJson(asli.toJson());
      expect(lagi.kode, asli.kode);
      expect(lagi.totalHarga, asli.totalHarga);
      expect(lagi.id, asli.id);
      expect(lagi.paymentStatus, 'paid');
      expect(lagi.sudahDibayar, isTrue);
      expect(lagi.tanggalDisplay, '12 Sep 2026');
    });

    test('fromMap toleran terhadap field hilang / tipe salah', () {
      final b = Booking.fromMap({
        'kode': 'RARA-TAHAN1',
        'kursi': '3', // teks angka
        'totalHarga': null, // kosong
        'diskon': 'abc', // bukan angka sama sekali
      });
      expect(b.kursi, 3);
      expect(b.totalHarga, 0);
      expect(b.diskon, 0);
      expect(b.status, 'Menunggu Konfirmasi');
      expect(b.createdAt, isNotEmpty);
    });

    test('fromMap menerima angka desimal pada field rupiah', () {
      final b = Booking.fromMap({
        'kode': 'RARA-TAHAN2',
        'totalHarga': 900000.0,
        'diskon': 50000.75,
      });
      expect(b.totalHarga, 900000);
      expect(b.diskon, 50000); // dibulatkan ke bawah (toInt)
    });

    test('fromApi toleran bila jumlah kursi dikirim sebagai teks', () {
      final b = Booking.fromApi({
        'kode': 'RARA-TAHAN3',
        'seats': '4',
        'total': '360000',
      });
      expect(b.kursi, 4);
      expect(b.totalHarga, 360000);
    });

    test('pesan WhatsApp memuat kode, rute, dan promo', () {
      final pesan = contoh()
          .copyWith(promo: 'RARAHEMAT', diskon: 50000)
          .toWhatsAppMessage();
      expect(pesan, contains('RARA-ABC123'));
      expect(pesan, contains('Jember → Surabaya'));
      expect(pesan, contains('Promo: RARAHEMAT'));
      expect(pesan, contains('Diskon: Rp50.000'));
    });
  });
}
