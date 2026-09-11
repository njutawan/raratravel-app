import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../screens/login_carousel_screen.dart';
import 'firebase_bootstrap.dart';

/// Gerbang login: pastikan user masuk sebelum aksi butuh-akun (booking).
/// Kembalikan [User] bila berhasil, null bila batal / mode offline.
class AuthGate {
  static Future<User?> ensureLoggedIn(BuildContext context) async {
    if (!FirebaseBootstrap.ready) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Mode offline: selesaikan PANDUAN_FIREBASE.md agar bisa pesan.',
            ),
          ),
        );
      }
      return null;
    }
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) return current;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginCarouselScreen()),
    );
    if (ok != true) return null;
    return FirebaseAuth.instance.currentUser;
  }
}
