import 'package:shared_preferences/shared_preferences.dart';
import '../config/backend_config.dart';
import '../models/booking.dart';
import '../models/booking_status.dart';

/// Penyimpanan riwayat booking di HP (offline, tanpa server).
///
/// Outbox dipisah per backend: jalur lama (Firestore) dan jalur baru
/// (Supabase) dikuras oleh proses berbeda saat login, jadi satu proses tidak
/// boleh menghapus antrean milik proses lain.
class BookingStorage {
  static const _key = 'rara_bookings_v1';
  static const _migratedKey = 'rara_migrated_v1'; // penanda sinkron Firestore
  static const _migratedSbKey = 'rara_migrated_sb_v1'; // penanda sinkron Supabase
  static const _dirtyKey = 'rara_dirty_v1'; // outbox Firestore
  static const _dirtySbKey = 'rara_dirty_sb_v1'; // outbox Supabase
  static const _outboxKeyKey = 'rara_outbox_key_v1'; // kode → kunci idempotency

  // ---------- Penanda migrasi (anti kirim ulang tiap login) ----------

  /// Kode booking yang sudah naik ke Firestore.
  static Future<Set<String>> migratedCodes() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_migratedKey) ?? []).toSet();
  }

  static Future<void> markMigrated(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_migratedKey) ?? [];
    if (!list.contains(kode)) {
      list.add(kode);
      await prefs.setStringList(_migratedKey, list);
    }
  }

  /// Kode booking yang sudah ada di server baru (Supabase).
  static Future<Set<String>> migratedSbCodes() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_migratedSbKey) ?? []).toSet();
  }

  static Future<void> markMigratedSb(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_migratedSbKey) ?? [];
    if (!list.contains(kode)) {
      list.add(kode);
      await prefs.setStringList(_migratedSbKey, list);
    }
  }

  // ---------- Outbox offline ----------

  /// Cari 1 pesanan lokal berdasar kode (null bila sudah dihapus).
  static Future<Booking?> findByKode(String kode) async {
    for (final b in await loadAll()) {
      if (b.kode == kode) return b;
    }
    return null;
  }

  static Future<void> markDirty(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_dirtyKey) ?? [];
    if (!list.contains(kode)) {
      list.add(kode);
      await prefs.setStringList(_dirtyKey, list);
    }
  }

  static Future<void> unmarkDirty(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_dirtyKey) ?? [];
    if (list.remove(kode)) await prefs.setStringList(_dirtyKey, list);
  }

  static Future<List<String>> dirtyCodes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_dirtyKey) ?? [];
  }

  /// Tandai pesanan perlu dikirim ke Supabase.
  ///
  /// [idempotencyKey] disimpan bila ada: pengiriman ulang (mis. setelah
  /// jaringan putus di tengah jalan) memakai kunci yang sama sehingga server
  /// tidak membuat pesanan ganda.
  static Future<void> markDirtySb(
    String kode, {
    String? idempotencyKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_dirtySbKey) ?? [];
    if (!list.contains(kode)) {
      list.add(kode);
      await prefs.setStringList(_dirtySbKey, list);
    }
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      final keys = Map<String, String>.from(
        prefs.getStringMap(_outboxKeyKey) ?? const {},
      );
      keys[kode] = idempotencyKey;
      await prefs.setStringMap(_outboxKeyKey, keys);
    }
  }

  static Future<void> unmarkDirtySb(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_dirtySbKey) ?? [];
    if (list.remove(kode)) await prefs.setStringList(_dirtySbKey, list);
    final keys = Map<String, String>.from(
      prefs.getStringMap(_outboxKeyKey) ?? const {},
    );
    if (keys.remove(kode) != null) await prefs.setStringMap(_outboxKeyKey, keys);
  }

  static Future<List<String>> dirtySbCodes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_dirtySbKey) ?? [];
  }

  /// Kunci idempotency yang dipakai saat pesanan pertama kali dikirim.
  static Future<String?> idempotencyKeyFor(String kode) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringMap(_outboxKeyKey) ?? const {})[kode];
  }

  // ---------- Riwayat ----------

  static Future<List<Booking>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    return list.map(Booking.fromJson).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Simpan/perbarui satu pesanan (upsert berdasarkan kode).
  ///
  /// Dipakai saat data datang dari server: permintaan yang diulang
  /// (idempotent) tidak boleh menghasilkan baris ganda di riwayat HP.
  static Future<void> save(Booking booking) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    final hasil = <String>[];
    var ketemu = false;
    for (final item in list) {
      final ada = Booking.fromJson(item);
      if (ada.kode == booking.kode) {
        hasil.add(booking.toJson());
        ketemu = true;
      } else {
        hasil.add(item);
      }
    }
    if (!ketemu) hasil.add(booking.toJson());
    await prefs.setStringList(_key, hasil);
  }

  /// Gabungkan daftar dari server ke riwayat HP (tanpa menghapus data lokal
  /// yang belum sempat tersinkron: pesanan offline tetap tampil).
  static Future<void> mergeFromServer(List<Booking> daftar) async {
    for (final booking in daftar) {
      await save(booking);
    }
  }

  static Future<void> updateStatus(String kode, String status) async {
    // Outbox: disinkron saat login berikutnya.
    await markDirty(kode);
    if (BackendConfig.useSupabaseBooking) await markDirtySb(kode);
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final kodeStatus = BookingStatus.code(status);
    // statusCode ikut diperbarui: tombol "Batalkan" membaca kode server,
    // jadi tanpa ini pesanan yang sudah dibatalkan tetap terlihat aktif.
    final updated = all
        .map(
          (b) => b.kode == kode
              ? b.copyWith(status: status, statusCode: kodeStatus)
              : b,
        )
        .map((b) => b.toJson())
        .toList();
    await prefs.setStringList(_key, updated);
  }

  /// Hapus seluruh riwayat lokal (dipakai saat Hapus Akun).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_migratedKey);
    await prefs.remove(_migratedSbKey);
    await prefs.remove(_dirtyKey);
    await prefs.remove(_dirtySbKey);
    await prefs.remove(_outboxKeyKey);
  }

  static Future<void> remove(String kode) async {
    await markDirty(kode); // outbox: hapus cloud-nya saat login berikutnya
    if (BackendConfig.useSupabaseBooking) await markDirtySb(kode);
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final filtered = all
        .where((b) => b.kode != kode)
        .map((b) => b.toJson())
        .toList();
    await prefs.setStringList(_key, filtered);
  }
}
