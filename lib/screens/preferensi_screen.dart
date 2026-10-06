import 'package:flutter/material.dart';
import 'notif_primer_screen.dart';
import '../services/preferences_service.dart';
import '../theme/app_theme.dart';

/// Layar preferensi (mata uang & bahasa) ala Traveloka yang muncul
/// SESUDAH onboarding, sebelum primer notifikasi & login.
/// Hanya tampil sekali — lanjutannya ditandai bersama onboarding selesai.
class PreferensiScreen extends StatefulWidget {
  const PreferensiScreen({super.key});

  @override
  State<PreferensiScreen> createState() => _PreferensiScreenState();
}

class _PreferensiScreenState extends State<PreferensiScreen> {
  String _mataUang = PreferencesService.defaultMataUang;
  String _bahasa = PreferencesService.defaultBahasa;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _muatPreferensiTersimpan();
  }

  /// Pengguna bisa membuka layar ini lagi (mis. dari Profil) — tampilkan
  /// pilihan yang sedang berlaku, bukan selalu nilai bawaan.
  Future<void> _muatPreferensiTersimpan() async {
    final prefs = await PreferencesService.getPreferensi();
    if (!mounted) return;
    setState(() {
      _mataUang = prefs.mataUang;
      _bahasa = prefs.bahasa;
    });
  }

  Future<void> _lanjut() async {
    setState(() => _loading = true);
    await PreferencesService.setPreferensiDasar(
      mataUang: _mataUang,
      bahasa: _bahasa,
    );
    // Terapkan langsung (harga & locale) tanpa perlu buka aplikasi ulang.
    PreferencesService.mataUang.value = _mataUang;
    PreferencesService.bahasa.value = _bahasa;
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
                  items: PreferencesService.daftarMataUang
                      .map(
                        (kode) => DropdownMenuItem(
                          value: kode,
                          child: Text(_labelMataUang(kode)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _mataUang = v ?? _mataUang),
                ),
                const SizedBox(height: 32),
                const _PreferensiLabel(teks: 'Pilihan Bahasa'),
                DropdownButtonFormField<String>(
                  initialValue: _bahasa,
                  decoration: _dekorasiDropdown(),
                  items: PreferencesService.daftarBahasa
                      .map(
                        (kode) => DropdownMenuItem(
                          value: kode,
                          child: Text(_labelBahasa(kode)),
                        ),
                      )
                      .toList(),
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

/// Label pilihan mata uang (tambah di sini bila mata uang baru didukung).
String _labelMataUang(String kode) => switch (kode) {
  'IDR' => 'IDR - Rupiah Indonesia (Rp)',
  _ => kode,
};

/// Label pilihan bahasa.
String _labelBahasa(String kode) => switch (kode) {
  'id' => 'Indonesia',
  'en' => 'English',
  _ => kode,
};

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
