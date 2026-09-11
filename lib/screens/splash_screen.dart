import 'package:flutter/material.dart';
import '../app.dart';
import '../services/preferences_service.dart';
import '../services/auth_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/messaging_service.dart';
import 'onboarding_screen.dart';
import 'notif_primer_screen.dart';
import 'login_carousel_screen.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';

/// Splash screen sederhana dengan logo & tagline.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _lanjut();
  }

  /// Splash -> onboarding -> primer notifikasi -> login (wajib) -> beranda.
  /// Mode offline / sudah login -> langsung beranda.
  Future<void> _lanjut() async {
    // Semua cek jalan PARALEL + delay branding ikut overlap (bukan dijumlah).
    final hasil = await Future.wait([
      PreferencesService.isOnboardingDone(),
      PreferencesService.shouldShowNotifPrimer(),
      AuthService.currentUserAsync(),
      Future.delayed(const Duration(seconds: 2)),
    ]);
    if (!mounted) return;
    final done = hasil[0] as bool;
    final primer = hasil[1] as bool;
    final user = hasil[2]; // User? (dinamis agar tanpa import baru)
    Widget next = const MainNav();
    // Buka via ketuk notifikasi (app sedang mati) → langsung tab Pesananku.
    final viaNotifikasi = MessagingService.ambilTapTertunda();
    if (!done) {
      next = const OnboardingScreen();
    } else if (primer) {
      next = const NotifPrimerScreen();
    } else if (FirebaseBootstrap.ready && user == null) {
      next = const LoginCarouselScreen(replaceToHome: true);
    }
    if (next is MainNav && viaNotifikasi) {
      next = const MainNav(initialIndex: 2);
    }
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.primary, AppTheme.primaryDark],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset(
                'assets/icon/app_logo.png',
                width: 104,
                height: 104,
                cacheWidth: 312,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'RARA TRAVEL & TOUR',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppConstants.appTagline,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 28),
            const CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}
