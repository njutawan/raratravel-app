#!/usr/bin/env python3
"""Tiruan Supabase (PostgREST + Storage) di atas PostgreSQL 16 sungguhan.

Dipakai harness uji Edge Function (tools/e2e/run_e2e.ts). Tujuannya: fungsi
TypeScript dapat benar-benar DIJALANKAN di lingkungan yang mendekati produksi,
lalu hasilnya diperiksa — bukan hanya dibaca.

Yang ditiru:
  * POST/GET /rest/v1/rpc/<fungsi>   → `select public.<fungsi>(p_x => ...)`
                                       (nama argumen wajib sama, seperti PostgREST)
  * GET /rest/v1/<tabel>?col=eq.nilai → select sederhana (dipakai selectOne)
  * Storage: tautan unggah/unduh bertanda tangan + unggah langsung
  * POST /_test/sql                  → SQL bebas (khusus penyiapan uji)

Keluaran pertama ke stdout: satu baris JSON {"port": <angka>} lalu "READY".
"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/..")
import db_check  # noqa: E402  (perkakas migrasi yang sama dengan uji database)

REPO = db_check.REPO
DATA_DIR = os.environ.get("E2E_DATA_DIR", "/tmp/e2e-data")

import pgserver  # noqa: E402
import psycopg  # noqa: E402
from psycopg.types.json import Jsonb  # noqa: E402

LOCK = threading.Lock()
SERVER = pgserver.get_server(DATA_DIR)
DSN = SERVER.get_uri()

_berkas: dict[str, bytes] = {}


def siapkan_database() -> None:
    migrasi = sorted(
        __import__("glob").glob(os.path.join(REPO, "supabase", "migrations", "*.sql"))
    )
    with psycopg.connect(DSN, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute("drop schema if exists public cascade; create schema public;")
            cur.execute(db_check.STUB)
            cur.execute("drop table if exists storage.objects;")
            cur.execute("drop table if exists storage.buckets;")
            cur.execute(db_check.STUB)
            for path in migrasi:
                cur.execute(db_check.strip_unsupported(open(path, encoding="utf-8").read()))


# ---------------------------------------------------------------------------
# Nilai → tipe PostgreSQL
# ---------------------------------------------------------------------------
def _cast(tipe: str) -> str:
    """Pakai tipe yang dideklarasikan apa adanya.

    PostgREST mencocokkan nama fungsi + nama argumen lalu MENCAST nilai JSON ke
    tipe yang dideklarasikan; cast yang berbeda (mis. integer → bigint) tidak
    akan menemukan fungsinya. Karena itu tiruan ini harus sama.
    """
    return tipe.strip()


def _nilai(tipe: str, value):
    if value is None:
        return None
    tipe = tipe.strip().lower()
    if tipe == "jsonb":
        return Jsonb(value if not isinstance(value, str) else json.loads(value))
    if tipe.endswith("[]"):
        if isinstance(value, list):
            return [None if v is None else str(v) for v in value]
        return json.loads(value)
    if tipe == "boolean":
        if isinstance(value, bool):
            return value
        return str(value).lower() in ("true", "1", "ya", "yes")
    if tipe in ("integer", "bigint", "smallint", "numeric", "double precision", "real"):
        return value if isinstance(value, (int, float)) else (None if value == "" else value)
    return value if isinstance(value, str) else json.dumps(value)


def tanda_tangan(cur, nama: str) -> dict[str, str] | None:
    cur.execute(
        """
        select coalesce(p.proargnames, '{}'::text[]),
               coalesce((select array_agg(format_type(t, null) order by ord)
                           from unnest(p.proargtypes::oid[]) with ordinality as u(t, ord)), '{}'::text[])
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = %s and p.prokind = 'f'
         limit 1
        """,
        (nama,),
    )
    row = cur.fetchone()
    if not row:
        return None
    nama_arg, tipe_arg = row
    return {a: t for a, t in zip(nama_arg, tipe_arg) if a}


def panggil_rpc(nama: str, params: dict) -> tuple[int, object]:
    with LOCK, psycopg.connect(DSN, autocommit=True) as conn:
        with conn.cursor() as cur:
            arg = tanda_tangan(cur, nama)
            if arg is None:
                return 404, {
                    "code": "PGRST202",
                    "message": f"Could not find the function public.{nama} in the schema cache",
                }
            salah = [k for k in params if k not in arg]
            if salah:
                return 404, {
                    "code": "PGRST202",
                    "message": (
                        f"Could not find the function public.{nama} with parameters "
                        f"{', '.join(sorted(params))} (tersedia: {', '.join(sorted(arg))})"
                    ),
                }
            potongan = []
            nilai = []
            for k, v in params.items():
                potongan.append(f"{k} => %s::{_cast(arg[k])}")
                nilai.append(_nilai(arg[k], v))
            sql = f"select public.{nama}({', '.join(potongan)})"
            try:
                cur.execute(sql, nilai)
                hasil = cur.fetchone()[0]
                return 200, hasil
            except psycopg.Error as exc:
                detail = getattr(exc.diag, "message_detail", None)
                return 400, {
                    "code": exc.sqlstate or "P0001",
                    "message": str(exc).strip().splitlines()[0],
                    "details": detail,
                    "hint": None,
                }


def pilih_tabel(tabel: str, query: dict) -> tuple[int, object]:
    kolom = query.get("select", "*")
    limit = int(query.get("limit", "1"))
    if not re.fullmatch(r"[A-Za-z0-9_,* ]+", kolom):
        return 400, {"code": "PGRST100", "message": "kolom tidak sah"}
    if not re.fullmatch(r"[a-z_]+", tabel):
        return 400, {"code": "PGRST100", "message": "tabel tidak sah"}
    where, nilai = [], []
    for k, v in query.items():
        if k in ("select", "limit", "order"):
            continue
        if isinstance(v, str) and v.startswith("eq."):
            if not re.fullmatch(r"[a-z_]+", k):
                return 400, {"code": "PGRST100", "message": "filter tidak sah"}
            where.append(f"{k} = %s")
            nilai.append(v[3:])
    sql = f"select {kolom} from public.{tabel}"
    if where:
        sql += " where " + " and ".join(where)
    sql += " limit %s"
    nilai.append(limit)
    with LOCK, psycopg.connect(DSN, autocommit=True) as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(sql, nilai)
                rows = cur.fetchall()
                nama_kolom = [d.name for d in cur.description]
                return 200, [dict(zip(nama_kolom, r)) for r in rows]
            except psycopg.Error as exc:
                return 400, {"code": exc.sqlstate or "P0001", "message": str(exc)}


def jalankan_sql(sql: str, params: list | None = None) -> tuple[int, object]:
    with LOCK, psycopg.connect(DSN, autocommit=True) as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(sql, params or [])
                if cur.description is None:
                    return 200, {"ok": True, "rowcount": cur.rowcount}
                nama_kolom = [d.name for d in cur.description]
                return 200, [dict(zip(nama_kolom, r)) for r in cur.fetchall()]
            except psycopg.Error as exc:
                return 400, {"code": exc.sqlstate or "P0001", "message": str(exc)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):  # senyap
        pass

    # -- util --------------------------------------------------------------
    def _kirim(self, status: int, body: object) -> None:
        data = json.dumps(body, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> bytes:
        panjang = int(self.headers.get("content-length") or 0)
        return self.rfile.read(panjang) if panjang else b""

    # -- rute --------------------------------------------------------------
    def do_GET(self):  # noqa: N802
        self._tangani("GET")

    def do_POST(self):  # noqa: N802
        self._tangani("POST")

    def do_PUT(self):  # noqa: N802
        self._tangani("PUT")

    def _tangani(self, metode: str) -> None:
        parsed = urlparse(self.path)
        jalur = unquote(parsed.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        body = self._body()

        # --- simpanan berkas -------------------------------------------------
        if jalur.startswith("/storage/v1/object/upload/sign/") and metode == "POST":
            sisa = jalur[len("/storage/v1/object/upload/sign/"):]
            return self._kirim(200, {"url": f"/object/upload/sign/{sisa}?token=uji-token", "token": "uji-token"})

        if jalur.startswith("/storage/v1/object/upload/sign/") and metode == "PUT":
            sisa = jalur[len("/storage/v1/object/upload/sign/"):]
            _berkas[sisa] = body
            return self._kirim(200, {"Key": sisa})

        if jalur.startswith("/storage/v1/object/sign/") and metode == "POST":
            sisa = jalur[len("/storage/v1/object/sign/"):]
            return self._kirim(200, {"signedURL": f"/object/sign/{sisa}?token=uji-token"})

        if jalur.startswith("/storage/v1/object/public/"):
            sisa = jalur[len("/storage/v1/object/public/"):]
            return self._kirim(200, {"public": sisa, "tersimpan": sisa in _berkas})

        if jalur.startswith("/storage/v1/object/") and metode == "POST":
            sisa = jalur[len("/storage/v1/object/"):]
            _berkas[sisa] = body
            return self._kirim(200, {"Key": sisa})

        # --- PostgREST -------------------------------------------------------
        if jalur.startswith("/rest/v1/rpc/") and metode in ("POST", "GET"):
            nama = jalur[len("/rest/v1/rpc/"):]
            if metode == "POST":
                params = json.loads(body.decode("utf-8")) if body else {}
            else:
                params = {}
                for k, v in query.items():
                    params[k] = None if v == "" else v
            status, hasil = panggil_rpc(nama, params)
            return self._kirim(status, hasil)

        if jalur.startswith("/rest/v1/") and metode == "GET":
            status, hasil = pilih_tabel(jalur[len("/rest/v1/"):], query)
            return self._kirim(status, hasil)

        # --- khusus uji ------------------------------------------------------
        if jalur == "/_test/sql" and metode == "POST":
            payload = json.loads(body.decode("utf-8")) if body else {}
            status, hasil = jalankan_sql(payload.get("sql", ""), payload.get("params"))
            return self._kirim(status, hasil)

        self._kirim(404, {"kod": "tidak_ada", "path": jalur})


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    siapkan_database()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(json.dumps({"port": httpd.server_address[1]}), flush=True)
    print("READY", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
