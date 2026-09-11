import 'dart:async';

import 'package:flutter/material.dart';
import '../app.dart';
import '../services/auth_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/login_guard.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import 'login_screen.dart';

/// Layar login wajib ala Traveloka: 3 slide otomatis (progress ala story),
/// kartu brand, tombol "Lanjut dengan Google" + "Metode lain" (OTP).
///
/// [replaceToHome] = true bila layar ini root (dari splash/onboarding):
/// sukses login langsung mengganti halaman ke beranda. Bila false (dibuka
/// dari tab/akun/booking): kembali dengan nilai true.
class LoginCarouselScreen extends StatefulWidget {
  final bool replaceToHome;
  const LoginCarouselScreen({super.key, this.replaceToHome = false});

  @override
  State<LoginCarouselScreen> createState() => _LoginCarouselScreenState();
}

class _LoginCarouselScreenState extends State<LoginCarouselScreen>
    with SingleTickerProviderStateMixin {
  final _page = PageController();
  late final AnimationController _progress;
  int _index = 0;
  bool _busy = false;
  // Rate limit tombol Google: 3x gagal -> kunci 5 menit.
  DateTime? _googleKunci;
  Timer? _googleTimer;

  static const _slides = [
    _Slide(
      image: 'assets/images/login_slide_1.jpg',
      title: 'Satu App Untuk Seluruh Perjalanan',
      desc:
          'Dari Travel Antar Kota, Sewa Mobil, sampai Paket Wisata, pesan semuanya dengan mudah di Rara Travel.',
    ),
    _Slide(
      image: 'assets/images/login_slide_2.jpg',
      title: 'Diskon Pengguna Baru',
      desc:
          'Pakai kuponnya buat pemesanan pertamamu dan wujudkan perjalanan impianmu dengan lebih hemat!',
      badge: _Badge.coupon,
    ),
    _Slide(
      image: 'assets/images/login_slide_3.jpg',
      title: 'Pesan Apapun Jadi Lebih Pede',
      desc:
          'Ubah rencana dan pembayaran tanpa ribet, dengan pilihan fleksibel di Rara Travel.',
      badge: _Badge.checklist,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _progress =
        AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed && mounted) {
              _page.animateToPage(
                (_index + 1) % _slides.length,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
              );
            }
          })
          ..forward();
    // Pulihkan status kunci Google bila aplikasi sempat ditutup.
    LoginGuard.status('google').then((st) {
      if (!mounted || !st.terkunci) return;
      setState(() => _googleKunci = st.terkunciSampai);
      _jalanGoogleKunci();
    });
  }

  var _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pre-cache semua slide sekali → transisi tanpa kedip/pop-in gambar.
    if (!_precached) {
      _precached = true;
      for (final s in _slides) {
        precacheImage(AssetImage(s.image), context);
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _page.dispose();
    _googleTimer?.cancel();
    super.dispose();
  }

  void _onPage(int i) {
    setState(() => _index = i);
    _progress.forward(from: 0);
  }

  /// Tap kiri/kanan layar untuk pindah slide (ala story).
  void _tapZone(TapUpDetails d) {
    final w = MediaQuery.of(context).size.width;
    final x = d.globalPosition.dx;
    if (x < w * 0.35 && _index > 0) {
      _page.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (x > w * 0.65) {
      _page.animateToPage(
        (_index + 1) % _slides.length,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _google() async {
    if (!FirebaseBootstrap.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mode offline: selesaikan PANDUAN_FIREBASE.md dulu.'),
        ),
      );
      return;
    }
    // Rate limit: 3x gagal -> kunci 5 menit.
    final g = await LoginGuard.status('google');
    if (g.terkunci) {
      if (!mounted) return;
      setState(() => _googleKunci = g.terkunciSampai);
      _jalanGoogleKunci();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Terkunci sementara. Coba lagi dalam $_googleSisa.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final cred = await AuthService.signInWithGoogle();
      if (cred?.user == null) {
        if (mounted) setState(() => _busy = false);
        return; // dibatalkan pengguna
      }
      await AuthService.completeSignIn(cred!.user!);
      await LoginGuard.catatSukses('google');
      if (!mounted) return;
      _finish();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.toString().contains('network_error')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak ada koneksi internet.')),
        );
        return; // gangguan jaringan bukan percobaan brute-force
      }
      final st = await LoginGuard.catatGagal('google');
      if (!mounted) return;
      if (st.terkunci) {
        setState(() => _googleKunci = st.terkunciSampai);
        _jalanGoogleKunci();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('3x gagal — tombol dikunci 5 menit.')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AuthService.friendlyError(e)} (sisa ${st.sisa}x)'),
        ),
      );
    }
  }

  bool get _googleTerkunci =>
      _googleKunci != null && DateTime.now().isBefore(_googleKunci!);

  String get _googleSisa {
    final s = _googleKunci;
    if (s == null) return '';
    final d = s.difference(DateTime.now());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  /// Hitung mundur kunci tombol Google.
  void _jalanGoogleKunci() {
    _googleTimer?.cancel();
    if (_googleKunci == null) return;
    _googleTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (DateTime.now().isAfter(_googleKunci!)) {
        t.cancel();
        setState(() => _googleKunci = null);
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _metodeLain() async {
    final ok = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen()));
    if (ok == true && mounted) _finish();
  }

  void _finish() {
    if (widget.replaceToHome) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainNav()),
        (_) => false,
      );
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                GestureDetector(
                  onTapUp: _tapZone,
                  child: PageView.builder(
                    controller: _page,
                    onPageChanged: _onPage,
                    itemCount: _slides.length,
                    itemBuilder: (_, i) => _SlideView(slide: _slides[i]),
                  ),
                ),
                // Progress bar ala story
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 13,
                  right: 13,
                  child: Row(
                    children: List.generate(_slides.length, (i) {
                      if (i < _index) return Expanded(child: _bar(1));
                      if (i == _index) {
                        return Expanded(
                          child: AnimatedBuilder(
                            animation: _progress,
                            builder: (_, __) => _bar(_progress.value),
                          ),
                        );
                      }
                      return Expanded(child: _bar(0));
                    }),
                  ),
                ),
              ],
            ),
          ),
          // Lembar bawah: judul + tombol masuk
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      _slides[_index].title,
                      key: ValueKey(_index),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        side: BorderSide(color: Colors.grey.shade400),
                        foregroundColor: Colors.black87,
                      ),
                      onPressed: _busy || _googleTerkunci ? null : _google,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CustomPaint(
                                  size: const Size(22, 22),
                                  painter: _GLogoPainter(),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _googleTerkunci
                                      ? 'Terkunci ($_googleSisa)'
                                      : 'Lanjut dengan Google',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _metodeLain,
                    child: const Text('Metode lain'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Satu segmen progress (0.0 – 1.0).
  Widget _bar(double fraction) {
    return Container(
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: fraction.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

enum _Badge { none, coupon, checklist }

class _Slide {
  final String image;
  final String title;
  final String desc;
  final _Badge badge;
  const _Slide({
    required this.image,
    required this.title,
    required this.desc,
    this.badge = _Badge.none,
  });
}

/// Satu slide: foto latar + badge overlay + kartu brand.
class _SlideView extends StatelessWidget {
  final _Slide slide;
  const _SlideView({required this.slide});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(slide.image, fit: BoxFit.cover, cacheWidth: 1200),
        if (slide.badge == _Badge.coupon)
          const Positioned(
            top: 96,
            left: 0,
            right: 0,
            child: Center(child: _CouponPill()),
          ),
        if (slide.badge == _Badge.checklist)
          const Positioned(
            top: 96,
            left: 40,
            right: 40,
            child: _ChecklistPill(),
          ),
        Positioned(
          left: 28,
          right: 28,
          bottom: 18,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 28),
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: AppTheme.cardShadow,
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/icon/app_logo.png',
                        width: 40,
                        height: 40,
                        cacheWidth: 120,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'raratravel.id',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  slide.desc,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Pil kupon (slide 2) — kode diambil dari AppConstants (diskon beneran).
class _CouponPill extends StatelessWidget {
  const _CouponPill();

  @override
  Widget build(BuildContext context) {
    final kode = AppConstants.promoCodes.keys.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Kode\nkupon',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 13,
              height: 1.2,
            ),
          ),
          Container(
            width: 2,
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: AppTheme.primary,
          ),
          Text(
            kode,
            style: const TextStyle(
              color: AppTheme.primary,
              fontWeight: FontWeight.w900,
              fontSize: 22,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pil checklist keunggulan (slide 3).
class _ChecklistPill extends StatelessWidget {
  const _ChecklistPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CheckRow('Refund fleksibel'),
          _CheckRow('Reschedule mudah'),
          _CheckRow('Berbagai pilihan pembayaran'),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String text;
  const _CheckRow(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

/// Logo "G" Google empat warna, digambar manual (tanpa asset).
class _GLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final stroke = size.width * 0.22;
    Paint seg(Color col) => Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    final rect = Rect.fromCircle(center: c, radius: r - stroke / 2);
    // Merah (atas), kuning (kanan-bawah), hijau (bawah-kiri), biru (kiri).
    canvas.drawArc(rect, -1.5, 1.25, false, seg(const Color(0xFFEA4335)));
    canvas.drawArc(rect, 0.35, 1.1, false, seg(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 1.45, 1.25, false, seg(const Color(0xFF34A853)));
    canvas.drawArc(rect, 2.7, 2.08, false, seg(const Color(0xFF4285F4)));
    // Bilah biru ke tengah.
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(c.dx + r * 0.3, c.dy),
        width: r * 0.95,
        height: r * 0.42,
      ),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
