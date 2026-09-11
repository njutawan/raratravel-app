import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app.dart';
import '../data/dummy_data.dart';
import '../models/booking.dart';
import '../models/travel_route.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';
import 'booking_screen.dart';
import 'orders_screen.dart';
import 'rental_screen.dart';
import 'wisata_screen.dart';

/// Layar sukses setelah booking dibuat: tampilkan tiket + CTA konfirmasi WA.
class CheckoutSuccessScreen extends StatelessWidget {
  final Booking booking;
  const CheckoutSuccessScreen({super.key, required this.booking});

  void _copyKode(BuildContext context) {
    Clipboard.setData(ClipboardData(text: booking.kode));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Kode booking disalin')));
  }

  /// Cari rute kebalikan di katalog & buka form booking-nya.
  void _pesanPulangPergi(BuildContext context) {
    final cocok = DummyData.routes.where(
      (r) => r.asal == booking.tujuan && r.tujuan == booking.asal,
    );
    if (cocok.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rute pulang belum tersedia — chat admin ya!'),
        ),
      );
      ExternalService.openWhatsApp(
        'Halo *Rara Travel & Tour*, saya butuh rute ${booking.tujuan} → ${booking.asal}.',
      );
      return;
    }
    final TravelRoute pulang = cocok.first;
    final tgl = DateTime.tryParse(booking.tanggal) ?? DateTime.now();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookingScreen(
          route: pulang,
          tanggal: tgl.add(const Duration(days: 1)),
          jam: pulang.jadwal.first,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = booking;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pesanan Berhasil'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: Adaptive.pagePadding(context),
        children: [
          const SizedBox(height: 8),
          const Icon(Icons.check_circle, color: Colors.green, size: 84),
          const SizedBox(height: 12),
          const Text(
            'Pesanan kamu tercatat!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Langkah terakhir: konfirmasi ke admin via WhatsApp agar kursi langsung diamankan.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          const SizedBox(height: 16),

          // Tiket
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'KODE BOOKING',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                letterSpacing: 1,
                              ),
                            ),
                            Text(
                              b.kode,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton.outlined(
                        onPressed: () => _copyKode(context),
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Salin kode',
                      ),
                      const SizedBox(width: 4),
                      StatusBadge(status: b.status),
                    ],
                  ),
                  const Divider(height: 24),
                  InfoRow(
                    label: 'Rute',
                    value: '${b.asal} → ${b.tujuan}',
                    boldValue: true,
                  ),
                  InfoRow(
                    label: 'Berangkat',
                    value: '${b.tanggalDisplay} • ${b.jam} WIB',
                  ),
                  InfoRow(label: 'Nama', value: b.nama),
                  InfoRow(label: 'No. WA', value: b.wa),
                  InfoRow(label: 'Jemput', value: b.jemput),
                  InfoRow(label: 'Antar', value: b.antar),
                  InfoRow(label: 'Kursi', value: '${b.kursi} kursi'),
                  InfoRow(label: 'Pembayaran', value: b.metodeBayar),
                  if (b.catatan.isNotEmpty)
                    InfoRow(label: 'Catatan', value: b.catatan),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        Formatters.idr(b.totalHarga),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.waGreen),
              onPressed: () =>
                  ExternalService.openWhatsApp(b.toWhatsAppMessage()),
              icon: const Icon(Icons.chat),
              label: const Text('Konfirmasi via WhatsApp'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _pesanPulangPergi(context),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Pesan Pulang-Pergi'),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OrdersScreen()),
                  ),
                  child: const Text('Lihat Pesananku'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const MainNav()),
                    (route) => false,
                  ),
                  child: const Text('Ke Beranda'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Cross-sell: layanan lain yang relevan
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Butuh armada sendiri atau liburan sekalian?',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RentalScreen(),
                            ),
                          ),
                          icon: const Icon(Icons.key_outlined, size: 18),
                          label: const Text('Sewa Mobil'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WisataScreen(),
                            ),
                          ),
                          icon: const Icon(Icons.landscape_outlined, size: 18),
                          label: const Text('Paket Wisata'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
