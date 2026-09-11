import 'package:flutter/material.dart';
import '../app.dart';
import 'login_carousel_screen.dart';
import '../services/firebase_bootstrap.dart';
import '../services/auth_service.dart';
import '../services/messaging_service.dart';
import '../services/preferences_service.dart';
import '../theme/app_theme.dart';

/// Layar primer izin notifikasi (ala Traveloka), tampil setelah onboarding:
/// menjelaskan manfaat notifikasi + tombol "Ya, Saya Bersedia".
class NotifPrimerScreen extends StatefulWidget {
  const NotifPrimerScreen({super.key});

  @override
  State<NotifPrimerScreen> createState() => _NotifPrimerScreenState();
}

class _NotifPrimerScreenState extends State<NotifPrimerScreen> {
  bool _loading = false;

  Future<void> _selesai({required bool setuju}) async {
    setState(() => _loading = true);
    if (setuju) {
      // Minta izin sistem (dialog Android 13+) bila Firebase siap.
      if (FirebaseBootstrap.ready) {
        await MessagingService.requestPermission();
      }
      await PreferencesService.setNotifPrimerDone();
    } else {
      // Tunda: tanya lagi 3 hari kemudian.
      await PreferencesService.snoozeNotifPrimer();
    }
    // Wajib login sebelum dashboard (kecuali mode offline / sudah login).
    final user = await AuthService.currentUserAsync();
    if (!mounted) return;
    final Widget next = (FirebaseBootstrap.ready && user == null)
        ? const LoginCarouselScreen(replaceToHome: true)
        : const MainNav();
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // ---------- Header lengkung + tombol tutup ----------
          SizedBox(
            height: 190,
            child: Stack(
              children: [
                ClipPath(
                  clipper: _CurveClipper(),
                  child: Container(
                    height: 175,
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.primary, AppTheme.primaryDark],
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 74,
                        height: 74,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.notifications_active_outlined,
                          size: 36,
                          color: AppTheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: 8,
                  child: IconButton(
                    onPressed: _loading ? null : () => _selesai(setuju: false),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Tutup',
                  ),
                ),
              ],
            ),
          ),

          // ---------- Penjelasan + manfaat ----------
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              children: [
                Text(
                  'Notifikasi akan memberikan Anda akses ke informasi penting tentang perjalanan seperti:',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.grey.shade800,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                const _BenefitTile(
                  icon: Icons.confirmation_number_outlined,
                  color: AppTheme.primary,
                  title: 'Status & Notifikasi Pesanan',
                ),
                const SizedBox(height: 10),
                const _BenefitTile(
                  icon: Icons.alarm_outlined,
                  color: Colors.orange,
                  title: 'Pengingat Jadwal Keberangkatan',
                ),
                const SizedBox(height: 10),
                const _BenefitTile(
                  icon: Icons.local_offer_outlined,
                  color: Colors.blue,
                  title: 'Promo & Info Rute Terbaru',
                ),
                const SizedBox(height: 20),
                const Text(
                  'Akses Cepat ke Info Terbaru',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),

          // ---------- Tombol ganda ----------
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : () => _selesai(setuju: true),
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Ya, Saya Bersedia'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: _loading
                          ? null
                          : () => _selesai(setuju: false),
                      child: const Text('Nanti Saja'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kartu manfaat: ikon lingkaran + judul.
class _BenefitTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;

  const _BenefitTile({
    required this.icon,
    required this.color,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: const [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lengkungan bawah header.
class _CurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..lineTo(0, size.height - 30)
      ..quadraticBezierTo(
        size.width / 2,
        size.height + 24,
        size.width,
        size.height - 30,
      )
      ..lineTo(size.width, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
