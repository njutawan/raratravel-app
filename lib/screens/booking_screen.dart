import 'package:flutter/material.dart';
import '../config/backend_config.dart';
import '../models/booking.dart';
import '../models/app_user.dart';
import '../models/travel_route.dart';
import '../repositories/booking_repository.dart';
import '../services/booking_storage.dart';
import '../services/auth_gate.dart';
import '../services/auth_service.dart';
import '../services/edge_client.dart';
import '../services/firebase_bootstrap.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';
import 'checkout_success_screen.dart';

/// Form pemesanan kursi travel.
class BookingScreen extends StatefulWidget {
  final TravelRoute route;
  final DateTime tanggal;
  final String jam;

  const BookingScreen({
    super.key,
    required this.route,
    required this.tanggal,
    required this.jam,
  });

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nama = TextEditingController();
  final _wa = TextEditingController();
  final _jemput = TextEditingController();
  final _antar = TextEditingController();
  final _catatan = TextEditingController();
  final _promo = TextEditingController();
  int _kursi = 1;
  String _bayar = AppConstants.paymentMethods.first;
  bool _loading = false;

  @override
  void dispose() {
    _nama.dispose();
    _wa.dispose();
    _jemput.dispose();
    _antar.dispose();
    _catatan.dispose();
    _promo.dispose();
    super.dispose();
  }

  /// Persen diskon kode promo (0 = kosong, -1 = tidak valid).
  int get _promoPersen {
    final kode = _promo.text.trim().toUpperCase();
    if (kode.isEmpty) return 0;
    return AppConstants.promoCodes[kode] ?? -1;
  }

  // Harga resmi berasal dari server (jadwal bisa beda harga tiap jam).
  int get _hargaKursi => widget.route.hargaUntuk(widget.jam);
  int get _subtotal => _hargaKursi * _kursi;

  int get _diskon {
    final p = _promoPersen;
    if (p <= 0) return 0;
    final hitung = _subtotal * p ~/ 100;
    return hitung > AppConstants.promoMaxDiskon
        ? AppConstants.promoMaxDiskon
        : hitung;
  }

  int get _total => _subtotal - _diskon;

