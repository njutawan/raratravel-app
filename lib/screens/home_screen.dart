import 'package:flutter/material.dart';
import '../data/dummy_data.dart';
import '../services/whatsapp_service.dart';
import '../services/preferences_service.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';
import '../widgets/route_card.dart';
import '../widgets/section_title.dart';
import 'orders_screen.dart';
import 'paket_screen.dart';
import 'rental_screen.dart';
import 'route_detail_screen.dart';
import 'search_screen.dart';
import 'wisata_screen.dart';

/// Beranda: header + pencarian + layanan + rute populer + armada + kontak.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _asal = 'Jember';
  String? _tujuan = 'Surabaya';
  DateTime _tanggal = DateTime.now().add(const Duration(days: 1));

  @override
  void initState() {
    super.initState();
    // Isi "Dari" dengan kota favorit dari onboarding (jika ada).
    PreferencesService.getKotaAsal().then((k) {
      if (k != null && mounted) setState(() => _asal = k);
    });
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

  void _swap() => setState(() {
    final t = _asal;
    _asal = _tujuan;
    _tujuan = t;
  });

  void _cari() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          initialAsal: _asal,
          initialTujuan: _tujuan,
          initialTanggal: _tanggal,
        ),
      ),
    );
  }

  void _bantuan() {
    ExternalService.openWhatsApp(
      'Halo *Rara Travel & Tour*, saya butuh info perjalanan.',
    );
  }

  void _promoTap() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pakai kode RARAHEMAT di form booking (hemat 10%)'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SearchScreen(initialTujuan: 'Jakarta'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final populer = DummyData.routes.where((r) => r.populer).toList();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ---------- Header ----------
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.primary, AppTheme.primaryDark],
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(28),
                ),
              ),
              padding: EdgeInsets.fromLTRB(
                Adaptive.hPad(context, maxWidth: 880, min: 20),
                52,
                Adaptive.hPad(context, maxWidth: 880, min: 20),
                24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'assets/icon/app_logo.png',
                          width: 46,
                          height: 46,
                          cacheWidth: 140,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'RARA TRAVEL & TOUR',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              'Amanah & Tepat Waktu',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _bantuan,
                        icon: const Icon(
                          Icons.headset_mic_outlined,
                          color: Colors.white,
                        ),
                        tooltip: 'Bantuan',
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Mau pergi ke mana\nhari ini?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Kartu pencarian
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                // Key agar Tukar/prefill me-rebuild field
                                // (initialValue hanya dibaca saat dibuat).
                                key: ValueKey(_asal),
                                initialValue: _asal,
                                decoration: const InputDecoration(
                                  labelText: 'Dari',
                                  prefixIcon: Icon(Icons.my_location),
                                ),
                                items: AppConstants.cities
                                    .map(
                                      (c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(c),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() => _asal = v),
                              ),
                            ),
                            IconButton(
                              onPressed: _swap,
                              icon: const Icon(
                                Icons.swap_vert,
                                color: AppTheme.primary,
                              ),
                              tooltip: 'Tukar',
                            ),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(_tujuan),
                                initialValue: _tujuan,
                                decoration: const InputDecoration(
                                  labelText: 'Ke',
                                  prefixIcon: Icon(Icons.location_on),
                                ),
                                items: AppConstants.cities
                                    .map(
                                      (c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(c),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() => _tujuan = v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          onTap: _pickDate,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 13,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade600),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.calendar_month,
                                  color: AppTheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  Formatters.fullDate(_tanggal),
                                  semanticsLabel:
                                      'Tanggal keberangkatan: ${Formatters.fullDate(_tanggal)}',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const Spacer(),
                                const Icon(
                                  Icons.edit_calendar_outlined,
                                  size: 18,
                                  color: Color(0xFF757575),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _cari,
                            icon: const Icon(Icons.search),
                            label: const Text('Cari Travel'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: Adaptive.pagePadding(context, maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---------- Strip kepercayaan (fakta layanan) ----------
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _TrustItem(
                          icon: Icons.location_city_outlined,
                          label: '${AppConstants.cities.length} Kota',
                        ),
                        const _TrustItem(
                          icon: Icons.door_front_door_outlined,
                          label: 'Door-to-door',
                        ),
                        const _TrustItem(
                          icon: Icons.access_time,
                          label: 'CS 24 Jam',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  // ---------- Layanan ----------
                  const SectionTitle(title: 'Layanan Kami'),
                  const SizedBox(height: 12),
                  GridView.count(
                    crossAxisCount: Adaptive.isWide(context) ? 6 : 3,
                    // Sel sedikit lebih tinggi → label 2 baris aman di font besar.
                    childAspectRatio: 0.92,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 14,
                    children: [
                      LayananTile(
                        icon: Icons.directions_car_filled,
                        label: 'Travel\nReguler',
                        color: AppTheme.primary,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SearchScreen(),
                          ),
                        ),
                      ),
                      LayananTile(
                        icon: Icons.key_outlined,
                        label: 'Sewa\nMobil',
                        color: Colors.blueGrey.shade700,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RentalScreen(),
                          ),
                        ),
                      ),
                      LayananTile(
                        icon: Icons.landscape_outlined,
                        label: 'Paket\nWisata',
                        color: Colors.green.shade700,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const WisataScreen(),
                          ),
                        ),
                      ),
                      LayananTile(
                        icon: Icons.inventory_2_outlined,
                        label: 'Kirim\nPaket',
                        color: Colors.orange.shade800,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PaketScreen(),
                          ),
                        ),
                      ),
                      LayananTile(
                        icon: Icons.confirmation_number_outlined,
                        label: 'Pesanan\nSaya',
                        color: Colors.purple.shade700,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const OrdersScreen(),
                          ),
                        ),
                      ),
                      LayananTile(
                        icon: Icons.chat_outlined,
                        label: 'Chat\nAdmin',
                        color: AppTheme.waGreen,
                        onTap: _bantuan,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ---------- Rute populer ----------
                  SectionTitle(
                    title: 'Rute Populer',
                    subtitle: 'Door-to-door, jemput di rumah',
                    onSeeAll: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SearchScreen()),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 260,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: populer.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (_, i) => SizedBox(
                        width: 320,
                        child: RouteCard(
                          route: populer[i],
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => RouteDetailScreen(
                                route: populer[i],
                                tanggal: _tanggal,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ---------- Promo (ketuk → cari rute Jakarta) ----------
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: _promoTap,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.orange.shade700,
                            Colors.deepOrange.shade700,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'PROMO RUTE JAUH',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Surabaya/Malang ↔ Jakarta mulai Rp450rb + kode RARAHEMAT hemat 10%!',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Ketuk untuk lihat jadwal →',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.local_offer,
                              color: Colors.white,
                              size: 30,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ---------- Armada ----------
                  SectionTitle(
                    title: 'Armada Kami',
                    subtitle: 'Bersih, terawat, full AC',
                    onSeeAll: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RentalScreen()),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: DummyData.armada.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (_, i) {
                        final a = DummyData.armada[i];
                        return Container(
                          width: 210,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: AppTheme.cardShadow,
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.directions_car,
                                    color: AppTheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      a.nama,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                a.tipe,
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Muat ${a.kapasitas} penumpang',
                                style: const TextStyle(fontSize: 12),
                              ),
                              Text(
                                'Sewa ${Formatters.idr(a.hargaSewa)}/hari',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.primary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ---------- Kenapa kami ----------
                  const SectionTitle(title: 'Kenapa Rara Travel?'),
                  const SizedBox(height: 10),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Column(
                        children: [
                          _WhyRow(
                            icon: Icons.verified_user_outlined,
                            title: 'Aman & berasuransi',
                            desc:
                                'Perjalanan dilindungi asuransi + driver profesional.',
                          ),
                          Divider(height: 18),
                          _WhyRow(
                            icon: Icons.access_time,
                            title: 'Tepat waktu',
                            desc:
                                'Jadwal disiplin setiap hari via jalur tol tercepat.',
                          ),
                          Divider(height: 18),
                          _WhyRow(
                            icon: Icons.door_front_door_outlined,
                            title: 'Door-to-door',
                            desc:
                                'Dijemput di rumah, diantar sampai depan tujuan.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ---------- Kontak ----------
                  Card(
                    color: AppTheme.primaryDark,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Butuh bantuan? Hubungi kami 24 jam',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            AppConstants.phoneDisplay,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: AppTheme.primaryDark,
                                  ),
                                  onPressed: _bantuan,
                                  icon: const Icon(Icons.chat),
                                  label: const Text('Chat WA'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  onPressed: () => ExternalService.openPhone(),
                                  icon: const Icon(Icons.call),
                                  label: const Text('Telepon'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WhyRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  const _WhyRow({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppTheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(
                desc,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrustItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.primary),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.primaryDark,
          ),
        ),
      ],
    );
  }
}
