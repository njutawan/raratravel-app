/// Aturan keputusan tombol "Hapus Akun".
///
/// Dipisah dari [AuthService] supaya bisa diuji tanpa Firebase/Supabase:
/// inilah aturan yang mencegah aplikasi menjanjikan "data dihapus permanen"
/// padahal data server masih tersimpan (temuan H-3).
class HapusAkun {
  const HapusAkun._();

  /// Boleh lanjut menghapus akun Firebase?
  ///
  /// Jawabannya **hanya** "ya" bila server memastikan data pribadi sudah tidak
  /// ada:
  ///   * `deleted: true`      → data pengguna baru saja dihapus server, atau
  ///   * `reason: user_not_found` → memang tidak ada data untuk dihapus
  ///     (pengguna belum pernah tersinkron / sudah pernah dihapus).
  ///
  /// Jawaban lain (mis. galat jaringan, `purge` belum jalan) berarti data
  /// masih ada → jangan hapus akun, agar pengguna tidak kehilangan kontrol
  /// atas sisa datanya.
  static bool bolehLanjut(Map<String, dynamic>? hasil) {
    if (hasil == null) return false;
    if (hasil['deleted'] == true) return true;
    return hasil['reason'] == 'user_not_found';
  }

  /// Pesan siap tampil bila [bolehLanjut] bernilai false.
  static const String pesanGagal =
      'Data akun belum berhasil dihapus dari server. Coba lagi sebentar lagi.';
}
