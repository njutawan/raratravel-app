import 'package:flutter/material.dart';
import 'notif_primer_screen.dart';
import '../services/preferences_service.dart';
import '../theme/app_theme.dart';

/// Layar selamat datang saat pertama kali membuka aplikasi
/// (ala Traveloka): banner + sapaan + preferensi + Lanjutkan.
/// Hanya tampil sekali — statusnya disimpan di HP.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String _mataUang = 'IDR';
  String _bahasa = 'id';
  bool _loading = false;

  Future<void> _lanjut() async {
    setState(() => _loading = true);
    await PreferencesService.setPreferensiDasar(
      mataUang: _mataUang,
      bahasa: _bahasa,
    );
    await PreferencesService.setOnboardingDone();
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
                const SizedBox(height: 32),
                const _PreferensiLabel(teks: 'Pilihan Mata Uang'),
                DropdownButtonFormField<String>(
                  initialValue: _mataUang,
                  decoration: _dekorasiDropdown(),
                  items: const [
                    DropdownMenuItem(
                      value: 'IDR',
                      child: Text('IDR - Rupiah Indonesia (Rp)'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _mataUang = v ?? _mataUang),
                ),
                const SizedBox(height: 32),
                const _PreferensiLabel(teks: 'Pilihan Bahasa'),
                DropdownButtonFormField<String>(
                  initialValue: _bahasa,
                  decoration: _dekorasiDropdown(),
                  items: const [
                    DropdownMenuItem(value: 'id', child: Text('Indonesia')),
                  ],
                  onChanged: (v) => setState(() => _bahasa = v ?? _bahasa),
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
                      onPressed: _loading ? null : _lanjut,
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

/// Label kecil abu-abu di atas dropdown preferensi (gaya Traveloka).
class _PreferensiLabel extends StatelessWidget {
  final String teks;
  const _PreferensiLabel({required this.teks});

  @override
  Widget build(BuildContext context) {
    return Text(
      teks,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Colors.grey.shade600,
      ),
    );
  }
}

/// Dropdown garis bawah tipis (tanpa kotak), seperti layar preferensi.
InputDecoration _dekorasiDropdown() => InputDecoration(
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: AppTheme.primary, width: 2),
      ),
    );
