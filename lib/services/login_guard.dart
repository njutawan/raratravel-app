import 'package:shared_preferences/shared_preferences.dart';

/// Status rate-limit satu identitas (nomor HP / 'google').
class GuardStatus {
  final int salah;
  final DateTime? terkunciSampai;
  final bool wajibBaru;

  const GuardStatus({
    required this.salah,
    this.terkunciSampai,
    required this.wajibBaru,
  });

  /// Masih dalam masa kunci?
  bool get terkunci =>
      terkunciSampai != null && DateTime.now().isBefore(terkunciSampai!);

  /// Sisa percobaan sebelum dikunci.
  int get sisa => (LoginGuard.maxSalah - salah).clamp(0, LoginGuard.maxSalah);
}

/// Penjaga brute-force login: 3x gagal → kunci 5 menit + wajib kode baru.
///
/// Tersimpan di HP (persisten walau aplikasi ditutup), dihitung per nomor HP
/// (OTP) atau 'google' (login Google). Pertahanan lapis pertama; Firebase
/// tetap throttling di server (`too-many-requests`).
class LoginGuard {
  static const maxSalah = 3;
  static const durasiKunci = Duration(minutes: 5);
  static const _prefix = 'rara_guard_v1_';

  static String _k(String id, String f) => '$_prefix${id}_$f';

  /// Baca status + bersihkan kunci yang sudah kedaluwarsa.
  static Future<GuardStatus> status(String id) async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_k(id, 'kunci')) ?? 0;
    DateTime? sampai = ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    var salah = p.getInt(_k(id, 'salah')) ?? 0;
    if (sampai != null && !DateTime.now().isBefore(sampai)) {
      // Kunci habis → nolkan hitungan (wajibBaru tetap sampai kode baru diminta).
      sampai = null;
      salah = 0;
      await p.remove(_k(id, 'kunci'));
      await p.setInt(_k(id, 'salah'), 0);
    }
    return GuardStatus(
      salah: salah,
      terkunciSampai: sampai,
      wajibBaru: p.getBool(_k(id, 'baru')) ?? false,
    );
  }

  /// Catat 1x gagal. Capai batas → kunci + wajib kode baru.
  static Future<GuardStatus> catatGagal(String id) async {
    final p = await SharedPreferences.getInstance();
    final salah = (p.getInt(_k(id, 'salah')) ?? 0) + 1;
    await p.setInt(_k(id, 'salah'), salah);
    DateTime? sampai;
    if (salah >= maxSalah) {
      sampai = DateTime.now().add(durasiKunci);
      await p.setInt(_k(id, 'kunci'), sampai.millisecondsSinceEpoch);
      await p.setBool(_k(id, 'baru'), true);
    }
    return GuardStatus(
      salah: salah,
      terkunciSampai: sampai,
      wajibBaru: salah >= maxSalah,
    );
  }

  /// Login sukses → hapus semua catatan.
  static Future<void> catatSukses(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_k(id, 'salah'));
    await p.remove(_k(id, 'kunci'));
    await p.remove(_k(id, 'baru'));
  }

  /// Tandai wajib/tidak kode baru (dipakai setelah kirim ulang OTP).
  static Future<void> setWajibBaru(String id, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_k(id, 'baru'), v);
  }
}
