#!/usr/bin/env python3
"""Buat migrasi seed katalog dari data aplikasi (sumber tunggal: kode Flutter).

Menghasilkan supabase/migrations/202609140007_catalog_seed.sql dari:
  * lib/utils/constants.dart  → daftar kota + fasilitas standar
  * lib/data/dummy_data.dart  → rute, armada, paket wisata

Jalankan ulang setiap kali data di aplikasi berubah:
    python3 tools/generate_catalog_seed.py
lalu terapkan migrasinya (supabase db push). Sifat insert idempoten:
mengulang tidak menggandakan data — yang ada hanya diperbarui harganya.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONSTANTS = ROOT / "lib" / "utils" / "constants.dart"
DUMMY = ROOT / "lib" / "data" / "dummy_data.dart"
OUT = ROOT / "supabase" / "migrations" / "202609140007_catalog_seed.sql"


# ---------------------------------------------------------------------------
# Parser kecil untuk literal Dart (cukup untuk file data aplikasi ini)
# ---------------------------------------------------------------------------
def split_items(source: str, list_name: str) -> list[str]:
    """Ambil isi `static const List<T> <list_name> = [ ... ];` lalu pecah per item."""
    match = re.search(
        r"static const List<\w+>\s+" + list_name + r"\s*=\s*\[", source
    )
    if not match:
        raise SystemExit(f"tidak menemukan list {list_name}")
    start = match.end()
    depth = 1
    i = start
    while i < len(source) and depth > 0:
        char = source[i]
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
        i += 1
    body = source[start : i - 1]

    items: list[str] = []
    depth = 0
    current: list[str] = []
    for char in body:
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        if char == "," and depth == 0:
            text = "".join(current).strip()
            if text:
                items.append(text)
            current = []
            continue
        current.append(char)
    last = "".join(current).strip()
    if last:
        items.append(last)
    return items


def declared_list(source: str, name: str) -> list[str]:
    """Ambil daftar string dari deklarasi `name = [ ... ];` (mis. daftar kota)."""
    match = re.search(r"\b" + name + r"\s*=\s*\[", source)
    if not match:
        return []
    depth = 1
    i = match.end()
    while i < len(source) and depth > 0:
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
        i += 1
    body = source[match.end() : i - 1]
    return [unescape(v) for v in re.findall(r"'((?:[^'\\]|\\.)*)'", body)]


def field_string(item: str, key: str) -> str:
    match = re.search(
        key + r"\s*:\s*'((?:[^'\\]|\\.)*)'", item, re.DOTALL
    )
    return unescape(match.group(1)) if match else ""


def field_string_opt(item: str, key: str) -> str | None:
    return field_string(item, key) or None


def field_int(item: str, key: str) -> int | None:
    match = re.search(key + r"\s*:\s*(\d+)", item)
    return int(match.group(1)) if match else None


def field_bool(item: str, key: str) -> bool:
    match = re.search(key + r"\s*:\s*(true|false)", item)
    return bool(match and match.group(1) == "true")


def field_list(item: str, key: str) -> list[str]:
    match = re.search(key + r"\s*:\s*\[(.*?)\]", item, re.DOTALL)
    if not match:
        return []
    return [unescape(v) for v in re.findall(r"'((?:[^'\\]|\\.)*)'", match.group(1))]


def unescape(value: str) -> str:
    return value.replace("\\'", "'").replace("\\\\", "\\")


def sql_str(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def sql_array(values: list[str]) -> str:
    if not values:
        return "'{}'"
    joined = ",".join('"' + v.replace('"', '\\"') + '"' for v in values)
    return "'{" + joined + "}'"


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower())
    return slug.strip("-")


def duration_minutes(text: str) -> int | None:
    """'± 10–12 jam' → 720 (ambil angka pertama, menit)."""
    numbers = re.findall(r"\d+", text.replace("–", "-"))
    if not numbers:
        return None
    return int(numbers[0]) * 60


# ---------------------------------------------------------------------------
# Bangun SQL
# ---------------------------------------------------------------------------
def main() -> int:
    constants = CONSTANTS.read_text(encoding="utf-8")
    dummy = DUMMY.read_text(encoding="utf-8")

    cities = declared_list(constants, "cities")
    standard_facilities = declared_list(constants, "standardFacilities")
    route_items = split_items(dummy, "routes")
    armada_items = split_items(dummy, "armada")
    wisata_items = split_items(dummy, "wisata")

    lines: list[str] = []
    add = lines.append

    add("-- ============================================================================")
    add("-- 202609140007_catalog_seed.sql")
    add("-- Katalog awal: kota, rute, armada, sewa mobil, dan paket wisata.")
    add("--")
    add("-- DIHASILKAN OTOMATIS oleh tools/generate_catalog_seed.py dari data aplikasi")
    add("-- (lib/utils/constants.dart + lib/data/dummy_data.dart). Jangan diedit manual:")
    add("-- ubah data di aplikasi lalu jalankan ulang generatornya.")
    add("--")
    add("-- Semua insert idempoten (on conflict → update harga/jadwal), aman diulang.")
    add("-- ============================================================================")
    add("")

    # ---- Kota
    add("-- ---------------------------------------------------------------------------")
    add("-- Kota yang dilayani (urutan mengikuti daftar di aplikasi)")
    add("-- ---------------------------------------------------------------------------")
    for index, city in enumerate(cities, start=1):
        add(
            "insert into public.cities (name, slug, sort_order, is_active) values\n"
            f"  ({sql_str(city)}, {sql_str(slugify(city))}, {index * 10}, true)\n"
            "on conflict (lower(name)) do update\n"
            "  set slug = excluded.slug,\n"
            "      sort_order = excluded.sort_order,\n"
            "      is_active = true;"
        )
        add("")

    # ---- Armada (vehicles)
    add("-- ---------------------------------------------------------------------------")
    add("-- Armada")
    add("-- ---------------------------------------------------------------------------")
    for armada in armada_items:
        nama = field_string(armada, "nama")
        tipe = field_string(armada, "tipe")
        kapasitas = field_int(armada, "kapasitas") or 1
        add(
            "insert into public.vehicles (name, vehicle_type, seat_capacity, is_active) values\n"
            f"  ({sql_str(nama)}, {sql_str(tipe)}, {kapasitas}, true)\n"
            "on conflict (lower(name)) do update\n"
            "  set vehicle_type = excluded.vehicle_type,\n"
            "      seat_capacity = excluded.seat_capacity,\n"
            "      is_active = true;"
        )
        add("")

    # ---- Rute
    add("-- ---------------------------------------------------------------------------")
    add("-- Rute travel reguler (harga = harga dasar per kursi)")
    add("-- ---------------------------------------------------------------------------")
    for index, route in enumerate(route_items, start=1):
        asal = field_string(route, "asal")
        tujuan = field_string(route, "tujuan")
        harga = field_int(route, "harga") or 0
        durasi = duration_minutes(field_string(route, "durasi"))
        via = field_string_opt(route, "via")
        jadwal = field_list(route, "jadwal")
        armada = field_list(route, "armada")
        fasilitas = field_list(route, "fasilitas") or standard_facilities
        deskripsi = field_string(route, "deskripsi")
        populer = field_bool(route, "populer")
        # Kapasitas default = armada terkecil pada rute (kursi terjual paling cepat habis).
        kapasitas = 14

        add("insert into public.routes (")
        add("  origin_city_id, destination_city_id, slug, base_price, default_capacity,")
        add("  duration_minutes, via, departure_times, vehicle_names, facilities,")
        add("  description, is_popular, sort_order, is_active")
        add(") values (")
        add(f"  (select id from public.cities where lower(name) = lower({sql_str(asal)})),")
        add(f"  (select id from public.cities where lower(name) = lower({sql_str(tujuan)})),")
        add(f"  {sql_str(slugify(f'{asal} {tujuan}'))}, {harga}, {kapasitas},")
        add(f"  {durasi if durasi is not None else 'null'}, {sql_str(via)}, {sql_array(jadwal)}, {sql_array(armada)},")
        add(f"  {sql_array(fasilitas)},")
        add(f"  {sql_str(' '.join(deskripsi.split()))}, {str(populer).lower()}, {index * 10}, true")
        add(")")
        add("on conflict (origin_city_id, destination_city_id) where is_active do update")
        add("  set base_price = excluded.base_price,")
        add("      default_capacity = excluded.default_capacity,")
        add("      duration_minutes = excluded.duration_minutes,")
        add("      via = excluded.via,")
        add("      departure_times = excluded.departure_times,")
        add("      vehicle_names = excluded.vehicle_names,")
        add("      facilities = excluded.facilities,")
        add("      description = excluded.description,")
        add("      is_popular = excluded.is_popular,")
        add("      sort_order = excluded.sort_order;")
        add("")

    # ---- Sewa mobil
    add("-- ---------------------------------------------------------------------------")
    add("-- Sewa mobil (rental_packages + harga harian)")
    add("-- ---------------------------------------------------------------------------")
    for armada in armada_items:
        nama = field_string(armada, "nama")
        tipe = field_string(armada, "tipe")
        kapasitas = field_int(armada, "kapasitas") or 1
        harga_sewa = field_int(armada, "hargaSewa") or 0
        lepas_kunci = field_int(armada, "hargaLepasKunci") or 0
        fitur = field_list(armada, "fitur")
        deskripsi = field_string(armada, "deskripsi")

        add("with kota as (select id from public.cities where lower(name) = 'jember' limit 1),")
        add("armada as (")
        add(f"  select id from public.vehicles where lower(name) = lower({sql_str(nama)}) limit 1")
        add("),")
        add("paket as (")
        add("  insert into public.rental_packages (")
        add("    city_id, vehicle_id, name, package_type, duration_days, description, is_active")
        add("  )")
        add("  select kota.id, armada.id,")
        add(f"         {sql_str(nama + ' + Sopir (12 jam)')}, {sql_str(tipe)}, 1,")
        add(f"         {sql_str(' '.join(deskripsi.split()) + ' Fasilitas: ' + ', '.join(fitur) + '.')}, true")
        add("    from kota, armada")
        add("  on conflict (city_id, lower(name)) where is_active do update")
        add("    set vehicle_id = excluded.vehicle_id,")
        add("        package_type = excluded.package_type,")
        add("        description = excluded.description")
        add("  returning id")
        add(")")
        add("insert into public.rental_package_prices (rental_package_id, price, valid_from)")
        add("select paket.id, harga, current_date from paket, (values")
        if lepas_kunci:
            add(f"  ({harga_sewa}::numeric, 0),")
            add(f"  ({lepas_kunci}::numeric, 1)")
        else:
            add(f"  ({harga_sewa}::numeric, 0)")
        add(") as daftar(harga, urutan)")
        add("where not exists (")
        add("  select 1 from public.rental_package_prices p")
        add("  where p.rental_package_id = paket.id")
        add(");")
        add("")

    # ---- Paket wisata
    add("-- ---------------------------------------------------------------------------")
    add("-- Paket wisata")
    add("-- ---------------------------------------------------------------------------")
    for wisata in wisata_items:
        nama = field_string(wisata, "nama")
        lokasi = field_string(wisata, "lokasi")
        harga = field_int(wisata, "harga") or 0
        tipe = field_string(wisata, "tipe")
        include = field_list(wisata, "include")
        highlight = field_list(wisata, "highlight")
        deskripsi = field_string(wisata, "deskripsi")
        durasi_teks = field_string(wisata, "durasi")
        durasi_hari = 1
        match = re.search(r"(\d+)\s*Hari", durasi_teks)
        if match:
            durasi_hari = int(match.group(1))

        detail = " ".join(deskripsi.split())
        if include:
            detail += " Termasuk: " + ", ".join(include) + "."
        if highlight:
            detail += " Highlight: " + ", ".join(highlight) + "."

        add("with paket as (")
        add("  insert into public.tour_packages (")
        add("    name, destination, description, duration_days, is_active")
        add("  ) values (")
        add(f"    {sql_str(nama)}, {sql_str(lokasi)}, {sql_str(detail)}, {durasi_hari}, true")
        add("  )")
        add("  on conflict (lower(name)) where is_active do update")
        add("    set destination = excluded.destination,")
        add("        description = excluded.description,")
        add("        duration_days = excluded.duration_days")
        add("  returning id")
        add(")")
        add("insert into public.tour_package_prices (tour_package_id, price, valid_from)")
        add(f"select paket.id, {harga}, current_date from paket")
        add("where not exists (")
        add("  select 1 from public.tour_package_prices p where p.tour_package_id = paket.id")
        add(");")
        add(f"-- tipe: {tipe}")
        add("")

    OUT.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(
        f"seed ditulis: {OUT.relative_to(ROOT)} "
        f"(kota={len(cities)}, rute={len(route_items)}, armada={len(armada_items)}, wisata={len(wisata_items)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
