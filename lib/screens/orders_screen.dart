import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/booking.dart';
import '../services/auth_service.dart';
import '../services/booking_storage.dart';
import '../services/firebase_bootstrap.dart';
import '../services/firestore_service.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import '../widgets/common_widgets.dart';
import 'login_carousel_screen.dart';
import 'search_screen.dart';

/// Riwayat pesanan.
/// - Mode offline (Firebase belum setup) → data lokal di HP.
/// - Mode cloud + tamu → ajakan login.
/// - Mode cloud + login → stream real-time dari Firestore.
class OrdersScreen extends StatefulWidget {
  /// Berubah setiap tab ini dibuka → memicu reload daftar.
  final int refreshToken;
  const OrdersScreen({super.key, this.refreshToken = 0});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late Future<List<Booking>> _future;
  // Cache stream cloud per uid: cegah resubscribe (baca ulang) tiap rebuild.
  Stream<List<Booking>>? _cloudStream;
  String? _cloudUid;

  @override
  void initState() {
    super.initState();
    _future = BookingStorage.loadAll();
  }

  void _refresh() => setState(() => _future = BookingStorage.loadAll());

  @override
  void didUpdateWidget(covariant OrdersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tab dibuka (ulang) → muat ulang agar pesanan baru langsung muncul.
    if (widget.refreshToken != oldWidget.refreshToken) _refresh();
  }

  /// True bila pesanan tersimpan di cloud (login + Firebase siap).
  bool get _isCloud =>
      FirebaseBootstrap.ready && AuthService.currentUser != null;

  Future<void> _cancel(Booking b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Batalkan pesanan?'),
        content: Text(
          'Pesanan ${b.kode} (${b.asal} → ${b.tujuan}, ${b.tanggalDisplay}) akan ditandai Dibatalkan. Tetap hubungi admin untuk refund/penjadwalan ulang ya.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Kembali'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ya, batalkan'),
          ),
        ],
      ),
    );
    if (ok == true) {
      var cloudOk = false;
      if (_isCloud) {
        try {
          await FirestoreService.updateStatus(b.kode, 'Dibatalkan');
          cloudOk = true;
        } catch (_) {}
      }
      await BookingStorage.updateStatus(b.kode, 'Dibatalkan');
      // Cloud sukses → tak perlu outbox; gagal → outbox yg bereskan.
      if (cloudOk) await BookingStorage.unmarkDirty(b.kode);
      _refresh();
    }
  }

  Future<void> _delete(Booking b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus riwayat?'),
        content: Text('Hapus pesanan ${b.kode} dari HP ini?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Kembali'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok == true) {
      var cloudOk = false;
      if (_isCloud) {
        try {
          await FirestoreService.deleteBooking(b.kode);
          cloudOk = true;
        } catch (_) {}
      }
      await BookingStorage.remove(b.kode);
      if (cloudOk) await BookingStorage.unmarkDirty(b.kode);
      _refresh();
    }
  }

  void _detail(Booking b) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Tablet: sheet dibatasi agar tak selebar layar.
      constraints: Adaptive.isWide(context)
          ? const BoxConstraints(maxWidth: 640)
          : null,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.9,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    b.kode,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary,
                    ),
                  ),
                ),
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
            const SizedBox(height: 8),
            Text(
              'Total: ${Formatters.idr(b.totalHarga)}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.waGreen),
              onPressed: () =>
                  ExternalService.openWhatsApp(b.toWhatsAppMessage()),
              icon: const Icon(Icons.chat),
              label: const Text('Chat Admin Soal Pesanan Ini'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (b.status == 'Menunggu Konfirmasi')
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _cancel(b);
                      },
                      child: const Text('Batalkan'),
                    ),
                  ),
                if (b.status == 'Menunggu Konfirmasi')
                  const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _delete(b);
                    },
                    child: const Text('Hapus'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!FirebaseBootstrap.ready) {
      // Mode offline: data lokal seperti semula.
      return Scaffold(
        appBar: AppBar(title: const Text('Pesananku')),
        body: FutureBuilder<List<Booking>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final list = snap.data ?? [];
            if (list.isEmpty) return _emptyLocal(context);
            return _bookingList(list, onRefresh: () async => _refresh());
          },
        ),
      );
    }
    // Mode cloud: mengikuti status login.
    return StreamBuilder<User?>(
      stream: AuthService.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: const Text('Pesananku')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final user = authSnap.data;
        if (user == null) {
          _cloudUid = null;
          _cloudStream = null;
          return _guestPrompt();
        }
        if (_cloudUid != user.uid) {
          _cloudUid = user.uid;
          _cloudStream = FirestoreService.userBookings(user.uid);
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Pesananku')),
          // Stale-while-revalidate: data HP tampil instan selagi cloud dimuat.
          body: FutureBuilder<List<Booking>>(
            future: _future,
            builder: (context, localSnap) {
              final lokal = localSnap.data ?? [];
              return StreamBuilder<List<Booking>>(
                stream: _cloudStream,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      lokal.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError && lokal.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_off_outlined,
                              size: 56,
                              color: Colors.grey.shade600,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Gagal memuat pesanan',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Cek koneksi internet, lalu tutup-buka tab ini.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  // Cloud siap → pakai cloud; belum/error → fallback data lokal.
                  if (snap.hasData && (snap.data ?? []).isEmpty) {
                    return EmptyState(
                      icon: Icons.confirmation_number_outlined,
                      title: 'Belum ada pesanan',
                      subtitle:
                          'Pesananmu akan muncul di sini otomatis setelah booking.',
                      actionLabel: 'Cari Travel',
                      onAction: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchScreen()),
                      ),
                    );
                  }
                  if (!snap.hasData && lokal.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final tampil = snap.hasData ? snap.data! : lokal;
                  final daftar = _bookingList(
                    tampil,
                    onRefresh: () async {
                      _cloudUid = null; // paksa langganan ulang + muat lokal
                      _refresh();
                    },
                  );
                  if (snap.hasData || snap.hasError) return daftar;
                  // Menunggu cloud + ada data lokal → tampil + bar loading tipis.
                  return Column(
                    children: [
                      const LinearProgressIndicator(minHeight: 3),
                      Expanded(child: daftar),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  /// Ajakan login untuk tamu (mode cloud).
  Widget _guestPrompt() {
    return Scaffold(
      appBar: AppBar(title: const Text('Pesananku')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.grey.shade600),
              const SizedBox(height: 12),
              const Text(
                'Masuk dulu yuk',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 6),
              Text(
                'Riwayat pesanan tersimpan aman di akunmu dan tersinkron di semua perangkat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LoginCarouselScreen(),
                  ),
                ),
                child: const Text('Masuk / Daftar'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyLocal(BuildContext context) {
    return EmptyState(
      icon: Icons.confirmation_number_outlined,
      title: 'Belum ada pesanan',
      subtitle: 'Pesanan travel kamu akan tersimpan di sini. Yuk pesan dulu!',
      actionLabel: 'Cari Travel',
      onAction: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
    );
  }

  /// Daftar kartu pesanan (dipakai mode lokal & cloud).
  Widget _bookingList(
    List<Booking> list, {
    required Future<void> Function() onRefresh,
  }) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: Adaptive.pagePadding(
          context,
          maxWidth: 720,
          vertical: 14,
          min: 14,
        ),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final b = list[i];
          return Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _detail(b),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${b.asal} → ${b.tujuan}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        StatusBadge(status: b.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${b.tanggalDisplay} • ${b.jam} WIB • ${b.kursi} kursi',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          b.kode,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          Formatters.idr(b.totalHarga),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
