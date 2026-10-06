#!/usr/bin/env python3
"""scan_secrets.py — pemindai rahasia untuk berkas yang dilacak git.

Dipakai `tools/release_gate.sh` (dan bisa dipanggil sendiri):

    git ls-files -z | xargs -0 python3 tools/scan_secrets.py
    python3 tools/scan_secrets.py firestore.rules lib/main.dart

Yang dilaporkan HANYA pola yang benar-benar berisi kunci, supaya tidak menuduh:
  * kode yang MEMBACA kunci (mis. `fcm.ts` memuat string "-----BEGIN PRIVATE KEY-----"),
  * kunci tiruan di harness uji (`sb_secret_kunci-uji-…`),
  * berkas contoh (`*.example`) yang memang berisi placeholder.

Aturan:
  1. Blok PEM kunci privat yang diikuti base64 panjang (kunci sungguhan).
  2. JSON service account (`"private_key": "-----BEGIN … \\nMII…"`).
  3. `sb_secret_…` / `sk_live_…` / `xoxb-…` dengan panjang nyata, tanpa penanda uji.
  4. JWT yang payload-nya memuat `"role":"service_role"` (kunci server Supabase lama).
  5. Berkas JSON bertipe `service_account` lengkap dengan `client_email` + `private_key`.

Keluar: satu baris per temuan `berkas:baris: <label>`; kode keluar 0 selalu
(daftar temuan dibaca pemanggil). Berkas biner & >2 MB dilewati.
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys

# Penanda fixture/contoh: nilai yang memuat kata ini dianggap bukan rahasia nyata.
PENANDA_UJI = re.compile(
    r"(uji|test|contoh|example|dummy|sample|fake|palsu|placeholder|xxx+|your[-_]?|isi[-_]?|<)",
    re.IGNORECASE,
)

PEM_PANJANG = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----\s*\n\s*[A-Za-z0-9+/=\s]{120,}", re.MULTILINE
)
SA_JSON = re.compile(
    r'"private_key"\s*:\s*"-----BEGIN [A-Z ]*PRIVATE KEY-----\\n[A-Za-z0-9+/=]{80,}'
)
SA_TYPE = re.compile(r'"type"\s*:\s*"service_account"')
KUNCI_POLA = [
    ("Supabase secret key", re.compile(r"\bsb_secret_[A-Za-z0-9_\-]{24,}")),
    ("Midtrans server key", re.compile(r"\bSB-Mid-server-[A-Za-z0-9]{16,}")),
    ("Stripe secret key", re.compile(r"\bsk_live_[A-Za-z0-9]{16,}")),
    ("Xendit secret key", re.compile(r"\bxnd_(?:development|production)_[A-Za-z0-9]{20,}")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}")),
    ("Supabase access token", re.compile(r"\bsbp_[A-Za-z0-9]{20,}")),
]
JWT_PANJANG = re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{6,}")

MAKS_BERKAS = 2 * 1024 * 1024


def b64url_decode(bagian: str) -> str:
    """Decode segmen JWT (tanpa padding) → teks, kosong bila gagal."""
    try:
        pad = "=" * (-len(bagian) % 4)
        return base64.urlsafe_b64decode(bagian + pad).decode("utf-8", "replace")
    except Exception:
        return ""


def jwt_service_role(token: str) -> bool:
    """True bila JWT ini kunci server Supabase (role service_role)."""
    seg = token.split(".")
    if len(seg) != 3:
        return False
    payload = b64url_decode(seg[1])
    if not payload:
        return False
    try:
        data = json.loads(payload)
    except Exception:
        return '"role":"service_role"' in payload.replace(" ", "")
    return str(data.get("role", "")).lower() == "service_role"


def garis_ke(teks: str, posisi: int) -> int:
    return teks.count("\n", 0, posisi) + 1


def pindai(jalur: str) -> list[str]:
    temuan: list[str] = []
    try:
        if os.path.getsize(jalur) > MAKS_BERKAS:
            return temuan
        with open(jalur, "rb") as f:
            awal = f.read(4096)
        if b"\x00" in awal:  # berkas biner
            return temuan
        with open(jalur, encoding="utf-8", errors="ignore") as f:
            teks = f.read()
    except (OSError, UnicodeError):
        return temuan

    nama = os.path.basename(jalur)
    if nama.endswith((".jks", ".keystore", ".p12", ".pfx", ".png", ".jpg", ".jar")):
        return temuan
    contoh = nama.endswith(".example") or ".example" in nama

    # 1. blok PEM kunci privat sungguhan
    for m in PEM_PANJANG.finditer(teks):
        temuan.append(f"{jalur}:{garis_ke(teks, m.start())}: kunci privat PEM (blok base64)")

    # 2. service account di dalam JSON (private_key ter-escape)
    for m in SA_JSON.finditer(teks):
        temuan.append(f"{jalur}:{garis_ke(teks, m.start())}: service account JSON (private_key)")

    # 3. berkas JSON service account utuh
    if SA_TYPE.search(teks) and '"client_email"' in teks and '"private_key"' in teks:
        temuan.append(f"{jalur}:1: berkas service account Firebase/GCP")

    # 4. kunci ber-prefix
    for label, pola in KUNCI_POLA:
        for m in pola.finditer(teks):
            nilai = m.group(0)
            if PENANDA_UJI.search(nilai):
                continue
            if contoh:
                continue
            temuan.append(f"{jalur}:{garis_ke(teks, m.start())}: {label}")

    # 5. JWT service_role
    for m in JWT_PANJANG.finditer(teks):
        if jwt_service_role(m.group(0)):
            temuan.append(f"{jalur}:{garis_ke(teks, m.start())}: JWT service_role Supabase")

    # Buang duplikat, jaga urutan.
    unik: list[str] = []
    for t in temuan:
        if t not in unik:
            unik.append(t)
    return unik


def main(argv: list[str]) -> int:
    if not argv:
        data = sys.stdin.read().split("\0") if not sys.stdin.isatty() else []
        argv = [x for x in data if x]
    semua: list[str] = []
    for jalur in argv:
        if not jalur or not os.path.isfile(jalur):
            continue
        semua.extend(pindai(jalur))
    for baris in semua:
        print(baris)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
