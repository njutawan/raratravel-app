/// Model paket wisata (open trip / private trip).
class WisataPaket {
  final String id;
  final String nama;
  final String lokasi;
  final int harga; // per pax (Rp)
  final String durasi; // mis. "1 Hari"
  final String tipe; // Open Trip / Private Trip
  final List<String> include;
  final List<String> highlight;
  final String deskripsi;

  const WisataPaket({
    required this.id,
    required this.nama,
    required this.lokasi,
    required this.harga,
    required this.durasi,
    this.tipe = 'Open Trip',
    this.include = const [],
    this.highlight = const [],
    this.deskripsi = '',
  });
}
