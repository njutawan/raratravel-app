import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

/// Optional Supabase connection. Firebase remains usable when this is absent.
class SupabaseBootstrap {
  static bool ready = false;

  static Future<void> init() async {
    if (!SupabaseConfig.isConfigured) {
      debugPrint('Supabase: belum dikonfigurasi (mode Firebase/local)');
      return;
    }

    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );
      ready = true;
      debugPrint('Supabase: terhubung');
    } catch (e) {
      ready = false;
      debugPrint('Supabase: gagal terhubung ($e)');
    }
  }

  static SupabaseClient get client {
    if (!ready) {
      throw StateError('Supabase belum dikonfigurasi atau gagal diinisialisasi');
    }
    return Supabase.instance.client;
  }
}
