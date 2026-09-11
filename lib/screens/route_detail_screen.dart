import 'package:flutter/material.dart';
import '../models/travel_route.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';
import 'booking_screen.dart';

/// Detail rute: jadwal, armada, fasilitas, deskripsi + tombol pesan.
class RouteDetailScreen extends StatefulWidget {
  final TravelRoute route;
  final DateTime tanggal;

  const RouteDetailScreen({
    super.key,
    required this.route,
    required this.tanggal,
  });

  @override
  State<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

class _RouteDetailScreenState extends State<RouteDetailScreen> {
  late String _jam;
  late DateTime _tanggal;

  @override
  void initState() {
    super.initState();
    _jam = widget.route.jadwal.first;
    _tanggal = widget.tanggal;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _tanggal,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    );
    if (picked != null) setState(() => _tanggal = picked);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    return Scaffold(
      appBar: AppBar(title: Text(r.title)),
      body: ListView(
        padding: Adaptive.pagePadding(context, maxWidth: 1000),
        children: [
          if (Adaptive.isWide(context))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _kolomKiri(r)),
                const SizedBox(width: 16),
                Expanded(child: _kolomKanan(r)),
              ],
            )
          else ...[
            _kolomKiri(r),
            _kolomKanan(r),
          ],
          const SizedBox(height: 90),
        ],
      ),
      bottomSheet: Container(
        padding: EdgeInsets.fromLTRB(
          Adaptive.hPad(context, maxWidth: 1000),
          12,
          Adaptive.hPad(context, maxWidth: 1000),
          20,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total mulai',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  Text(
                    Formatters.idr(r.harga),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton.outlined(
              onPressed: () => ExternalService.openWhatsApp(
                'Halo *Rara Travel & Tour*, saya mau tanya rute ${r.asal} → ${r.tujuan} (${Formatters.fullDate(_tanggal)}, jam $_jam).',
              ),
              icon: const Icon(Icons.chat_outlined),
              tooltip: 'Tanya Admin via WA',
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        BookingScreen(route: r, tanggal: _tanggal, jam: _jam),
                  ),
                ),
                child: const Text('Pesan Sekarang'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Kolom kiri detail (ringkasan + jam + armada).
  /// Di HP tampil berurutan; di tablet berdampingan dengan [_kolomKanan].
  Widget _kolomKiri(TravelRoute r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Ringkasan rute
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    _KotaBox(kota: r.asal, sub: 'Keberangkatan'),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          children: [
                            Icon(Icons.more_horiz, color: Colors.grey),
                            Text(
                              'langsung',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF757575),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _KotaBox(kota: r.tujuan, sub: 'Kedatangan'),
                  ],
                ),
                const Divider(height: 24),
                InfoRow(label: 'Durasi', value: '${r.durasi} ${r.via}'),
                InfoRow(
                  label: 'Harga/kursi',
                  value: Formatters.idr(r.harga),
                  boldValue: true,
                ),
                InfoRow(label: 'Tanggal', value: Formatters.fullDate(_tanggal)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.edit_calendar, size: 18),
                    label: const Text('Ubah tanggal'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Fakta layanan (penguat keputusan sebelum pesan)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in [
              (Icons.door_front_door_outlined, 'Gratis jemput-antar'),
              (Icons.verified_user_outlined, 'Asuransi perjalanan'),
              (Icons.workspace_premium_outlined, 'Driver profesional'),
            ])
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(f.$1, size: 15, color: Colors.blue.shade800),
                    const SizedBox(width: 5),
                    Text(
                      f.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // Pilih jam
        const Text(
          'Pilih Jam Keberangkatan',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: r.jadwal.map((j) {
            final selected = j == _jam;
            return ChoiceChip(
              label: Text('$j WIB'),
              selected: selected,
              onSelected: (_) => setState(() => _jam = j),
              materialTapTargetSize: MaterialTapTargetSize.padded,
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Armada
        const Text(
          'Armada',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: r.armada
                .map(
                  (a) => ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.directions_car,
                      color: AppTheme.primary,
                    ),
                    title: Text(a, style: const TextStyle(fontSize: 14)),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// Kolom kanan detail (fasilitas + deskripsi).
  Widget _kolomKanan(TravelRoute r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Fasilitas
        const Text(
          'Fasilitas',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: r.fasilitas
                .map(
                  (f) => ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 20,
                    ),
                    title: Text(f, style: const TextStyle(fontSize: 14)),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 16),

        // Deskripsi
        const Text(
          'Tentang Rute Ini',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              r.deskripsi,
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _KotaBox extends StatelessWidget {
  final String kota;
  final String sub;
  const _KotaBox({required this.kota, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              kota,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
