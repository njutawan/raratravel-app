/// Pemetaan status pesanan antara server (kode) dan tampilan (bahasa Indonesia).
///
/// Server menyimpan kode: pending / confirmed / completed / cancelled / expired.
/// Aplikasi menampilkan label: "Menunggu Konfirmasi", dst — sama seperti data
/// lama di Firestore/HP, sehingga riwayat lama tetap tampil benar.
class BookingStatus {
  static const pending = 'pending';
  static const confirmed = 'confirmed';
  static const completed = 'completed';
  static const cancelled = 'cancelled';
  static const expired = 'expired';

  /// Kode server → label tampilan.
  static String label(String? code) {
    switch ((code ?? '').toLowerCase()) {
      case pending:
        return 'Menunggu Konfirmasi';
      case confirmed:
        return 'Dikonfirmasi';
      case completed:
        return 'Selesai';
      case cancelled:
        return 'Dibatalkan';
      case expired:
        return 'Kedaluwarsa';
      default:
        return code == null || code.isEmpty ? 'Menunggu Konfirmasi' : code;
    }
  }

  /// Label lama / kiriman bebas → kode server (kompatibel data Firestore).
  static String code(String? label) {
    switch ((label ?? '').toLowerCase().trim()) {
      case 'pending':
      case 'menunggu konfirmasi':
      case 'menunggu':
      case 'baru':
        return pending;
      case 'confirmed':
      case 'dikonfirmasi':
      case 'terkonfirmasi':
      case 'lunas':
      case 'paid':
        return confirmed;
      case 'completed':
      case 'selesai':
        return completed;
      case 'cancelled':
      case 'canceled':
      case 'dibatalkan':
      case 'batal':
        return cancelled;
      case 'expired':
      case 'kedaluwarsa':
      case 'hangus':
        return expired;
      default:
        return pending;
    }
  }

  /// Pesanan yang masih berjalan (belum selesai/dibatalkan).
  static bool isActive(String? code) {
    final value = BookingStatus.code(code);
    return value == pending || value == confirmed;
  }

  /// Warna badge di UI: hijau (jalan), biru (selesai), merah (batal).
  static bool isSuccess(String? code) {
    final value = BookingStatus.code(code);
    return value == confirmed || value == completed;
  }

  static bool isFailure(String? code) {
    final value = BookingStatus.code(code);
    return value == cancelled || value == expired;
  }
}
