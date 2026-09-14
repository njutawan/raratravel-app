/// Supabase configuration is supplied at build time.
///
/// flutter run --dart-define=SUPABASE_URL=https://... \
///   --dart-define=SUPABASE_ANON_KEY=...   (anon lama ATAU sb_publishable_… )
class SupabaseConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');

  /// Kunci publik proyek. Supabase punya dua penamaan untuk kunci yang sama:
  /// `anon` (JWT, `eyJ…`) pada proyek lama dan *publishable key*
  /// (`sb_publishable_…`) pada model kunci baru. Keduanya boleh dipakai —
  /// keduanya aman berada di aplikasi karena hanya bisa menjangkau data yang
  /// diizinkan policy RLS.
  static const anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
