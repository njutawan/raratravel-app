import 'dart:async';

import '../config/backend_config.dart';
import '../models/booking.dart';
import '../services/booking_storage.dart';
import '../services/edge_client.dart';
import '../utils/formatters.dart';

/// Halaman riwayat pesanan dari server.
class BookingPage {
  final List<Booking> items;
  final int total;
  final int limit;
  final int offset;

  const BookingPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  bool get hasMore => offset + items.length < total;

  factory BookingPage.fromApi(Map<String, dynamic> json, {String userId = ''}) {
    final daftar = (json['items'] as List?) ?? const [];
    return BookingPage(
      items: daftar
          .whereType<Map>()
          .map((item) => Booking.fromApi(Map<String, dynamic>.from(item), userId: userId))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? daftar.length,
      limit: (json['limit'] as num?)?.toInt() ?? daftar.length,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Hasil pembuatan pesanan di server.
class CreateBookingResult {
  final Booking booking;
  final bool idempotent;
  final int remainingSeats;

  const CreateBookingResult({
    required this.booking,
    required this.idempotent,
    required this.remainingSeats,
  });
}

/// Akses pesanan di PostgreSQL melalui Edge Function (langkah 6 & 7 migrasi).
///
/// Selalu menulis ke riwayat HP juga, sehingga daftar tetap tampil saat offline.
class BookingRepository {
  /// Aktif bila build dikonfigurasi memakai Supabase dan URL/anon key terisi.
  static bool get enabled => BackendConfig.useSupabaseBooking && EdgeClient.ready;

  /// Buat pesanan baru.
  ///
  /// [idempotencyKey] wajib: kunci yang sama membuat ulang permintaan
  /// (jaringan putus / tombol ditekan dua kali) tidak menghasilkan pesanan ganda.
  static Future<CreateBookingResult> create({
    required Booking draft,
    required String idempotencyKey,
    String? userId,
  }) async {
    final hasil = await EdgeClient.invoke(
      'create-booking',
      body: {
        'idempotency_key': idempotencyKey,
        ...draft.toCreatePayload(),
      },
      auth: true,
    );

    final bookingJson = Map<String, dynamic>.from(hasil['booking'] as Map);
    final booking = Booking.fromApi(bookingJson, userId: userId ?? draft.userId);

    // Simpan ke riwayat HP (upsert: permintaan ulang tidak menggandakan baris).
    await BookingStorage.save(booking);
    await BookingStorage.markMigrated(booking.kode);
    await BookingStorage.unmarkDirty(booking.kode);

    final pricing = hasil['pricing'];
    final sisa = pricing is Map
        ? (pricing['remaining_seats'] as num?)?.toInt() ?? 0
        : 0;

    return CreateBookingResult(
      booking: booking,
      idempotent: hasil['idempotent'] == true,
      remainingSeats: sisa,
    );
  }

  /// Riwayat pesanan milik pengguna yang login.
  static Future<BookingPage> listMine({
    int limit = 20,
    int offset = 0,
    String? status,
    String? userId,
  }) async {
    final hasil = await EdgeClient.invoke(
      'manage-booking',
      body: {
        'action': 'list',
        'limit': limit,
        'offset': offset,
        if (status != null && status.isNotEmpty) 'status': status,
      },
      auth: true,
    );
    return BookingPage.fromApi(hasil, userId: userId ?? '');
  }

  /// Satu pesanan berdasarkan kode.
  static Future<Booking?> detail(String kode, {String? userId}) async {
    final hasil = await EdgeClient.invoke(
      'manage-booking',
      body: {'action': 'detail', 'kode': kode},
      auth: true,
    );
    final booking = hasil['booking'];
    if (booking is! Map) return null;
    return Booking.fromApi(Map<String, dynamic>.from(booking), userId: userId ?? '');
  }

  /// Batalkan pesanan; kursi dikembalikan di server.
  static Future<Booking?> cancel(String kode, {String? reason, String? userId}) async {
    final hasil = await EdgeClient.invoke(
      'manage-booking',
      body: {
        'action': 'cancel',
        'kode': kode,
        if (reason != null && reason.isNotEmpty) 'note': reason,
      },
      auth: true,
    );
    final booking = hasil['booking'];
    if (booking is! Map) return null;
    final hasilBooking = Booking.fromApi(Map<String, dynamic>.from(booking), userId: userId ?? '');
    await BookingStorage.save(hasilBooking);
    return hasilBooking;
  }

  /// Stream riwayat: tampilkan riwayat HP lebih dulu, lalu data server.
  ///
  /// Server belum bisa memakai Realtime karena login memakai Firebase (bukan
  /// Supabase Auth), jadi daftar disegarkan berkala selama layar terbuka.
  /// Notifikasi perubahan status tetap datang lewat FCM (tanpa polling saat
  /// aplikasi di latar belakang).
  static Stream<List<Booking>> watchMine({
    Duration interval = const Duration(minutes: 2),
    int limit = 50,
  }) {
    late StreamController<List<Booking>> controller;
    Timer? timer;
    var sedangMuat = false;

    Future<void> muat({required bool pakaiCache}) async {
      if (sedangMuat || controller.isClosed) return;
      sedangMuat = true;
      try {
        if (pakaiCache) {
          controller.add(await BookingStorage.loadAll());
        }
        final halaman = await listMine(limit: limit);
        await BookingStorage.mergeFromServer(halaman.items);
        if (!controller.isClosed) {
          controller.add(await BookingStorage.loadAll());
        }
      } catch (error) {
        if (!controller.isClosed) {
          controller.addError(error);
        }
      } finally {
        sedangMuat = false;
      }
    }

    controller = StreamController<List<Booking>>(
      onListen: () {
        muat(pakaiCache: true);
        timer = Timer.periodic(interval, (_) => muat(pakaiCache: false));
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );

    return controller.stream;
  }

  /// Kunci idempotency baru untuk satu percobaan pemesanan.
  static String newIdempotencyKey() => Formatters.idempotencyKey();
}
