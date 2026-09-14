import 'package:flutter/material.dart';
import '../data/dummy_data.dart';
import '../models/travel_route.dart';
import '../repositories/catalog_repository.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';
import '../widgets/route_card.dart';
import 'route_detail_screen.dart';

/// Layar pencarian & daftar semua rute travel.
class SearchScreen extends StatefulWidget {
  final String? initialAsal;
  final String? initialTujuan;
  final DateTime? initialTanggal;

  const SearchScreen({
    super.key,
    this.initialAsal,
    this.initialTujuan,
    this.initialTanggal,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String? _asal;
  String? _tujuan;
  late DateTime _tanggal;
  bool _termurahDulu = true;

  List<String> _cities = AppConstants.cities;

  // Hasil dari server (null → tampilkan data lokal lebih dulu).
  List<TravelRoute>? _dariServer;
  bool _memuatServer = false;

  @override
  void initState() {
    super.initState();
    _asal = widget.initialAsal;
    _tujuan = widget.initialTujuan;
    _tanggal =
        widget.initialTanggal ?? DateTime.now().add(const Duration(days: 1));
    _muatKota();
    _cariDariServer();
  }

  Future<void> _muatKota() async {
    if (!CatalogRepository.enabled) return;
    try {
      final cities = await CatalogRepository.cities();
      if (!mounted) return;
      if (cities.isNotEmpty) {
        setState(() => _cities = cities);
      }
    } catch (_) {}
  }

  /// Ambil hasil dari katalog server (harga & kursi terbaru dari admin).
  ///
  /// Saat server belum aktif / gagal dihubungi, repositori otomatis memakai
  /// data lokal sehingga layar tetap terisi.
  Future<void> _cariDariServer() async {
    if (!CatalogRepository.enabled || _memuatServer) return;
    setState(() => _memuatServer = true);
    final halaman = await CatalogRepository.searchRoutes(
      asal: _asal,
      tujuan: _tujuan,
      tanggal: _tanggal,
      sort: _termurahDulu ? 'price_asc' : 'price_desc',
      limit: 50,
    );
    if (!mounted) return;
    setState(() {
      _dariServer = halaman.items;
      _memuatServer = false;
    });
  }

  /// Filter berubah: tampilkan data lokal seketika, lalu segarkan dari server.
  void _ubahFilter(VoidCallback ubah) {
    setState(() {
      ubah();
      _dariServer = null; // hindari hasil lama tampil dengan filter baru
    });
    _cariDariServer();
  }

  List<TravelRoute> get _hasil {
    final dariServer = _dariServer;
    if (dariServer != null) return dariServer;
    var list = DummyData.routes.where((r) {
      final cocokAsal = _asal == null || r.asal == _asal;
      final cocokTujuan = _tujuan == null || r.tujuan == _tujuan;
      return cocokAsal && cocokTujuan;
    }).toList();
    list.sort(
      (a, b) => _termurahDulu
          ? a.harga.compareTo(b.harga)
          : b.harga.compareTo(a.harga),
    );
    return list;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _tanggal,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    );
    if (picked != null) _ubahFilter(() => _tanggal = picked);
  }

  @override
  Widget build(BuildContext context) {
    final hasil = _hasil;
    final fields = _filterFields();
    return Scaffold(
      appBar: AppBar(title: const Text('Cari Travel')),
      // Tablet/foldable: filter jadi panel samping; HP: filter di atas.
      body: Adaptive.isWide(context)
          ? Row(
              children: [
                Container(
                  width: 320,
                  color: Colors.white,
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      fields[0],
                      const SizedBox(height: 10),
                      fields[1],
                      const SizedBox(height: 10),
                      fields[2],
                      const SizedBox(height: 10),
                      fields[3],
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                _hasilList(hasil),
              ],
            )
          : Column(
              children: [
                // Filter
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: fields[0]),
                          const SizedBox(width: 10),
                          Expanded(child: fields[1]),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: fields[2]),
                          const SizedBox(width: 10),
                          fields[3],
                        ],
                      ),
                    ],
                  ),
                ),
                // Hasil
                _hasilList(hasil),
              ],
            ),
    );
  }

  /// Empat field filter (dipakai ulang di layout HP & tablet).
  List<Widget> _filterFields() {
    return [
      DropdownButtonFormField<String>(
        key: ValueKey('search_asal_$_asal'),
        initialValue: _asal == null || _cities.contains(_asal) ? _asal : null,
        decoration: const InputDecoration(labelText: 'Dari', isDense: true),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('Semua')),
          ..._cities.map(
            (c) => DropdownMenuItem(value: c, child: Text(c)),
          ),
        ],
        onChanged: (v) => _ubahFilter(() => _asal = v),
      ),
      DropdownButtonFormField<String>(
        key: ValueKey('search_tujuan_$_tujuan'),
        initialValue: _tujuan == null || _cities.contains(_tujuan) ? _tujuan : null,
        decoration: const InputDecoration(labelText: 'Ke', isDense: true),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('Semua')),
          ..._cities.map(
            (c) => DropdownMenuItem(value: c, child: Text(c)),
          ),
        ],
        onChanged: (v) => _ubahFilter(() => _tujuan = v),
      ),
      InkWell(
        onTap: _pickDate,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade600),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.calendar_month,
                size: 20,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                Formatters.shortDate(_tanggal),
                semanticsLabel:
                    'Tanggal keberangkatan: ${Formatters.shortDate(_tanggal)}',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
      FilterChip(
        label: Text(_termurahDulu ? 'Termurah' : 'Termahal'),
        avatar: const Icon(Icons.sort, size: 18),
        onSelected: (_) =>
            _ubahFilter(() => _termurahDulu = !_termurahDulu),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
    ];
  }

  /// Daftar hasil (dipakai ulang di layout HP & tablet).
  Widget _hasilList(List<TravelRoute> hasil) {
    return Expanded(
      child: Column(
        children: [
          if (_memuatServer) const LinearProgressIndicator(minHeight: 3),
          Expanded(child: _isiHasil(hasil)),
        ],
      ),
    );
  }

  Widget _isiHasil(List<TravelRoute> hasil) {
    if (hasil.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_outlined,
        title: 'Rute tidak ditemukan',
        subtitle: 'Coba ubah asal/tujuan, atau chat admin untuk rute custom.',
        actionLabel: 'Chat Admin',
        onAction: () => ExternalService.openWhatsApp(
          'Halo *Rara Travel & Tour*, saya butuh rute ${_asal ?? '...'} → ${_tujuan ?? '...'}.',
        ),
      );
    }
    return ListView.separated(
      padding: Adaptive.pagePadding(
        context,
        maxWidth: 720,
        vertical: 14,
        min: 14,
      ),
      itemCount: hasil.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => RouteCard(
        route: hasil[i],
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                RouteDetailScreen(route: hasil[i], tanggal: _tanggal),
          ),
        ),
      ),
    );
  }
}
