import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raratravel_app/models/travel_route.dart';
import 'package:raratravel_app/widgets/adaptive.dart';
import 'package:raratravel_app/widgets/common_widgets.dart';
import 'package:raratravel_app/widgets/route_card.dart';
import 'package:raratravel_app/widgets/section_title.dart';

/// Uji widget: bagian yang dilihat langsung pengguna di alur kritis
/// (daftar rute, status pesanan, keadaan kosong) + perilaku adaptif
/// (tablet/folded & font aksesibilitas raksasa).
void main() {
  /// Bungkus widget dengan MaterialApp + tema seperti aplikasi asli.
  Widget bungkus(Widget anak, {double lebar = 360, double skalaFont = 1.0}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(lebar, 800),
          textScaler: TextScaler.linear(skalaFont),
        ),
        child: Scaffold(body: anak),
      ),
    );
  }

  TravelRoute rute({
    int harga = 450000,
    bool populer = false,
    List<String> jadwal = const ['06.00', '19.00'],
  }) {
    return TravelRoute(
      id: 'rute-uji',
      asal: 'Jember',
      tujuan: 'Surabaya',
      harga: harga,
      durasi: '± 6 jam',
      via: 'via Tol Trans Jawa',
      jadwal: jadwal,
      armada: const ['Hiace Premio'],
      fasilitas: const ['AC', 'WiFi'],
      deskripsi: 'Rute uji',
      populer: populer,
    );
  }

  group('RouteCard (daftar rute — pintu masuk alur booking)', () {
    testWidgets('menampilkan asal → tujuan, via, jadwal, dan harga rupiah',
        (tester) async {
      await tester.pumpWidget(bungkus(RouteCard(route: rute(), onTap: () {})));

      expect(find.textContaining('Jember'), findsOneWidget);
      expect(find.textContaining('Surabaya'), findsOneWidget);
      expect(find.textContaining('→'), findsOneWidget);
      expect(find.text('± 6 jam via Tol Trans Jawa'), findsOneWidget);
      expect(find.text('06.00 WIB'), findsOneWidget);
      expect(find.text('19.00 WIB'), findsOneWidget);
      // Harga wajib terformat Indonesia, bukan angka mentah.
      expect(find.text('Rp450.000'), findsOneWidget);
      expect(find.textContaining('450000'), findsNothing);
    });

    testWidgets('tombol Pesan memanggil callback (buka detail rute)',
        (tester) async {
      var ditekan = 0;
      await tester.pumpWidget(
        bungkus(RouteCard(route: rute(), onTap: () => ditekan++)),
      );

      await tester.tap(find.text('Pesan'));
      await tester.pump();
      expect(ditekan, 1);
    });

    testWidgets('label Populer hanya muncul bila rutenya populer',
        (tester) async {
      await tester.pumpWidget(bungkus(RouteCard(route: rute(), onTap: () {})));
      expect(find.text('Populer'), findsNothing);

      await tester.pumpWidget(
        bungkus(RouteCard(route: rute(populer: true), onTap: () {})),
      );
      expect(find.text('Populer'), findsOneWidget);
    });
  });

  group('StatusBadge (status pesanan di "Pesananku")', () {
    testWidgets('setiap status tampil apa adanya dengan warna berbeda',
        (tester) async {
      for (final status in ['Menunggu Konfirmasi', 'Dikonfirmasi', 'Dibatalkan']) {
        await tester.pumpWidget(bungkus(StatusBadge(status: status)));
        expect(find.text(status), findsOneWidget);
      }
    });

    testWidgets('Dibatalkan memakai warna merah, bukan warna default',
        (tester) async {
      Color? warnaBadge(String status) {
        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.text(status),
                matching: find.byType(Container),
              )
              .first,
        );
        return (container.decoration as BoxDecoration?)?.color;
      }

      await tester.pumpWidget(bungkus(const StatusBadge(status: 'Dibatalkan')));
      final merah = warnaBadge('Dibatalkan');

      await tester.pumpWidget(
        bungkus(const StatusBadge(status: 'Dikonfirmasi')),
      );
      final hijau = warnaBadge('Dikonfirmasi');

      await tester.pumpWidget(
        bungkus(const StatusBadge(status: 'Menunggu Konfirmasi')),
      );
      final jingga = warnaBadge('Menunggu Konfirmasi');

      expect(merah, Colors.red.shade100);
      expect(hijau, Colors.green.shade100);
      expect(jingga, Colors.orange.shade100);
      expect(merah, isNot(jingga));
    });
  });

  group('EmptyState (mis. "Belum ada pesanan")', () {
    testWidgets('tombol aksi hanya muncul bila label + callback diberikan',
        (tester) async {
      await tester.pumpWidget(
        bungkus(
          const EmptyState(
            icon: Icons.inbox,
            title: 'Belum ada pesanan',
            subtitle: 'Yuk pesan perjalanan pertamamu.',
          ),
        ),
      );
      expect(find.text('Belum ada pesanan'), findsOneWidget);
      expect(find.text('Cari Rute'), findsNothing);

      var ditekan = 0;
      await tester.pumpWidget(
        bungkus(
          EmptyState(
            icon: Icons.inbox,
            title: 'Belum ada pesanan',
            subtitle: 'Yuk pesan perjalanan pertamamu.',
            actionLabel: 'Cari Rute',
            onAction: () => ditekan++,
          ),
        ),
      );
      await tester.tap(find.text('Cari Rute'));
      await tester.pump();
      expect(ditekan, 1);
    });
  });

  group('SectionTitle', () {
    testWidgets('"Lihat Semua" hanya bila ada aksi, dan bisa ditekan',
        (tester) async {
      await tester.pumpWidget(
        bungkus(const SectionTitle(title: 'Paket Wisata')),
      );
      expect(find.text('Paket Wisata'), findsOneWidget);
      expect(find.text('Lihat Semua'), findsNothing);

      var ditekan = 0;
      await tester.pumpWidget(
        bungkus(
          SectionTitle(
            title: 'Paket Wisata',
            subtitle: 'Pilihan favorit',
            onSeeAll: () => ditekan++,
          ),
        ),
      );
      expect(find.text('Pilihan favorit'), findsOneWidget);
      await tester.tap(find.text('Lihat Semua'));
      await tester.pump();
      expect(ditekan, 1);
    });
  });

  group('MaxTextScale (anti-overflow font aksesibilitas raksasa)', () {
    testWidgets('skala font dibatasi sesuai batas', (tester) async {
      await tester.pumpWidget(
        bungkus(
          Builder(
            builder: (context) {
              // Di luar MaxTextScale, skala font sistem dipakai apa adanya.
              expect(MediaQuery.textScalerOf(context).scale(1), 3.0);
              return const SizedBox.shrink();
            },
          ),
          skalaFont: 3.0,
        ),
      );

      await tester.pumpWidget(
        bungkus(
          MaxTextScale(
            max: 1.3,
            child: Builder(
              builder: (context) {
                expect(MediaQuery.textScalerOf(context).scale(1), 1.3);
                return const SizedBox.shrink();
              },
            ),
          ),
          skalaFont: 3.0,
        ),
      );
      expect(find.byType(MaxTextScale), findsOneWidget);
    });
  });

  group('Adaptive (HP vs tablet/foldable)', () {
    testWidgets('isWide berubah di 600dp', (tester) async {
      Future<bool> nilai(double lebar) async {
        late bool hasil;
        await tester.pumpWidget(
          bungkus(
            Builder(
              builder: (context) {
                hasil = Adaptive.isWide(context);
                return const SizedBox.shrink();
              },
            ),
            lebar: lebar,
          ),
        );
        return hasil;
      }

      expect(await nilai(360), isFalse);
      expect(await nilai(599), isFalse);
      expect(await nilai(600), isTrue);
      expect(await nilai(1024), isTrue);
    });

    testWidgets('padding horizontal: minimum di HP, rata tengah di tablet',
        (tester) async {
      Future<EdgeInsets> nilai(double lebar) async {
        late EdgeInsets hasil;
        await tester.pumpWidget(
          bungkus(
            Builder(
              builder: (context) {
                hasil = Adaptive.pagePadding(context);
                return const SizedBox.shrink();
              },
            ),
            lebar: lebar,
          ),
        );
        return hasil;
      }

      final hp = await nilai(360);
      expect(hp.left, 16);
      expect(hp.top, 16);

      // 1024dp: (1024 − 680) / 2 = 172 di kiri dan kanan.
      final tablet = await nilai(1024);
      expect(tablet.left, 172);
      expect(tablet.right, 172);
    });
  });
}
