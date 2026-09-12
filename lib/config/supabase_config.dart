/// Supabase configuration is supplied at build time.
///
/// flutter run --dart-define=SUPABASE_URL=https://... \
///   --dart-define=SUPABASE_ANON_KEY=...
class SupabaseConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
