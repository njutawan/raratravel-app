import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/backend_config.dart';
import '../services/whatsapp_service.dart';
import '../services/auth_service.dart';
import '../services/firebase_bootstrap.dart';
import '../services/messaging_service.dart';
import '../services/preferences_service.dart';
import 'login_carousel_screen.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/adaptive.dart';

/// Layar profil / info perusahaan + bantuan.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _tentang(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Tentang Kami'),
        content: const SingleChildScrollView(
          child: Text(
            'Rara Travel & Tour — platform resmi penyedia layanan transportasi darat premium antarkota di Jawa Timur di bawah naungan PT Raratrans Energi Persada.\n\n'
            'Melayani travel reguler door-to-door (Jember, Surabaya, Bandara Juanda, Malang, Banyuwangi, Jakarta, Denpasar, dll), sewa mobil + sopir / lepas kunci, paket wisata (Bromo, Ijen, Bali), kirim paket kilat, hingga tiket pesawat, kereta, kapal, & bus.\n\n'
            'Tiga pilar kami: Aman (berasuransi), Tepat Waktu, dan Door-to-Door Service.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  void _kebijakan(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ketentuan Umum'),
        content: const SingleChildScrollView(
          child: Text(
            '• Penumpang wajib siap 30 menit sebelum jam keberangkatan.\n'
            '• Free bagasi 1 koli/orang (±20 kg). Kelebihan bagasi kena biaya tambahan.\n'
            '• Pembatalan H-1: refund 50% / reschedule gratis 1x.\n'
            '• Pembatalan di hari-H: non-refundable, bisa reschedule dengan biaya admin.\n'
            '• Dilarang membawa barang berbahaya, narkoba, & hewan tanpa kandang.\n'
            '• Keterlambatan akibat force majeure (macet ekstrem, bencana) akan diinfo real-time via WA.',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profil & Bantuan')),
      body: ListView(
        padding: Adaptive.pagePadding(context),
        children: [
          // Header perusahaan
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/icon/app_logo.png',
                      width: 60,
                      height: 60,
                      cacheWidth: 180,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Rara Travel & Tour',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          'PT Raratrans Energi Persada',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Amanah & Tepat Waktu • Sejak 2010',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Kartu akun (sembunyi saat mode offline)
          const _AccountCard(),
          const SizedBox(height: 12),

          // Kontak cepat
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.waGreen,
                  ),
                  onPressed: () => ExternalService.openWhatsApp(
                    'Halo *Rara Travel & Tour*, saya butuh bantuan.',
                  ),
                  icon: const Icon(Icons.chat),
                  label: const Text('Chat WA'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => ExternalService.openPhone(),
                  icon: const Icon(Icons.call),
                  label: const Text(AppConstants.phoneDisplay),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.access_time, color: AppTheme.primary),
                  title: Text('Jam Operasional'),
                  subtitle: Text(AppConstants.openHours),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                const ListTile(
                  leading: Icon(Icons.location_on, color: AppTheme.primary),
                  title: Text('Kantor Pusat'),
                  subtitle: Text(AppConstants.address),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.email, color: AppTheme.primary),
                  title: const Text('Email'),
                  subtitle: const Text(AppConstants.email),
                  onTap: () =>
                      ExternalService.openEmail(subject: 'Tanya Rara Travel'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.language, color: AppTheme.primary),
                  title: const Text('Website'),
                  subtitle: const Text(AppConstants.website),
                  onTap: () => ExternalService.openLink(AppConstants.website),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(
                    Icons.privacy_tip_outlined,
                    color: AppTheme.primary,
                  ),
                  title: const Text('Kebijakan Privasi'),
                  subtitle: const Text('raratravel.id/privacy-policy'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () =>
                      ExternalService.openLink(AppConstants.privacyPolicy),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.info_outline,
                    color: AppTheme.primary,
                  ),
                  title: const Text('Tentang Kami'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _tentang(context),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(
                    Icons.receipt_long_outlined,
                    color: AppTheme.primary,
                  ),
                  title: const Text('Ketentuan & Refund'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _kebijakan(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          const _PreferensiCard(),
          const SizedBox(height: 12),

          const _RingkasanBackendCard(),
          const SizedBox(height: 12),

          Card(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Ikuti Kami',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.facebook, color: Colors.blue),
                  title: const Text('Facebook'),
                  subtitle: const Text('raratranstravel'),
                  onTap: () => ExternalService.openLink(AppConstants.facebook),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.camera_alt_outlined,
                    color: Colors.pink,
                  ),
                  title: const Text('Instagram'),
                  subtitle: const Text('@raratraveltour'),
                  onTap: () => ExternalService.openLink(AppConstants.instagram),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.play_circle_outline,
                    color: Colors.red,
                  ),
                  title: const Text('YouTube'),
                  subtitle: const Text('@raratraveltour'),
                  onTap: () => ExternalService.openLink(AppConstants.youtube),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Rara Travel App v1.0.0 • raratravel.id',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Kartu akun: status login + tombol masuk/keluar/hapus akun.
class _AccountCard extends StatelessWidget {
  const _AccountCard();

  /// Hapus akun permanen: profil + semua pesanan cloud + riwayat lokal.
  /// Wajib ada sebelum rilis Play Store (kebijakan Data Safety).
  Future<void> _hapusAkun(BuildContext context) async {
    final yakin = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus akun permanen?'),
        content: const Text(
          'Profil dan SEMUA pesananmu (cloud + HP ini) akan dihapus permanen dan tidak bisa dikembalikan. Lanjut?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus Permanen'),
          ),
        ],
      ),
    );
    if (yakin != true || !context.mounted) return;
    try {
      await AuthService.deleteAccount();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Akun & seluruh data dihapus.')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      final msg = e.code == 'requires-recent-login'
          ? 'Sesi kedaluwarsa. Keluar lalu masuk lagi, kemudian hapus akun.'
          : AuthService.friendlyError(e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal menghapus akun. Coba lagi.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!FirebaseBootstrap.ready) return const SizedBox.shrink();
    return StreamBuilder<User?>(
      stream: AuthService.authStateChanges(),
      builder: (context, snap) {
        final user = snap.data;
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(
                user == null
                    ? Icons.person_outline
                    : Icons.verified_user_outlined,
              ),
            ),
            title: Text(
              user == null ? 'Belum masuk' : (user.phoneNumber ?? 'Pengguna'),
            ),
            subtitle: Text(
              user == null
                  ? 'Masuk untuk sinkron pesanan ke akun'
                  : 'Pesanan tersinkron ke akun ini',
            ),
            trailing: user == null
                ? FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const LoginCarouselScreen(),
                      ),
                    ),
                    child: const Text('Masuk'),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => AuthService.signOut(),
                        child: const Text('Keluar'),
                      ),
                      TextButton(
                        onPressed: () => _hapusAkun(context),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                        ),
                        child: const Text('Hapus Akun'),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// Kartu preferensi (mata uang & bahasa).
///
/// Kartu diagnostik: mode backend & kesiapan fitur pada build yang berjalan.
///
/// Berguna saat uji rilis di HP: menampilkan (tanpa perlu buka kode) apakah
/// katalog memakai Supabase, ke mana pesanan ditulis, apakah tombol pembayaran
/// aktif, dan apakah push notification sudah terdaftar. Ada tombol salin agar
/// isinya mudah dilaporkan ke tim.
class _RingkasanBackendCard extends StatelessWidget {
  const _RingkasanBackendCard();

  String get _teksRingkasan =>
      'Rara Travel v${MessagingService.appVersion} — ${BackendConfig.deskripsi}';

  @override
  Widget build(BuildContext context) {
    final warna = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        leading: Icon(Icons.settings_suggest_outlined, color: warna.primary),
        title: const Text(
          'Ringkasan Backend',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: const Text(
          'Untuk uji rilis: mode data, pembayaran, notifikasi',
          style: TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          _Baris(label: 'Versi aplikasi', nilai: MessagingService.appVersion),
          _Baris(
            label: 'Firebase',
            nilai: FirebaseBootstrap.ready ? 'siap' : 'belum siap',
          ),
          _Baris(
            label: 'Supabase',
            nilai: BackendConfig.hasSupabase ? 'tersambung' : 'belum diatur',
          ),
          _Baris(
            label: 'Katalog',
            nilai:
                BackendConfig.useSupabaseCatalog ? 'Supabase' : 'lokal (bawaan)',
          ),
          _Baris(
            label: 'Penulisan pesanan',
            nilai: BackendConfig.useSupabaseBooking
                ? (BackendConfig.writeFirestore
                    ? 'Supabase + Firestore (dual)'
                    : 'Supabase')
                : 'Firestore',
          ),
          _Baris(
            label: 'Pembayaran online',
            nilai: BackendConfig.paymentsEnabled ? 'AKTIF' : 'nonaktif',
            sorot: BackendConfig.paymentsEnabled,
          ),
          FutureBuilder<bool>(
            future: MessagingService.tokenTerdaftar(),
            builder: (context, snap) {
              final teks = snap.hasData
                  ? (snap.data! ? 'terdaftar' : 'belum terdaftar')
                  : 'memeriksa…';
              return _Baris(label: 'Notifikasi (FCM)', nilai: teks);
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Salin ringkasan'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _teksRingkasan));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ringkasan backend disalin.')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Satu baris label → nilai pada kartu diagnostik.
class _Baris extends StatelessWidget {
  const _Baris({required this.label, required this.nilai, this.sorot = false});

  final String label;
  final String nilai;
  final bool sorot;

  @override
  Widget build(BuildContext context) {
    final warna = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              nilai,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: sorot ? FontWeight.bold : FontWeight.w500,
                color: sorot ? warna.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pilihan ini benar-benar dipakai aplikasi: mata uang mengganti simbol pada
/// semua harga, bahasa mengganti locale (nama hari/bulan + dialog tanggal).
class _PreferensiCard extends StatelessWidget {
  const _PreferensiCard();

  static String _labelMataUang(String kode) => switch (kode) {
    'IDR' => 'IDR - Rupiah Indonesia (Rp)',
    _ => kode,
  };

  static String _labelBahasa(String kode) => switch (kode) {
    'id' => 'Indonesia',
    'en' => 'English',
    _ => kode,
  };

  Future<void> _pilih(
    BuildContext context, {
    required String judul,
    required List<String> pilihan,
    required String terpilih,
    required String Function(String) label,
    required Future<void> Function(String) onPilih,
  }) async {
    final hasil = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(judul),
        children: [
          // RadioGroup: API pilihan tunggal terbaru Flutter (groupValue &
          // onChanged tidak lagi dipasang pada tiap RadioListTile).
          RadioGroup<String>(
            groupValue: terpilih,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final kode in pilihan)
                  RadioListTile<String>(value: kode, title: Text(label(kode))),
              ],
            ),
          ),
        ],
      ),
    );
    if (hasil != null) await onPilih(hasil);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: PreferencesService.mataUang,
      builder: (context, mataUangKode, _) => ValueListenableBuilder<String>(
        valueListenable: PreferencesService.bahasa,
        builder: (context, bahasaKode, __) => Card(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Preferensi',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.attach_money,
                  color: AppTheme.primary,
                ),
                title: const Text('Mata Uang'),
                subtitle: Text(_labelMataUang(mataUangKode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pilih(
                  context,
                  judul: 'Pilih Mata Uang',
                  pilihan: PreferencesService.daftarMataUang,
                  terpilih: mataUangKode,
                  label: _labelMataUang,
                  onPilih: PreferencesService.setMataUang,
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.translate, color: AppTheme.primary),
                title: const Text('Bahasa'),
                subtitle: Text(_labelBahasa(bahasaKode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pilih(
                  context,
                  judul: 'Pilih Bahasa',
                  pilihan: PreferencesService.daftarBahasa,
                  terpilih: bahasaKode,
                  label: _labelBahasa,
                  onPilih: PreferencesService.setBahasa,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
