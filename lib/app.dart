import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/profile_screen.dart';

/// Kunci navigator global: izinkan pindah tab dari notifikasi tanpa context.
class AppNavigator {
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
}

/// Root aplikasi + navigasi bawah.
class RaraTravelApp extends StatelessWidget {
  const RaraTravelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rara Travel & Tour',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: AppNavigator.key,
      home: const SplashScreen(),
    );
  }
}

/// Halaman utama dengan BottomNavigationBar (4 tab).
class MainNav extends StatefulWidget {
  /// Tab awal (2 = Pesananku, dipakai saat dibuka via ketuk notifikasi).
  final int initialIndex;
  const MainNav({super.key, this.initialIndex = 0});

  @override
  State<MainNav> createState() => _MainNavState();
}

class _MainNavState extends State<MainNav> {
  late int _index;
  late final Set<int> _built; // tab yang sudah pernah dibuka (lazy build)
  int _ordersToken = 0; // naik tiap tab Pesananku dibuka → daftar direfresh

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, 3);
    _built = {_index};
  }

  List<Widget> get _pages => [
    const HomeScreen(),
    const SearchScreen(),
    OrdersScreen(refreshToken: _ordersToken),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Lazy: tab yang belum dibuka tidak dibangun (hemat startup +
      // tidak subscribe Firestore sia-sia). Sekali dibangun, state dijaga.
      body: IndexedStack(
        index: _index,
        children: List.generate(
          _pages.length,
          (i) => _built.contains(i) ? _pages[i] : const SizedBox.shrink(),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          _built.add(i);
          if (i == 2) _ordersToken++;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Beranda',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Cari Travel',
          ),
          NavigationDestination(
            icon: Icon(Icons.confirmation_number_outlined),
            selectedIcon: Icon(Icons.confirmation_number),
            label: 'Pesananku',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
