import 'package:flutter/material.dart';
import '../services/whatsapp_service.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/adaptive.dart';

/// Layar kirim paket kilat antar kota.
class PaketScreen extends StatefulWidget {
  const PaketScreen({super.key});

  @override
  State<PaketScreen> createState() => _PaketScreenState();
}

class _PaketScreenState extends State<PaketScreen> {
  final _formKey = GlobalKey<FormState>();
  String _asal = 'Jember';
  String _tujuan = 'Surabaya';
  final _barang = TextEditingController();
  final _berat = TextEditingController(text: '1');
  final _pengirim = TextEditingController();
  final _penerima = TextEditingController();
  final _telpPenerima = TextEditingController();

  @override
  void dispose() {
    _barang.dispose();
    _berat.dispose();
    _pengirim.dispose();
    _penerima.dispose();
    _telpPenerima.dispose();
    super.dispose();
  }

  /// Estimasi kasar (final ditentukan admin via WA).
  int get _estimasi {
    final berat = double.tryParse(_berat.text.replaceAll(',', '.')) ?? 1;
    final jauh =
        (_asal == 'Jakarta' ||
        _tujuan == 'Jakarta' ||
        _tujuan.contains('Bali') ||
        _asal.contains('Bali'));
    final base = jauh ? 80000 : 30000;
    final perKg = jauh ? 25000 : 12000;
    return (base + perKg * berat).round();
  }

  void _kirim() {
    if (!_formKey.currentState!.validate()) return;
    final msg = StringBuffer()
      ..writeln('Halo *Rara Travel & Tour*, saya mau kirim paket kilat:')
      ..writeln('')
      ..writeln('Rute: *$_asal → $_tujuan*')
      ..writeln('Barang: ${_barang.text.trim()}')
      ..writeln('Berat: ${_berat.text.trim()} kg')
      ..writeln('Pengirim: ${_pengirim.text.trim()}')
      ..writeln(
        'Penerima: ${_penerima.text.trim()} (${_telpPenerima.text.trim()})',
      )
      ..writeln('Estimasi: ${Formatters.idr(_estimasi)}')
      ..writeln('')
      ..writeln('Mohon info jadwal penjemputan paket. Terima kasih.');
    ExternalService.openWhatsApp(msg.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kirim Paket Kilat')),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: Adaptive.pagePadding(context),
            children: [
              Card(
                color: Colors.orange.shade50,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.bolt, color: Colors.orange),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Paket ikut armada travel — tiba di hari yang sama untuk rute Jember–Surabaya–Malang. Motor & dokumen juga bisa!',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _asal,
                      decoration: const InputDecoration(labelText: 'Dari'),
                      items: AppConstants.cities
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _asal = v!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _tujuan,
                      decoration: const InputDecoration(labelText: 'Ke'),
                      items: AppConstants.cities
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _tujuan = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _barang,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Jenis barang *',
                  hintText: 'cth. dokumen, oleh-oleh, sparepart',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Isi jenis barang' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _berat,
                textInputAction: TextInputAction.next,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Berat (kg) *',
                  prefixIcon: Icon(Icons.scale_outlined),
                ),
                validator: (v) {
                  final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                  if (d == null || d <= 0) return 'Isi berat yang valid';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _pengirim,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Nama pengirim *',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Isi nama pengirim'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _penerima,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Nama penerima *',
                  prefixIcon: Icon(Icons.person_add_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Isi nama penerima'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _telpPenerima,
                textInputAction: TextInputAction.done,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'No. HP penerima *',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                validator: (v) => (v == null || v.trim().length < 10)
                    ? 'Isi nomor HP valid'
                    : null,
              ),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Text(
                        'Estimasi Ongkir',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _berat,
                        builder: (_, __, ___) => Text(
                          Formatters.idr(_estimasi),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                'Estimasi kasar — tarif final & jadwal jemput dikonfirmasi admin.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.waGreen,
                  ),
                  onPressed: _kirim,
                  icon: const Icon(Icons.send),
                  label: const Text('Pesan Jemput Paket via WA'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
