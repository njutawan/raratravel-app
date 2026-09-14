#!/usr/bin/env python3
"""Uji lokal migrasi Supabase + RPC tanpa perlu Docker/Supabase CLI.

Menjalankan PostgreSQL 16 sungguhan di dalam proses Python (paket `pgserver`),
lalu:

  1. membuat tiruan objek Supabase (`auth.uid()`, `auth.jwt()`,
     `storage.objects`, peran `anon/authenticated/service_role`),
  2. menjalankan seluruh `supabase/migrations/*.sql` berurutan,
  3. menjalankan `tools/db_smoke_test.sql` (17 kelompok uji perilaku),
  4. memeriksa kesesuaian nama + parameter RPC yang dipanggil Edge Function
     dengan tanda tangan fungsi di database (PostgREST akan menolak nama yang
     tidak ada — kesalahan ini tidak terlihat sampai fungsi dijalankan).

Pemasangan (sekali):

  python3 -m venv /tmp/venv
  /tmp/venv/bin/pip install pgserver

Pemakaian, dari akar repositori:

  /tmp/venv/bin/python tools/db_check.py                 # migrasi + uji perilaku
  /tmp/venv/bin/python tools/db_check.py --migrasi-saja  # hanya migrasi
  /tmp/venv/bin/python tools/db_check.py --rpc           # hanya pemeriksaan RPC

Keluaran `SEMUA OK` berarti seluruh migrasi, uji perilaku, dan kesesuaian RPC
lulus. Berkas ini hanya untuk pengembangan — tidak dipakai saat produksi.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR_DEFAULT = os.environ.get("DB_CHECK_DIR", "/tmp/dbcheck")

# ---------------------------------------------------------------------------
# Tiruan objek milik Supabase (tidak ada di PostgreSQL biasa).
# ---------------------------------------------------------------------------
STUB = r"""
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then create role supabase_admin nologin superuser; end if;
end $$;

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

create or replace function auth.uid() returns uuid language sql stable as $fn$
  select nullif(current_setting('test.uid', true), '')::uuid;
$fn$;
create or replace function auth.role() returns text language sql stable as $fn$
  select coalesce(nullif(current_setting('test.role', true), ''), 'anon');
$fn$;
create or replace function auth.jwt() returns jsonb language sql stable as $fn$
  select coalesce(nullif(current_setting('test.jwt', true), ''), '{}')::jsonb;
$fn$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  owner uuid,
  public boolean not null default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
