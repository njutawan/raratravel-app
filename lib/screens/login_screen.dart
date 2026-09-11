import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/login_guard.dart';

/// Login/daftar via kode OTP SMS.
/// Berhasil → kembali dengan nilai true (Navigator.pop(context, true)).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  int _step = 0; // 0 = nomor HP, 1 = kode OTP
  bool _loading = false;
  String? _error;
  String? _verificationId;
  int? _resendToken;
  int _cooldown = 0;
  Timer? _timer;
  // --- Rate limit brute-force: 3x salah -> kunci 5 mnt + wajib kode baru ---
  int _sisa = LoginGuard.maxSalah;
  DateTime? _terkunciSampai;
  bool _wajibKodeBaru = false;
  Timer? _timerKunci;

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    _timer?.cancel();
    _timerKunci?.cancel();
    super.dispose();
  }

  void _startCooldown([int seconds = 60]) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  /// Nomor valid (format +62...) atau null.
  String? get _phoneIntl {
    final digits = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 9) return null;
    return AuthService.normalizePhone(_phone.text.trim());
  }

  /// Muat status rate-limit nomor ini + jalankan hitung mundur bila terkunci.
  Future<void> _muatGuard() async {
    final phone = _phoneIntl;
    if (phone == null) return;
    final st = await LoginGuard.status('otp_$phone');
    if (!mounted) return;
    setState(() {
      _sisa = st.sisa;
      _terkunciSampai = st.terkunciSampai;
      _wajibKodeBaru = st.wajibBaru;
    });
    _jalanKunci();
  }

  /// Hitung mundur kunci; saat habis, buka + wajib minta kode baru.
  void _jalanKunci() {
    _timerKunci?.cancel();
    if (_terkunciSampai == null) return;
    _timerKunci = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (DateTime.now().isAfter(_terkunciSampai!)) {
        t.cancel();
        setState(() {
          _terkunciSampai = null;
          _sisa = LoginGuard.maxSalah;
          _wajibKodeBaru = true; // kunci habis -> wajib kode baru
        });
      } else {
        setState(() {});
      }
    });
  }

  String get _sisaKunci {
    final s = _terkunciSampai;
    if (s == null) return '';
    final d = s.difference(DateTime.now());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  bool get _terkunci =>
      _terkunciSampai != null && DateTime.now().isBefore(_terkunciSampai!);

  Future<void> _kirimOtp({bool ulang = false}) async {
    final phone = _phoneIntl;
    if (phone == null) {
      setState(() => _error = 'Isi nomor HP yang valid (cth. 0812...)');
      return;
    }
    // Nomor terkunci -> tolak kirim, tampilkan hitung mundur.
    final g = await LoginGuard.status('otp_$phone');
    if (g.terkunci) {
      if (!mounted) return;
      setState(() {
        _sisa = g.sisa;
        _terkunciSampai = g.terkunciSampai;
        _wajibKodeBaru = g.wajibBaru;
        _error =
            'Terkunci sementara demi keamanan. Coba lagi dalam $_sisaKunci.';
      });
      _jalanKunci();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await AuthService.sendOtp(
      phone: phone,
      forceResendingToken: ulang ? _resendToken : null,
      onCodeSent: (vid, token) async {
        if (!mounted) return;
        setState(() {
          _verificationId = vid;
          _resendToken = token;
          _step = 1;
          _loading = false;
        });
        _otp.clear();
        // Kode baru -> gugurkan kewajiban (hitungan salah tetap, anti-bypass).
        final phone = _phoneIntl;
        if (phone != null) {
          await LoginGuard.setWajibBaru('otp_$phone', false);
        }
        await _muatGuard();
        _startCooldown();
      },
      onAutoVerified: (cred) => _onSignedIn(cred.user),
      onError: (msg) {
        if (mounted) setState(() => _error = msg);
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  Future<void> _verifikasi() async {
    if ((_verificationId ?? '').isEmpty) return;
    if (_terkunci) {
      setState(
        () => _error = 'Terkunci sementara. Coba lagi dalam $_sisaKunci.',
      );
      return;
    }
    if (_wajibKodeBaru) {
      setState(
        () =>
            _error = 'Demi keamanan, tekan "Kirim ulang kode" untuk kode baru.',
      );
      return;
    }
    if (_otp.text.trim().length < 6) {
      setState(() => _error = 'Kode OTP 6 digit. Cek SMS kamu.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = await AuthService.verifyOtp(
        verificationId: _verificationId!,
        smsCode: _otp.text,
      );
      await _onSignedIn(cred.user);
    } catch (e) {
      // Hanya KODE SALAH yang dihitung; error lain (sesi/jaringan) tidak.
      if (e is FirebaseAuthException && e.code == 'invalid-verification-code') {
        final phone = _phoneIntl;
        if (phone != null) {
          final st = await LoginGuard.catatGagal('otp_$phone');
          if (!mounted) return;
          setState(() {
            _sisa = st.sisa;
            _terkunciSampai = st.terkunciSampai;
            _wajibKodeBaru = st.wajibBaru;
          });
          _jalanKunci();
          if (st.terkunci) {
            setState(() {
              _error =
                  '3x salah — dikunci 5 menit. Setelah itu wajib minta kode baru.';
              _loading = false;
            });
            return;
          }
        }
        if (mounted) {
          setState(() {
            _error = 'Kode OTP salah. Sisa $_sisa percobaan.';
            _loading = false;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _error = AuthService.friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  /// Selesai login: profil + migrasi + FCM, lalu kembali sukses.
  Future<void> _onSignedIn(User? user) async {
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Sukses -> hapus catatan gagal nomor ini.
    final phone = _phoneIntl;
    if (phone != null) await LoginGuard.catatSukses('otp_$phone');
    await AuthService.completeSignIn(user);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Masuk / Daftar')),
      body: !FirebaseBootstrap.ready
          ? _buildOffline()
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/icon/app_logo.png',
                      width: 84,
                      height: 84,
                      cacheWidth: 252,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _step == 0 ? 'Masuk dengan nomor HP' : 'Masukkan kode OTP',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _step == 0
                      ? 'Kode verifikasi dikirim via SMS. Gratis daftar.'
                      : 'Kode 6 digit dikirim ke ${_phoneIntl ?? ''} via SMS.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 20),
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.red.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_step == 0) ...[
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Nomor HP / WhatsApp *',
                      hintText: 'cth. 081225093894',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    onSubmitted: (_) => _kirimOtp(),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : () => _kirimOtp(),
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Kirim Kode OTP'),
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: _otp,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 10,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Kode OTP 6 digit',
                      hintText: '••••••',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _verifikasi(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _terkunci
                        ? 'Terkunci sementara — coba lagi dalam $_sisaKunci'
                        : _wajibKodeBaru
                        ? 'Wajib minta kode baru (tekan Kirim ulang kode)'
                        : 'Sisa $_sisa percobaan sebelum dikunci sementara',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: (_terkunci || _wajibKodeBaru || _sisa <= 1)
                          ? Colors.red.shade700
                          : Colors.grey.shade600,
                      fontWeight: (_terkunci || _wajibKodeBaru)
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading || _terkunci || _wajibKodeBaru
                          ? null
                          : _verifikasi,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _terkunci
                                  ? 'Terkunci ($_sisaKunci)'
                                  : 'Verifikasi & Masuk',
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: _loading || _cooldown > 0 || _terkunci
                            ? null
                            : () => _kirimOtp(ulang: true),
                        child: Text(
                          _cooldown > 0
                              ? 'Kirim ulang ($_cooldown dtk)'
                              : 'Kirim ulang kode',
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _loading
                            ? null
                            : () => setState(() => _step = 0),
                        child: const Text('Ganti nomor'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Dengan masuk, pesananmu tersimpan aman di akun dan terlihat admin secara real-time.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }

  /// Tampilan bila Firebase belum dikonfigurasi.
  Widget _buildOffline() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 64,
              color: Colors.grey.shade600,
            ),
            const SizedBox(height: 12),
            const Text(
              'Login belum tersedia',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Firebase belum dikonfigurasi, jadi aplikasi berjalan mode offline.\n\nIkuti PANDUAN_FIREBASE.md (langkah 1–2), lalu jalankan ulang aplikasi.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
