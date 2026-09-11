import 'package:shared_preferences/shared_preferences.dart';
import '../models/booking.dart';

/// Penyimpanan riwayat booking di HP (offline, tanpa server).
class BookingStorage {
  static const _key = 'rara_bookings_v1';
  static const _migratedKey = 'rara_migrated_v1';
  static const _dirtyKey = 'rara_dirty_v1';

  /// Kode booking yang sudah naik ke cloud (anti migrasi ulang tiap login).
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

  // ---------- Outbox offline: batal/hapus yg gagal ke cloud ----------

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

  static Future<List<Booking>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    return list.map(Booking.fromJson).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static Future<void> add(Booking booking) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.add(booking.toJson());
    await prefs.setStringList(_key, list);
  }

  static Future<void> updateStatus(String kode, String status) async {
    await markDirty(kode); // outbox: disinkron saat login berikutnya
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final updated = all
        .map((b) => b.kode == kode ? b.copyWith(status: status) : b)
        .map((b) => b.toJson())
        .toList();
    await prefs.setStringList(_key, updated);
  }

  /// Hapus seluruh riwayat lokal (dipakai saat Hapus Akun).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_migratedKey);
    await prefs.remove(_dirtyKey);
  }

  static Future<void> remove(String kode) async {
    await markDirty(kode); // outbox: hapus cloud-nya saat login berikutnya
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final filtered = all
        .where((b) => b.kode != kode)
        .map((b) => b.toJson())
        .toList();
    await prefs.setStringList(_key, filtered);
  }
}
