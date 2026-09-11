/// Model armada / mobil sewa.
class Armada {
  final String id;
  final String nama;
  final String tipe; // MPV, SUV, Van, Minibus
  final int kapasitas; // jumlah penumpang
  final int hargaSewa; // sewa harian + sopir (Rp)
  final int hargaLepasKunci; // 0 jika tidak tersedia
  final List<String> fitur;
  final String deskripsi;

  const Armada({
    required this.id,
    required this.nama,
    required this.tipe,
    required this.kapasitas,
    required this.hargaSewa,
    this.hargaLepasKunci = 0,
    required this.fitur,
    required this.deskripsi,
  });
}
