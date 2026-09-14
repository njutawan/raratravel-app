import 'supabase_config.dart';

/// Pilihan backend saat migrasi Firebase → Supabase berjalan bertahap.
///
/// Semua sakelar diatur saat build (tidak perlu ubah kode):
///
///   flutter run \
///     --dart-define=SUPABASE_URL=https://xxx.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJ... \
///     --dart-define=BOOKING_WRITE=dual      \  # dual | supabase | firestore
///     --dart-define=CATALOG_SOURCE=supabase \  # local | supabase
///     --dart-define=PAYMENTS_ENABLED=true
///
/// Urutan migrasi yang aman (lihat MIGRASI_SUPABASE.md):
///   1. BookingsMode.dual     → tulis ke Supabase + Firestore (jika keduanya siap)
///   2. BookingsMode.supabase → Firestore tidak lagi ditulis (langkah 12)
///   3. BookingsMode.firestore→ kembali ke perilaku lama bila perlu rollback
class BackendConfig {
  /// Asal data katalog: 'local' (dummy_data.dart) atau 'supabase' (API).
  static const String _catalogSource =
      String.fromEnvironment('CATALOG_SOURCE', defaultValue: 'local');

  /// Penulisan pesanan: 'dual' | 'supabase' | 'firestore'.
  static const String _bookingWrite =
      String.fromEnvironment('BOOKING_WRITE', defaultValue: 'dual');

  /// Fitur pembayaran online (Midtrans/transfer manual tercatat).
  static const bool _paymentsEnabled =
      bool.fromEnvironment('PAYMENTS_ENABLED', defaultValue: false);

  /// Batas tunggu panggilan Edge Function (detik).
  static const int callTimeoutSeconds =
      int.fromEnvironment('EDGE_TIMEOUT', defaultValue: 15);

  /// Supabase API tersedia? (URL + anon key terisi)
  static bool get hasSupabase => SupabaseConfig.isConfigured;

  /// Katalog dibaca dari Supabase.
  static bool get useSupabaseCatalog =>
      hasSupabase && _catalogSource.toLowerCase() == 'supabase';

  /// Pesanan dibaca/ditulis ke Supabase.
  static bool get useSupabaseBooking {
    if (!hasSupabase) return false;
    final mode = _bookingWrite.toLowerCase();
    return mode == 'dual' || mode == 'supabase';
  }

  /// Sementara migrasi berjalan, Firestore tetap ditulis (opsi 'dual').
  static bool get writeFirestore {
    final mode = _bookingWrite.toLowerCase();
    return mode == 'dual' || mode == 'firestore';
  }

  /// Firestore masih menjadi sumber kebenaran saat rollback.
  static bool get firestoreIsSourceOfTruth =>
      _bookingWrite.toLowerCase() == 'firestore' || !hasSupabase;

  static bool get paymentsEnabled => hasSupabase && _paymentsEnabled;

  /// Terangkan mode aktif untuk kebutuhan debugging/support.
  static String get deskripsi =>
      'katalog=${useSupabaseCatalog ? 'supabase' : 'lokal'}, '
      'pesanan=${_bookingWrite.toLowerCase()}, '
      'pembayaran=${paymentsEnabled ? 'aktif' : 'nonaktif'}';
}
