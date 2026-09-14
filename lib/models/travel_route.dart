/// Model rute travel reguler antar kota.
class TravelRoute {
  final String id;
  final String asal;
  final String tujuan;
  final int harga; // per kursi (Rp)
  final String durasi; // mis. "± 10–12 jam"
  final String via; // mis. "via Tol Trans Jawa"
  final List<String> jadwal; // mis. ["06.00", "19.00"]
  final List<String> armada;
  final List<String> fasilitas;
  final String deskripsi;
  final bool populer;

  /// Harga per jam keberangkatan (mis. jam 06.00 lebih mahal dari jam 19.00).
  /// Kosong = semua jam memakai [harga].
  final Map<String, int> hargaPerJam;

  const TravelRoute({
    required this.id,
    required this.asal,
    required this.tujuan,
    required this.harga,
    required this.durasi,
    required this.via,
    required this.jadwal,
    required this.armada,
    required this.fasilitas,
    required this.deskripsi,
    this.populer = false,
    this.hargaPerJam = const {},
  });

  String get title => '$asal – $tujuan';

  /// Harga satu kursi untuk jam keberangkatan terpilih.
  int hargaUntuk(String jam) => hargaPerJam[jam] ?? harga;

  TravelRoute copyWith({Map<String, int>? hargaPerJam}) => TravelRoute(
    id: id,
    asal: asal,
    tujuan: tujuan,
    harga: harga,
    durasi: durasi,
    via: via,
    jadwal: jadwal,
    armada: armada,
    fasilitas: fasilitas,
    deskripsi: deskripsi,
    populer: populer,
    hargaPerJam: hargaPerJam ?? this.hargaPerJam,
  );
}
