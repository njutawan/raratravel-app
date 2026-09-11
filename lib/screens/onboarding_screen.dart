import 'package:flutter/material.dart';
import 'notif_primer_screen.dart';
import '../services/preferences_service.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';

/// Layar selamat datang saat pertama kali membuka aplikasi
/// (ala Traveloka): banner + sapaan + preferensi + Lanjutkan.
/// Hanya tampil sekali — statusnya disimpan di HP.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String _kotaAsal = 'Jember';
  bool _loading = false;

  Future<void> _lanjut({required bool simpan}) async {
    setState(() => _loading = true);
    if (simpan) {
      await PreferencesService.setOnboardingDone(kotaAsal: _kotaAsal);
    } else {
      await PreferencesService.setOnboardingDone();
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const NotifPrimerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // ---------- Header visual melengkung ----------
          SizedBox(
            height: 320,
            child: Stack(
              children: [
                ClipPath(
                  clipper: _CurveClipper(),
                  child: Image.asset(
                    'assets/images/onboarding_header.jpg',
                    width: double.infinity,
                    height: 300,
                    cacheWidth: 1200,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.cardShadow,
                            blurRadius: 10,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/icon/app_logo.png',
                          width: 76,
                          height: 76,
                          cacheWidth: 228,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---------- Sapaan + preferensi ----------
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
              children: [
                const Text(
                  'Halo! Selamat datang di Rara Travel & Tour.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Untuk melanjutkan, pilih preferensi Anda.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 20),
                const _BenefitRow(
                  icon: Icons.door_front_door_outlined,
                  text: 'Door-to-door: dijemput & diantar sampai depan pintu',
                ),
                const SizedBox(height: 8),
                const _BenefitRow(
                  icon: Icons.notifications_active_outlined,
                  text: 'Lacak pesanan + notifikasi status otomatis',
                ),
                const SizedBox(height: 8),
                const _BenefitRow(
                  icon: Icons.discount_outlined,
                  text: 'Kode RARAHEMAT: hemat 10% setiap booking',
                ),
                const SizedBox(height: 20),
                Text(
                  'Kota Keberangkatan Favorit',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _kotaAsal,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.my_location),
                    hintText: 'Pilih kota asal',
                  ),
                  items: AppConstants.cities
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setState(() => _kotaAsal = v ?? _kotaAsal),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kolom "Dari" di pencarian akan otomatis terisi kota ini. Bisa diubah kapan pun.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          // ---------- Tombol ----------
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : () => _lanjut(simpan: true),
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Lanjutkan'),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading ? null : () => _lanjut(simpan: false),
                    child: const Text('Lewati'),
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

/// Lengkungan bawah header (efek seperti aplikasi Traveloka).
class _CurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..lineTo(0, size.height - 44)
      ..quadraticBezierTo(
        size.width / 2,
        size.height + 24,
        size.width,
        size.height - 44,
      )
      ..lineTo(size.width, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// Baris manfaat onboarding (ikon + teks).
class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _BenefitRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: AppTheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    );
  }
}