"""


def strip_unsupported(sql: str) -> str:
    """Buang CREATE EXTENSION: server uji lokal tanpa paket contrib Supabase."""
    return re.sub(
        r"create extension[^;]*;",
        "-- [db_check] create extension dilewati (server uji lokal)",
        sql,
        flags=re.I,
    )


# ---------------------------------------------------------------------------
# Pemeriksaan RPC ↔ Edge Function
# ---------------------------------------------------------------------------
def _kunci_tingkat_atas(sumber: str, mulai: int) -> list[str]:
    """Ambil nama kunci pada literal objek mulai posisi '{' (tanpa masuk ke dalam)."""
    kunci: list[str] = []
    depth = 0
    i = mulai
    expect_key = False
    while i < len(sumber):
        ch = sumber[i]
        if ch in "\"'`":
            kutip = ch
            j = i + 1
            teks = ""
            while j < len(sumber) and sumber[j] != kutip:
                if sumber[j] == "\\":
                    j += 1
                teks += sumber[j]
                j += 1
            if depth == 1 and expect_key and j + 1 < len(sumber) and sumber[j + 1] == ":":
                kunci.append(teks)
            i = j + 1
            expect_key = False
            continue
        if ch == "/" and i + 1 < len(sumber) and sumber[i + 1] == "/":
            while i < len(sumber) and sumber[i] != "\n":
                i += 1
            continue
        if ch in "{([":
            depth += 1
            expect_key = depth == 1
            i += 1
            continue
        if ch in "})]":
            depth -= 1
            if depth == 0:
                return kunci
            expect_key = False
            i += 1
            continue
        if ch == "," and depth == 1:
            expect_key = True
            i += 1
            continue
        if depth == 1 and expect_key and (ch.isalpha() or ch in "_$"):
            j = i
            while j < len(sumber) and (sumber[j].isalnum() or sumber[j] in "_$"):
                j += 1
            if j < len(sumber) and sumber[j] == ":":
                kunci.append(sumber[i:j])
            i = j
            expect_key = False
            continue
        i += 1
    return kunci


def panggilan_rpc(folder: str) -> list[dict]:
    """Cari semua rpc("nama", {...}) di berkas TypeScript Edge Function."""
    hasil: list[dict] = []
    pola = re.compile(r"\brpc\s*(?:<[^()]*>)?\s*\(\s*([\"'])([a-z_0-9]+)\1")
    for akar, _, berkas in os.walk(folder):
        for nama in berkas:
            if not nama.endswith(".ts"):
                continue
            path = os.path.join(akar, nama)
            sumber = open(path, encoding="utf-8").read()
            for m in pola.finditer(sumber):
                i = m.end()
                while i < len(sumber) and sumber[i].isspace():
                    i += 1
                if i < len(sumber) and sumber[i] == ",":
                    i += 1
                    while i < len(sumber) and sumber[i].isspace():
                        i += 1
                params: list[str] = []
                posisional = False
                if i < len(sumber) and sumber[i] == "{":
                    params = _kunci_tingkat_atas(sumber, i)
                elif i < len(sumber) and sumber[i] == "[":
                    posisional = True
                hasil.append(
                    {
                        "file": os.path.relpath(path, REPO),
                        "line": sumber[: m.start()].count("\n") + 1,
                        "fn": m.group(2),
                        "params": params,
                        "positional": posisional,
                    }
                )
    return hasil


def tanda_tangan_fungsi(cur) -> dict:
    cur.execute(
        """
        select p.proname,
               coalesce(p.proargnames, '{}'::text[]) as argnames,
               p.pronargdefaults,
               pg_get_function_arguments(p.oid)
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.prokind = 'f'
        """
    )
    hasil = {}
    for nama, argnames, jumlah_default, tanda_tangan in cur.fetchall():
        nama_arg = [a for a in (argnames or []) if a]
        berdefault = set(nama_arg[len(nama_arg) - jumlah_default :]) if jumlah_default else set()
        hasil[nama] = {
            "args": [{"name": a, "has_default": a in berdefault} for a in nama_arg],
            "signature": tanda_tangan,
        }
    return hasil


def periksa_rpc(cur) -> int:
    fungsi = tanda_tangan_fungsi(cur)
    panggilan = panggilan_rpc(os.path.join(REPO, "supabase", "functions"))
    masalah: list[str] = []
    nama_unik: set[str] = set()

    for call in panggilan:
        nama = call["fn"]
        nama_unik.add(nama)
        if nama not in fungsi:
            masalah.append(f"FUNGSI TIDAK ADA  {call['file']}:{call['line']} → {nama}()")
            continue
        if call["positional"]:
            continue
        tersedia = {a["name"] for a in fungsi[nama]["args"] if a["name"]}
        wajib = {a["name"] for a in fungsi[nama]["args"] if a["name"] and not a["has_default"]}
        dikirim = set(call["params"])
        tidak_ada = sorted(dikirim - tersedia)
        kurang = sorted(wajib - dikirim)
        if tidak_ada:
            masalah.append(
                f"PARAM SALAH       {call['file']}:{call['line']} → {nama}(): "
                f"tidak ada di database {tidak_ada} (tersedia: {sorted(tersedia)})"
            )
        if kurang:
            masalah.append(
                f"PARAM KURANG      {call['file']}:{call['line']} → {nama}(): wajib diisi {kurang}"
            )
        if len(dikirim) > len(fungsi[nama]["args"]):
            masalah.append(
                f"PARAM BERLEBIH    {call['file']}:{call['line']} → {nama}(): "
                f"{len(dikirim)} argumen > {len(fungsi[nama]['args'])}"
            )

    print(f"— RPC dipakai Edge Function: {len(nama_unik)} fungsi, {len(panggilan)} panggilan")
    for nama in masalah:
        print("   ", nama)
    if masalah:
        print(f"RPC GAGAL ({len(masalah)} masalah)")
        return 1
    print("RPC OK (nama + parameter cocok dengan database)")
    return 0


# ---------------------------------------------------------------------------
# Jalankan migrasi + uji perilaku
# ---------------------------------------------------------------------------
def jalankan(data_dir: str, migrasi_saja: bool, hanya_rpc: bool) -> int:
    try:
        import pgserver
        import psycopg
    except ImportError:  # pragma: no cover
        print(
            "Paket pgserver/psycopg belum terpasang. Jalankan:\n"
            "  python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pgserver"
        )
        return 1

    migrasi = sorted(glob.glob(os.path.join(REPO, "supabase", "migrations", "*.sql")))
    if not migrasi:
        print("Tidak ada berkas migrasi ditemukan.")
        return 1

    server = pgserver.get_server(data_dir)
    rc = 0
    with psycopg.connect(server.get_uri(), autocommit=True) as conn:
        with conn.cursor() as cur:
            if not hanya_rpc:
                cur.execute("drop schema if exists public cascade; create schema public;")
                cur.execute(STUB)
                cur.execute("drop table if exists storage.objects;")
                cur.execute("drop table if exists storage.buckets;")
                cur.execute(STUB)

                for path in migrasi:
                    sql = strip_unsupported(open(path, encoding="utf-8").read())
                    nama = os.path.basename(path)
                    try:
                        cur.execute(sql)
                        print(f"OK    {nama}")
                    except Exception as exc:  # noqa: BLE001
                        rc = 1
                        print(f"GAGAL {nama}\n      {str(exc).strip().splitlines()[0]}")

                if rc == 0 and not migrasi_saja:
                    uji = os.path.join(REPO, "tools", "db_smoke_test.sql")
                    try:
                        cur.execute(open(uji, encoding="utf-8").read())
                        print(f"OK    {os.path.basename(uji)} (uji perilaku)")
                    except Exception as exc:  # noqa: BLE001
                        rc = 1
                        print(f"GAGAL {os.path.basename(uji)}\n      {str(exc).strip()}")

            if rc == 0:
                print("")
                rc = periksa_rpc(cur) or rc

    if rc == 0:
        bagian = ["migrasi"]
        if not migrasi_saja and not hanya_rpc:
            bagian.append("uji perilaku")
        bagian.append("RPC")
        print(f"\nSEMUA OK ({len(migrasi)} migrasi, {' + '.join(bagian)})")
    return rc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default=DATA_DIR_DEFAULT, help="folder data PostgreSQL uji")
    parser.add_argument("--migrasi-saja", action="store_true", help="jangan jalankan uji perilaku")
    parser.add_argument("--rpc", action="store_true", help="hanya periksa kecocokan RPC dengan Edge Function")
    args = parser.parse_args()
    return jalankan(args.dir, args.migrasi_saja, args.rpc)


if __name__ == "__main__":
    sys.exit(main())
