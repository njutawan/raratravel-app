import 'package:flutter/foundation.dart';

import '../config/backend_config.dart';
import '../data/dummy_data.dart';
import '../models/armada.dart';
import '../models/travel_route.dart';
import '../models/wisata_paket.dart';
import '../services/edge_client.dart';

/// Halaman katalog (rute/paket) beserta informasi pagination.
class CatalogPage<T> {
  final List<T> items;
  final int total;
  final int limit;
  final int offset;

  const CatalogPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  bool get hasMore => offset + items.length < total;
}

/// Katalog dari Supabase (`search-routes`), dengan data lokal sebagai cadangan.
///
/// Tujuannya agar admin bisa mengubah rute, harga, dan jadwal tanpa merilis
/// ulang aplikasi. Bila server tidak dapat dihubungi, aplikasi tetap memakai
/// data bawaan (lib/data/dummy_data.dart) seperti sebelumnya.
class CatalogRepository {
  static bool get enabled => BackendConfig.useSupabaseCatalog && EdgeClient.ready;

  // Cache singkat di memori: berpindah layar tidak memanggil server berulang.
  static final Map<String, _CacheEntry> _cache = {};
  static const _cacheDuration = Duration(minutes: 5);

  /// Cari rute (pencarian utama aplikasi).
  static Future<CatalogPage<TravelRoute>> searchRoutes({
    String? asal,
    String? tujuan,
    DateTime? tanggal,
    int penumpang = 1,
    String? q,
    String sort = 'popular',
    int limit = 20,
    int offset = 0,
  }) async {
    final filter = 'search|$asal|$tujuan|${_tanggal(tanggal)}|$penumpang|$q|$sort|$limit|$offset';

    if (!enabled) {
      return _lokal(asal: asal, tujuan: tujuan, limit: limit, offset: offset);
    }

    try {
      final hasil = await _invoke('search-routes', {
        'action': 'search',
        'origin': asal,
        'destination': tujuan,
        if (tanggal != null) 'date': _tanggal(tanggal),
        'passengers': penumpang,
        'q': q,
        'sort': sort,
        'limit': limit,
        'offset': offset,
      }, cacheKey: filter);

      final daftar = (hasil['items'] as List?) ?? const [];
      return CatalogPage(
        items: daftar
            .whereType<Map>()
            .map((item) => _ruteDariServer(Map<String, dynamic>.from(item)))
            .toList(),
        total: (hasil['total'] as num?)?.toInt() ?? daftar.length,
        limit: (hasil['limit'] as num?)?.toInt() ?? limit,
        offset: (hasil['offset'] as num?)?.toInt() ?? offset,
      );
    } catch (e) {
      debugPrint('Katalog: gagal memuat dari server, memakai data lokal ($e)');
      return _lokal(asal: asal, tujuan: tujuan, limit: limit, offset: offset);
    }
  }

  /// Detail satu rute (slug/id rute).
  static Future<TravelRoute?> routeDetail(String key) async {
    if (!enabled) {
      for (final rute in DummyData.routes) {
        if (rute.id == key) return rute;
      }
      return null;
    }

    try {
      final hasil = await _invoke('search-routes', {
        'action': 'detail',
        'key': key,
      }, cacheKey: 'detail|$key');

      final rute = hasil['route'];
      if (rute is! Map) return null;
      return _ruteDariServer(Map<String, dynamic>.from(rute), detail: true);
    } catch (e) {
      debugPrint('Katalog: detail rute gagal ($e)');
      return null;
    }
  }

