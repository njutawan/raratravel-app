import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/app_user.dart';
import '../models/booking.dart';

/// Database cloud: koleksi `users` & `bookings`.
class FirestoreService {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  static CollectionReference<Map<String, dynamic>> get _bookings =>
      _db.collection('bookings');

  // ---------------- USERS ----------------

  static Future<AppUser?> getUser(String uid) async {
    final doc = await _users.doc(uid).get();
    if (!doc.exists) return null;
    return AppUser.fromMap(doc.id, doc.data()!);
  }

  static Future<void> saveUser(AppUser user) =>
      _users.doc(user.uid).set(user.toMap(), SetOptions(merge: true));

  static Future<void> addFcmToken(String uid, String token) =>
      _users.doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));

  // ---------------- BOOKINGS ----------------
  // ID dokumen = kode booking → simpan idempoten (aman dipanggil ulang).

  static Future<void> saveBooking(Booking booking, String uid) =>
      _bookings.doc(booking.kode).set(booking.copyWith(userId: uid).toMap());

  static Future<void> updateStatus(String kode, String status) =>
      _bookings.doc(kode).update({'status': status});

  static Future<void> deleteBooking(String kode) =>
      _bookings.doc(kode).delete();

  /// Hapus seluruh data cloud milik [uid] (profil + semua pesanan).
  /// Dipakai fitur Hapus Akun.
  static Future<void> deleteAllUserData(String uid) async {
    final snap = await _bookings.where('userId', isEqualTo: uid).get();
    for (final d in snap.docs) {
      try {
        await d.reference.delete();
      } catch (_) {}
    }
    try {
      await _users.doc(uid).delete();
    } catch (_) {}
  }

  /// Riwayat pesanan milik user, terbaru dulu, maks 50.
  /// Pakai orderBy server bila composite index tersedia (lihat
  /// firestore.indexes.json); bila belum / offline → otomatis fallback
  /// ke query tanpa order. Sort lokal tetap dijaga utk konsistensi.
  static Stream<List<Booking>> userBookings(String uid) async* {
    final col = _bookings.where('userId', isEqualTo: uid);
    List<Booking> rapikan(QuerySnapshot<Map<String, dynamic>> snap) {
      final list = snap.docs.map((d) => Booking.fromMap(d.data())).toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    }

    // Probe murah (1 doc): pastikan index ada & online sebelum orderBy.
    try {
      await col.orderBy('createdAt', descending: true).limit(1).get();
      yield* col
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .map(rapikan);
    } catch (_) {
      yield* col.snapshots().map(rapikan);
    }
  }
}
