#!/usr/bin/env python3
"""Isi lib/firebase_options.dart dari android/app/google-services.json.

Tidak butuh FlutterFire CLI. Dipakai tools/setup_firebase.sh langkah 5
bila json sudah diunduh dari Console.

  python3 tools/gen_firebase_options.py
  python3 tools/gen_firebase_options.py path/ke/google-services.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

AKAR = Path(__file__).resolve().parent.parent
JSON_BAWAAN = AKAR / "android" / "app" / "google-services.json"
DART_TUJUAN = AKAR / "lib" / "firebase_options.dart"
PACKAGE = "com.raratravel.app"


def q(nilai: str) -> str:
    return "'" + nilai.replace("\\", "\\\\").replace("'", "\\'") + "'"


def pilih_klien(data: dict) -> dict:
    klien = data.get("client") or []
    for c in klien:
        pkg = (
            ((c.get("client_info") or {}).get("android_client_info") or {}).get(
                "package_name"
            )
            or ""
        )
        if pkg == PACKAGE:
            return c
    if len(klien) == 1:
        return klien[0]
    raise SystemExit(
        f"Tidak ada client dengan package {PACKAGE} di google-services.json"
    )


def ekstrak(data: dict) -> dict:
    info = data.get("project_info") or {}
    klien = pilih_klien(data)
    kunci = ((klien.get("api_key") or [{}])[0]).get("current_key") or ""
    app_id = ((klien.get("client_info") or {}).get("mobilesdk_app_id")) or ""
    if not kunci or not app_id:
        raise SystemExit("google-services.json tidak lengkap (api_key / app_id kosong)")
    return {
        "project_id": info.get("project_id") or "",
        "project_number": str(info.get("project_number") or ""),
        "storage_bucket": info.get("storage_bucket") or "",
        "api_key": kunci,
        "app_id": app_id,
        "package": ((klien.get("client_info") or {}).get("android_client_info") or {}).get(
            "package_name"
        )
        or PACKAGE,
    }


def tulis_dart(nilai: dict) -> str:
    storage = (
        f"    storageBucket: {q(nilai['storage_bucket'])},\n" if nilai["storage_bucket"] else ""
    )
    return f"""// File ini dihasilkan dari android/app/google-services.json
// (tools/gen_firebase_options.py). Jangan edit manual — generate ulang
// jika json diganti (SHA baru / app baru).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {{
  static FirebaseOptions get currentPlatform {{
    if (kIsWeb) {{
      throw UnsupportedError('Rara Travel belum dikonfigurasi untuk web.');
    }}
    switch (defaultTargetPlatform) {{
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'Firebase belum dikonfigurasi untuk platform $defaultTargetPlatform.',
        );
    }}
  }}

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: {q(nilai['api_key'])},
    appId: {q(nilai['app_id'])},
    messagingSenderId: {q(nilai['project_number'])},
    projectId: {q(nilai['project_id'])},
{storage}  );
}}
"""


def main() -> int:
    sumber = Path(sys.argv[1]) if len(sys.argv) > 1 else JSON_BAWAAN
    if not sumber.is_file():
        print(f"Berkas tidak ada: {sumber}", file=sys.stderr)
        return 1
    data = json.loads(sumber.read_text(encoding="utf-8"))
    nilai = ekstrak(data)
    DART_TUJUAN.write_text(tulis_dart(nilai), encoding="utf-8")
    print(f"OK  project={nilai['project_id']}  package={nilai['package']}")
    print(f"    {DART_TUJUAN.relative_to(AKAR)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
