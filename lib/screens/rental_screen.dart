import 'package:flutter/material.dart';
import '../data/dummy_data.dart';
import '../models/armada.dart';
import '../repositories/catalog_repository.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';

/// Layar sewa mobil + sopir / lepas kunci.
class RentalScreen extends StatefulWidget {
  const RentalScreen({super.key});

  @override
  State<RentalScreen> createState() => _RentalScreenState();
}

class _RentalScreenState extends State<RentalScreen> {
  List<Armada> _armada = DummyData.armada;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _muatData();
  }

  Future<void> _muatData() async {
    if (!CatalogRepository.enabled) return;
    setState(() => _loading = true);
    try {
      final list = await CatalogRepository.rentals();
      if (!mounted) return;
      if (list.isNotEmpty) {
        setState(() => _armada = list);
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _handleRefresh() async {
    CatalogRepository.clearCache();
    await _muatData();
  }

  void _sewa(BuildContext context, Armada a, bool lepasKunci) {
    final harga = lepasKunci ? a.hargaLepasKunci : a.hargaSewa;
    final msg = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya mau sewa mobil:')
      ..writeln('')
      ..writeln('Mobil: *${a.nama}* (${a.tipe})')
      ..writeln(
        'Sistem: ${lepasKunci ? 'Lepas Kunci' : 'Dengan Sopir (include BBM? tanya admin)'}',
      )
      ..writeln('Estimasi: ${Formatters.idr(harga)}/hari')
      ..writeln('')
      ..writeln('Tanggal pakai: ...')
      ..writeln('Durasi: ... hari')
      ..writeln('Rute/rencana perjalanan: ...')
      ..writeln('')
      ..writeln('Mohon info ketersediaan & syaratnya. Terima kasih.');
    ExternalService.openWhatsApp(msg.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sewa Mobil')),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: Adaptive.pagePadding(context, vertical: 14, min: 14),
          children: [
            Card(
              color: Colors.blue.shade50,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Harga sewa harian (12 jam). Dengan sopir sudah termasuk jasa driver. Lepas kunci wajib KTP + deposit.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading) const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 3),
            ),
            const SizedBox(height: 10),
            ..._armada.map(
              (a) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              a.tipe == 'Van' || a.tipe == 'Minibus'
                                  ? Icons.airport_shuttle
                                  : Icons.directions_car,
                              color: AppTheme.primary,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.nama,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  '${a.tipe} • Muat ${a.kapasitas} orang',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (a.deskripsi.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          a.deskripsi,
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (a.fitur.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          children: a.fitur
                              .map(
                                (f) => Chip(
                                  label: Text(
                                    f,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              )
                              .toList(),
                        ),
                      ],
                      const Divider(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '+ Sopir',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                                Text(
                                  '${Formatters.idr(a.hargaSewa)}/hari',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (a.hargaLepasKunci > 0)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Lepas kunci',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                  Text(
                                    '${Formatters.idr(a.hargaLepasKunci)}/hari',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _sewa(context, a, false),
                              child: const Text('Sewa + Sopir'),
                            ),
                          ),
                          if (a.hargaLepasKunci > 0) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _sewa(context, a, true),
                                child: const Text('Lepas Kunci'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