  /// Daftar kota untuk filter asal/tujuan.
  static Future<List<String>> cities() async {
    if (!enabled) return DummyData.routes.map((r) => r.asal).toSet().toList();

    try {
      final hasil = await _invoke('search-routes', {'action': 'cities'}, cacheKey: 'cities');
      final daftar = (hasil['items'] as List?) ?? const [];
      return daftar
          .whereType<Map>()
          .map((item) => (item['name'] ?? '').toString())
          .where((nama) => nama.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Katalog: daftar kota gagal ($e)');
      return DummyData.routes.map((r) => r.asal).toSet().toList();
    }
  }

  /// Paket sewa mobil.
  static Future<List<Armada>> rentals({String? kota, String? q, int limit = 30}) async {
    if (!enabled) return DummyData.armada;

    try {
      final hasil = await _invoke('search-routes', {
        'action': 'rentals',
        'city': kota,
        'q': q,
        'limit': limit,
      }, cacheKey: 'rentals|$kota|$q|$limit');

      final daftar = (hasil['items'] as List?) ?? const [];
      if (daftar.isEmpty) return DummyData.armada;
      return daftar
          .whereType<Map>()
          .map((item) => _armadaDariServer(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      debugPrint('Katalog: sewa mobil gagal ($e)');
      return DummyData.armada;
    }
  }

  /// Paket wisata.
  static Future<List<WisataPaket>> tours({String? q, int limit = 30}) async {
    if (!enabled) return DummyData.wisata;

    try {
      final hasil = await _invoke('search-routes', {
        'action': 'tours',
        'q': q,
        'limit': limit,
      }, cacheKey: 'tours|$q|$limit');

      final daftar = (hasil['items'] as List?) ?? const [];
      if (daftar.isEmpty) return DummyData.wisata;
      return daftar
          .whereType<Map>()
          .map((item) => _wisataDariServer(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      debugPrint('Katalog: paket wisata gagal ($e)');
      return DummyData.wisata;
    }
  }

  /// Bersihkan cache (dipakai saat admin mengubah katalog / pull-to-refresh).
  static void clearCache() => _cache.clear();

  // -------------------------------------------------------------------------
  // Panggilan + cache
  // -------------------------------------------------------------------------
  static Future<Map<String, dynamic>> _invoke(
    String function,
    Map<String, dynamic> body, {
    required String cacheKey,
  }) async {
    final tersimpan = _cache[cacheKey];
    if (tersimpan != null && !tersimpan.kadaluwarsa) {
      return tersimpan.data;
    }

    final hasil = await EdgeClient.invoke(function, body: body);
    _cache[cacheKey] = _CacheEntry(hasil, DateTime.now().add(_cacheDuration));
    return hasil;
  }

  static CatalogPage<TravelRoute> _lokal({
    String? asal,
    String? tujuan,
    int limit = 20,
    int offset = 0,
  }) {
    final cocok = DummyData.routes.where((rute) {
      final asalCocok = asal == null || asal.isEmpty || rute.asal == asal;
      final tujuanCocok = tujuan == null || tujuan.isEmpty || rute.tujuan == tujuan;
      return asalCocok && tujuanCocok;
    }).toList();

    final potong = cocok.skip(offset).take(limit).toList();
    return CatalogPage(
      items: potong,
      total: cocok.length,
      limit: limit,
      offset: offset,
    );
  }

  static String? _tanggal(DateTime? tanggal) {
    if (tanggal == null) return null;
    return '${tanggal.year}-${tanggal.month.toString().padLeft(2, '0')}-'
        '${tanggal.day.toString().padLeft(2, '0')}';
  }

  // -------------------------------------------------------------------------
  // Pemetaan balasan server → model aplikasi
  // -------------------------------------------------------------------------
  static TravelRoute _ruteDariServer(
    Map<String, dynamic> json, {
    bool detail = false,
  }) {
    final jadwal = <String>[];
    final hargaPerJam = <String, int>{};
    final daftarJadwal = (json['schedules'] as List?) ?? const [];
    for (final item in daftarJadwal) {
      if (item is! Map) continue;
      final jam = (item['departure_time_label'] ?? '').toString();
      if (jam.isEmpty) continue;
      if (!jadwal.contains(jam)) jadwal.add(jam);
      // Harga bisa berbeda per jam (mis. jadwal akhir pekan lebih mahal).
      final hargaJam = (item['price'] as num?)?.toInt();
      if (hargaJam != null) hargaPerJam[jam] = hargaJam;
    }
    // Detail rute memuat pola jam; pencarian memakai jadwal yang tersedia.
    if (jadwal.isEmpty) {
      for (final jam in (json['departure_times'] as List?) ?? const []) {
        final label = jam.toString().replaceAll(':', '.');
        if (!jadwal.contains(label)) jadwal.add(label);
      }
    }

    final harga = (json['price_from'] as num?)?.toInt() ??
        (json['base_price'] as num?)?.toInt() ??
        0;

    return TravelRoute(
      id: (json['slug'] ?? json['route_id'] ?? '').toString(),
      asal: (json['origin'] ?? '').toString(),
      tujuan: (json['destination'] ?? '').toString(),
      harga: harga,
      durasi: _durasi((json['duration_minutes'] as num?)?.toInt()),
      via: (json['via'] ?? '').toString(),
      jadwal: jadwal.isEmpty ? const ['06.00'] : jadwal,
      armada: ((json['vehicle_names'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(),
      fasilitas: ((json['facilities'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(),
      deskripsi: (json['description'] ?? '').toString(),
      populer: json['is_popular'] == true,
      hargaPerJam: hargaPerJam,
    );
  }

  static Armada _armadaDariServer(Map<String, dynamic> json) {
    final rawDesc = (json['description'] ?? '').toString();
    List<String> fitur = [];
    if (json['features'] is List) {
      fitur = (json['features'] as List).map((e) => e.toString()).toList();
    } else if (json['fitur'] is List) {
      fitur = (json['fitur'] as List).map((e) => e.toString()).toList();
    } else if (rawDesc.contains('Fasilitas:')) {
      final part = rawDesc.split('Fasilitas:').last;
      fitur = part.split(',').map((s) => s.replaceAll('.', '').trim()).where((s) => s.isNotEmpty).toList();
    }

    final hargaSewa = (json['price_driver'] as num?)?.toInt() ??
        (json['price_from'] as num?)?.toInt() ??
        0;
    final hargaLepasKunci = (json['price_self_drive'] as num?)?.toInt() ??
        (json['price_lepas_kunci'] as num?)?.toInt() ??
        0;

    var cleanDesc = rawDesc;
    if (cleanDesc.contains('Fasilitas:')) {
      cleanDesc = cleanDesc.split('Fasilitas:').first.trim();
    }

    var nama = (json['name'] ?? json['vehicle_name'] ?? '').toString();
    if (nama.contains(' + Sopir')) {
      nama = nama.split(' + Sopir').first.trim();
    }

    return Armada(
      id: (json['id'] ?? '').toString(),
      nama: nama,
      tipe: (json['vehicle_type'] ?? json['package_type'] ?? '').toString(),
      kapasitas: (json['seat_capacity'] as num?)?.toInt() ?? 0,
      hargaSewa: hargaSewa,
      hargaLepasKunci: hargaLepasKunci,
      fitur: fitur,
      deskripsi: cleanDesc,
    );
  }

  static WisataPaket _wisataDariServer(Map<String, dynamic> json) {
    final rawDesc = (json['description'] ?? '').toString();
    List<String> include = [];
    List<String> highlight = [];

    if (json['includes'] is List) {
      include = (json['includes'] as List).map((e) => e.toString()).toList();
    } else if (json['include'] is List) {
      include = (json['include'] as List).map((e) => e.toString()).toList();
    }

    if (json['highlights'] is List) {
      highlight = (json['highlights'] as List).map((e) => e.toString()).toList();
    } else if (json['highlight'] is List) {
      highlight = (json['highlight'] as List).map((e) => e.toString()).toList();
    }

    var cleanDesc = rawDesc;
    if (include.isEmpty && cleanDesc.contains('Termasuk:')) {
      final parts = cleanDesc.split('Termasuk:');
      cleanDesc = parts[0].trim();
      final rest = parts[1];
      if (rest.contains('Highlight:')) {
        final restParts = rest.split('Highlight:');
        include = restParts[0].split(',').map((s) => s.replaceAll('.', '').trim()).where((s) => s.isNotEmpty).toList();
        highlight = restParts[1].split(',').map((s) => s.replaceAll('.', '').trim()).where((s) => s.isNotEmpty).toList();
      } else {
        include = rest.split(',').map((s) => s.replaceAll('.', '').trim()).where((s) => s.isNotEmpty).toList();
      }
    } else if (highlight.isEmpty && cleanDesc.contains('Highlight:')) {
      final parts = cleanDesc.split('Highlight:');
      cleanDesc = parts[0].trim();
      highlight = parts[1].split(',').map((s) => s.replaceAll('.', '').trim()).where((s) => s.isNotEmpty).toList();
    }

    final durationDays = (json['duration_days'] as num?)?.toInt();
    final durasi = (json['duration_text'] ?? '').toString().isNotEmpty
        ? (json['duration_text'] ?? '').toString()
        : _durasiHari(durationDays);

    final tipe = (json['package_type'] ?? json['type'] ?? 'Open Trip').toString();

    return WisataPaket(
      id: (json['id'] ?? '').toString(),
      nama: (json['name'] ?? '').toString(),
      lokasi: (json['destination'] ?? '').toString(),
      harga: (json['price_from'] as num?)?.toInt() ?? 0,
      durasi: durasi,
      tipe: tipe,
      include: include,
      highlight: highlight,
      deskripsi: cleanDesc,
    );
  }

  static String _durasi(int? menit) {
    if (menit == null || menit <= 0) return '± 4–6 jam';
    final jam = (menit / 60).round();
    if (jam < 24) return '± $jam jam';
    final hari = (jam / 24).toStringAsFixed(1);
    return '± $hari hari';
  }

  static String _durasiHari(int? hari) {
    if (hari == null || hari <= 1) return '1 Hari';
    return '$hari Hari';
  }
}

class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime kedaluwarsa;

  _CacheEntry(this.data, this.kedaluwarsa);

  bool get kadaluwarsa => DateTime.now().isAfter(kedaluwarsa);
}
