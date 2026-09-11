import 'package:flutter/material.dart';
import '../data/dummy_data.dart';
import '../models/wisata_paket.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';

/// Layar paket wisata (open trip / private trip).
class WisataScreen extends StatelessWidget {
  const WisataScreen({super.key});

  void _pesan(WisataPaket p) {
    final msg = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya tertarik paket wisata:')
      ..writeln('')
      ..writeln('Paket: *${p.nama}*')
      ..writeln('Lokasi: ${p.lokasi}')
      ..writeln('Tipe: ${p.tipe} • ${p.durasi}')
      ..writeln('Harga: ${Formatters.idr(p.harga)}/pax')
      ..writeln('')
      ..writeln('Tanggal rencana: ...')
      ..writeln('Jumlah peserta: ... orang')
      ..writeln('Meeting point: ...')
      ..writeln('')
      ..writeln(
        'Mohon info jadwal terdekat & ketersediaan seat. Terima kasih.',
      );
    ExternalService.openWhatsApp(msg.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paket Wisata')),
      body: ListView.separated(
        padding: Adaptive.pagePadding(context, vertical: 14, min: 14),
        itemCount: DummyData.wisata.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final p = DummyData.wisata[i];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: p.tipe == 'Open Trip'
                              ? Colors.green.shade100
                              : Colors.purple.shade100,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          p.tipe,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: p.tipe == 'Open Trip'
                                ? Colors.green.shade800
                                : Colors.purple.shade800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.durasi,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p.nama,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                  Text(
                    p.lokasi,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p.deskripsi,
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Highlight:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  ...p.highlight.map(
                    (h) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.place,
                            size: 16,
                            color: AppTheme.accentDark,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              h,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sudah termasuk:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  ...p.include.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            size: 16,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              f,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 20),
                  Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Mulai dari',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          Text(
                            Formatters.idr(p.harga),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primary,
                            ),
                          ),
                          Text(
                            '/pax',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => _pesan(p),
                        child: const Text('Tanya & Pesan'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