  /// Ada isian yang akan hilang jika pengguna menekan back.
  bool get _isDirty =>
      _nama.text.isNotEmpty ||
      _wa.text.isNotEmpty ||
      _jemput.text.isNotEmpty ||
      _antar.text.isNotEmpty ||
      _catatan.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _prefillProfil();
  }

  /// Isi otomatis nama & WA dari profil akun (bila sudah login).
  Future<void> _prefillProfil() async {
    if (!FirebaseBootstrap.ready) return;
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      final profil = await FirestoreService.getUser(user.uid);
      if (!mounted || profil == null) return;
      if (_nama.text.isEmpty && profil.name.isNotEmpty) {
        _nama.text = profil.name;
      }
      if (_wa.text.isEmpty && profil.phoneLocal.isNotEmpty) {
        _wa.text = profil.phoneLocal;
      }
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // Wajib login (OTP) agar pesanan tercatat di akun + terlihat admin.
    final user = await AuthGate.ensureLoggedIn(context);
    if (!mounted || user == null) return;
    setState(() => _loading = true);

    // Kode & kunci idempotency dibuat SEKALI: bila pengiriman diulang (jaringan
    // putus, tombol ditekan dua kali), server mengenali permintaan yang sama
    // sehingga tidak membuat pesanan ganda.
    final idempotencyKey = BookingRepository.newIdempotencyKey();
    var booking = Booking(
      kode: Formatters.bookingCode(),
      asal: widget.route.asal,
      tujuan: widget.route.tujuan,
      tanggal: Formatters.toISO(widget.tanggal),
      jam: widget.jam,
      nama: _nama.text.trim(),
      wa: _wa.text.trim(),
      jemput: _jemput.text.trim(),
      antar: _antar.text.trim(),
      kursi: _kursi,
      totalHarga: _total,
      metodeBayar: _bayar,
      catatan: _catatan.text.trim(),
      promo: _promoPersen > 0 ? _promo.text.trim().toUpperCase() : '',
      diskon: _diskon,
      createdAt: DateTime.now().toIso8601String(),
    );
    await BookingStorage.add(
      booking,
    ); // cache lokal (riwayat tetap ada offline)

    // ---- Server baru (PostgreSQL): harga & kursi divalidasi di sana ----
    if (BookingRepository.enabled) {
      var percobaan = 0;
      while (true) {
        try {
          final hasil = await BookingRepository.create(
            draft: booking,
            idempotencyKey: idempotencyKey,
            userId: user.uid,
          );
          // Pakai versi server (kode & total resmi dari database).
          booking = hasil.booking;
          break;
        } on ApiException catch (e) {
          if (!mounted) return;
          if (e.isPriceMismatch && percobaan == 0) {
            final lanjut = await _tanyaHargaBerubah(e);
            if (lanjut != true) {
              setState(() => _loading = false);
              return;
            }
            // Ulangi sekali dengan harga resmi dari server.
            booking = booking.copyWith(
              totalHarga: e.expectedTotal,
              diskon: (e.details['discount'] as num?)?.toInt() ?? booking.diskon,
            );
            percobaan++;
            continue;
          }
          setState(() => _loading = false);
          _pesanError(e);
          return;
        } catch (_) {
          // Gagal tak terduga → lanjut jalur lama di bawah (pesanan lokal sah).
          break;
        }
      }
    }

    // ---- Jalur lama (Firestore) masih jalan selama mode 'dual' ----
    if (FirebaseBootstrap.ready && BackendConfig.writeFirestore) {
      try {
        await FirestoreService.saveBooking(booking, user.uid);
        await BookingStorage.markMigrated(booking.kode);
        // Simpan nama ke profil bila masih kosong.
        final profil = await FirestoreService.getUser(user.uid);
        if (profil != null &&
            profil.name.isEmpty &&
            _nama.text.trim().isNotEmpty) {
          await FirestoreService.saveUser(
            AppUser(
              uid: user.uid,
              phone: profil.phone,
              name: _nama.text.trim(),
              fcmTokens: profil.fcmTokens,
              createdAt: profil.createdAt,
            ),
          );
        }
      } catch (_) {
        // Gagal cloud (offline?) — pesanan lokal tetap sah, konfirmasi via WA.
      }
    }

    if (!mounted) return;
    // Langsung pindah halaman (tidak perlu setState: halaman ini dibuang).
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CheckoutSuccessScreen(booking: booking),
      ),
    );
  }

  /// Harga berubah di server (mis. admin memperbarui tarif). Tawarkan hitung
  /// ulang supaya pengguna tidak membayar dengan angka lama.
  Future<bool?> _tanyaHargaBerubah(ApiException e) {
    final totalBaru = e.expectedTotal;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Harga diperbarui'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tarif rute ini baru saja diperbarui admin. Mohon periksa total terbaru:',
            ),
            const SizedBox(height: 12),
            Text('Total sebelumnya: ${Formatters.idr(booking.totalHarga)}'),
            Text(
              'Total terbaru: ${Formatters.idr(totalBaru)}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Nanti saja'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Pesan dengan harga baru'),
          ),
        ],
      ),
    );
  }

  /// Pesan kesalahan yang bisa dimengerti pengguna.
  void _pesanError(ApiException e) {
    String pesan;
    if (e.isSeatsUnavailable) {
      pesan = e.message.isEmpty
          ? 'Kursi sudah habis. Pilih jadwal atau tanggal lain.'
          : e.message;
    } else if (e.isUnauthorized) {
      pesan = 'Sesi login berakhir. Silakan masuk lagi.';
    } else if (e.isPromoInvalid) {
      pesan = e.message;
    } else {
      pesan = e.message.isEmpty
          ? 'Gagal menyimpan pesanan. Coba lagi.'
          : e.message;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(pesan), duration: const Duration(seconds: 5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    // PopScope: cegah isian hilang karena tombol back tak sengaja.
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final batal = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Batalkan pesanan?'),
            content: const Text('Data yang sudah diisi akan hilang.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Tetap di sini'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Ya, batalkan'),
              ),
            ],
          ),
        );
        if (batal == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Form Pemesanan')),
        // Total + tombol selalu terlihat (tanpa scroll) → checkout mulus.
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: EdgeInsets.fromLTRB(
              Adaptive.hPad(context),
              10,
              Adaptive.hPad(context),
              12,
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Bayar',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      Text(
                        Formatters.idr(_total),
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Buat Pesanan'),
                  ),
                ),
              ],
            ),
          ),
        ),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: Adaptive.pagePadding(context),
              children: [
                // Ringkasan perjalanan
                Card(
                  color: AppTheme.primary.withValues(alpha: 0.06),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${r.asal} → ${r.tujuan}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${Formatters.fullDate(widget.tanggal)} • Jam ${widget.jam} WIB',
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${Formatters.idr(_hargaKursi)}/kursi • ${r.durasi} ${r.via}',
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  'Data Penumpang',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nama,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nama lengkap *',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => (v == null || v.trim().length < 3)
                      ? 'Isi nama lengkap'
                      : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _wa,
                  textInputAction: TextInputAction.next,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'No. WhatsApp aktif *',
                    hintText: 'cth. 081234567890',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (v) {
                    final t = v?.trim() ?? '';
                    if (t.length < 10 || !RegExp(r'^[0-9+]+$').hasMatch(t)) {
                      return 'Isi nomor WA yang valid';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                const Text(
                  'Penjemputan & Pengantaran',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _jemput,
                  textInputAction: TextInputAction.next,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Alamat jemput lengkap *',
                    hintText: 'Nama jalan, patokan, no. rumah/kos',
                    prefixIcon: Icon(Icons.my_location),
                  ),
                  validator: (v) => (v == null || v.trim().length < 10)
                      ? 'Isi alamat jemput lengkap'
                      : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _antar,
                  textInputAction: TextInputAction.next,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Alamat antar lengkap *',
                    hintText: 'Tujuan akhir + patokan',
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                  validator: (v) => (v == null || v.trim().length < 10)
                      ? 'Isi alamat antar lengkap'
                      : null,
                ),
                const SizedBox(height: 16),

                // Jumlah kursi
                Row(
                  children: [
                    const Text(
                      'Jumlah Kursi',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const Spacer(),
                    IconButton.filledTonal(
                      onPressed: _kursi > 1
                          ? () => setState(() => _kursi--)
                          : null,
                      tooltip: 'Kurangi kursi',
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '$_kursi',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: _kursi < 16
                          ? () => setState(() => _kursi++)
                          : null,
                      tooltip: 'Tambah kursi',
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (_kursi >= 5)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Rombongan $_kursi orang? Chat admin untuk harga spesial & pilihan armada (Hiace/Elf).',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                const Text(
                  'Metode Pembayaran',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: _bayar,
                  onChanged: (v) => setState(() => _bayar = v!),
                  child: Column(
                    children: AppConstants.paymentMethods
                        .map(
                          (m) => RadioListTile<String>(
                            value: m,
                            title: Text(
                              m,
                              style: const TextStyle(fontSize: 14),
                            ),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _catatan,
                  textInputAction: TextInputAction.done,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Catatan (opsional)',
                    hintText: 'cth. bawa koper besar, titip jemput teman, dll.',
                    prefixIcon: Icon(Icons.note_outlined),
                  ),
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _promo,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Kode promo (opsional)',
                    hintText: 'cth. RARAHEMAT',
                    prefixIcon: Icon(Icons.discount_outlined),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_promo.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _promoPersen > 0
                        ? 'Kode berlaku! Kamu hemat ${Formatters.idr(_diskon)}.'
                        : 'Kode promo tidak valid.',
                    style: TextStyle(
                      fontSize: 12,
                      color: _promoPersen > 0
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 16),

                // Rincian + ekspektasi login (ditagih saat submit via OTP)
                Text(
                  '$_kursi kursi × ${Formatters.idr(_hargaKursi)}. Pembayaran dikonfirmasi via WhatsApp admin.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Pesanan tersimpan ke akunmu — login OTP ±1 menit saat menekan Buat Pesanan.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
