import 'package:flutter/material.dart';

/// Utilitas adaptif tablet/foldable.
///
/// Breakpoint mengikuti Material 3: layar dinyatakan "lebar" mulai 600dp
/// (tablet 7"+ / foldable terbentang). Semua layar membaca ini di [build]
/// sehingga otomatis menyesuaikan saat rotasi / foldable dilipat-bentang.
class Adaptive {
  /// True di tablet / foldable terbentang / desktop.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 600;

  /// Padding horizontal adaptif: [min] di HP; di layar lebar dilebarkan
  /// simetris sehingga konten selebar [maxWidth] dan rata tengah.
  /// Aman dipakai di padding ListView/GridView (tak merusak constraints).
  static double hPad(
    BuildContext context, {
    double maxWidth = 680,
    double min = 16,
  }) {
    final w = MediaQuery.sizeOf(context).width;
    final p = (w - maxWidth) / 2;
    return p < min ? min : p;
  }

  /// Pengganti `EdgeInsets.all(n)`: vertikal tetap, horizontal adaptif.
  static EdgeInsets pagePadding(
    BuildContext context, {
    double maxWidth = 680,
    double vertical = 16,
    double min = 16,
  }) {
    return EdgeInsets.symmetric(
      horizontal: hPad(context, maxWidth: maxWidth, min: min),
      vertical: vertical,
    );
  }
}
