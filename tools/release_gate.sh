#!/usr/bin/env bash
# release_gate.sh — satu perintah: jalankan SEMUA pemeriksaan yang bisa
# dikerjakan dari dalam repo, lalu cetak status 6 tugas rilis.
#
#   bash tools/release_gate.sh            # semua pemeriksaan (±1–3 menit)
#   bash tools/release_gate.sh --cepat    # lewati yang berat (db / e2e / emulator)
#   bash tools/release_gate.sh --bantu    # penjelasan
#
# Yang diperiksa:
#   1. Rahasia tidak bocor ke git (service_role, kunci privat, keystore rilis)
#   2. Edge Function: impor/ekspor, 19 skenario e2e, bundel Dashboard tidak basi
#   3. Migrasi: 12 berkas + uji perilaku + kecocokan 31 RPC (PostgreSQL 16 asli)
#   4. firestore.rules: emulator (bila Java ada) atau status job CI
#   5. Keystore debug: SHA-1/256 cocok dengan SHA_FINGERPRINTS.txt + google-services.json
#   6. Artefak rilis: DATA_SAFETY.md, halaman hapus akun (syarat Play), .firebaserc
#   7. Kesiapan deploy: workflow deploy ada + secrets/variables Actions terpasang
#
# Keluar 0 bila semua pemeriksaan lokal lulus. Bagian yang butuh Console/kredensial
# TIDAK dinilai di sini — skrip mencetak perintah verifikasinya di tabel akhir.
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AKAR" || exit 1
CEPAT=0
GAGAL=0
LEWAT=0
BARIS_MATRIX=()

hijau()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul()  { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok()     { hijau "  ✔ $*"; }
info()   { printf '  · %s\n' "$*"; }
tolak()  { merah "  ✖ $*"; GAGAL=1; }
lewati() { kuning "  ↷ $*"; LEWAT=$((LEWAT+1)); }

while [ $# -gt 0 ]; do
  case "$1" in
    --cepat|--fast) CEPAT=1; shift ;;
    --bantu|--help|-h) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) merah "Argumen tidak dikenal: $1"; exit 2 ;;
  esac
done

python_venv() {
  local p
  for p in "${PYTHON:-}" "$AKAR/.venv/bin/python" "/tmp/venv/bin/python" \
           "$AKAR/.venv/Scripts/python.exe"; do
    [ -n "$p" ] && [ -x "$p" ] && "$p" -c 'import pgserver, psycopg' 2>/dev/null && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# ===========================================================================
judul "1. Rahasia & berkas sensitif di git"
# ===========================================================================
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bocor="$(git ls-files | grep -iE '(^|/)(key\.properties|.*\.(jks|p12|pfx))$|\.env\.(supabase|firebase)$|service-account.*\.json$' \
           | grep -v '^android/debug.keystore$' || true)"
  if [ -n "$bocor" ]; then
    tolak "berkas rahasia TER-COMMIT:"; printf '%s\n' "$bocor" | sed 's/^/      /'
    info "Hapus dari riwayat: git rm --cached <file> + filter-repo, lalu rotasi kuncinya."
  else
    ok "tidak ada keystore rilis / key.properties / .env / service account di git"
  fi
  # Pemindai rahasia: pola yang BENAR-BENAR berupa kunci (blok PEM berisi base64
  # panjang, atau sb_secret_ yang bukan fixture uji) — supaya kode yang MEMBACA
  # kunci (fcm.ts) dan kunci tiruan di harness uji tidak ikut dituduh.
  temuan_rahasia="$(git ls-files -z | xargs -0 python3 "$AKAR/tools/scan_secrets.py" 2>/dev/null || true)"
  if [ -n "$temuan_rahasia" ]; then
    tolak "ada rahasia nyata di berkas yang dilacak:"
    printf '%s\n' "$temuan_rahasia" | head -8 | sed 's/^/      /'
    info "Hapus dari git (git rm --cached + riwayat), rotasi kuncinya sekarang."
  else
    ok "tidak ada kunci privat / secret key nyata di berkas yang dilacak"
  fi
  ok "debug.keystore di-commit sengaja: $(git ls-files android/debug.keystore | wc -l | tr -d ' ') berkas"
else
  lewati "bukan repo git — pemeriksaan rahasia dilewati"
fi

# ===========================================================================
judul "2. Edge Function (Supabase)"
# ===========================================================================
if command -v node >/dev/null 2>&1; then
  if node tools/ts_check.js >/tmp/gate-ts.log 2>&1; then
    ok "ts_check: $(grep -E 'TS OK' /tmp/gate-ts.log | head -1)"
  else
    tolak "ts_check gagal"; tail -5 /tmp/gate-ts.log | sed 's/^/      /'
  fi
  if [ "$CEPAT" = 1 ]; then
    lewati "e2e Edge Function dilewati (--cepat)"
  else
    if node tools/e2e/run_e2e.mts >/tmp/gate-e2e.log 2>&1; then
      ok "e2e: $(grep -E 'skenario lulus' /tmp/gate-e2e.log | tail -1)"
    else
      tolak "e2e gagal"; tail -15 /tmp/gate-e2e.log | sed 's/^/      /'
      info "Butuh venv: python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pgserver \"psycopg[binary]\""
    fi
  fi
  if node tools/bundle_functions.js >/tmp/gate-bundle.log 2>&1; then
    if git diff --quiet supabase/deploy-dashboard 2>/dev/null; then
      ok "berkas siap-tempel Dashboard (10 fungsi) tidak basi"
    else
      tolak "supabase/deploy-dashboard BASI — commit hasil bundle_functions.js"
      git checkout -- supabase/deploy-dashboard 2>/dev/null || true
    fi
  else
    tolak "bundle_functions.js gagal"; tail -5 /tmp/gate-bundle.log | sed 's/^/      /'
  fi
else
  tolak "node tidak ada — Edge Function tidak bisa diperiksa"
fi

# ===========================================================================
judul "3. Migrasi database"
# ===========================================================================
PY="$(python_venv || true)"
if [ -z "$PY" ]; then
  lewati "pgserver/psycopg tidak tersedia → migrasi tidak diuji di sini"
  info "Pasang: python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pgserver \"psycopg[binary]\""
elif [ "$CEPAT" = 1 ]; then
  lewati "uji migrasi dilewati (--cepat)"
else
  if "$PY" tools/db_check.py --dir /tmp/gate-dbcheck >/tmp/gate-db.log 2>&1; then
    ok "$(grep -E '^SEMUA OK' /tmp/gate-db.log | tail -1)"
    info "$(grep -cE '^OK ' /tmp/gate-db.log) berkas SQL lulus"
    info "$(grep -E 'RPC dipakai' /tmp/gate-db.log | head -1 | sed 's/^— //')"
  else
    tolak "db_check gagal"; tail -20 /tmp/gate-db.log | sed 's/^/      /'
  fi
fi
jumlah_migrasi="$(ls supabase/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ')"
jumlah_fungsi="$(ls -d supabase/functions/*/ 2>/dev/null | grep -v '_shared' | wc -l | tr -d ' ')"
info "migrasi di repo: $jumlah_migrasi berkas · Edge Function: $jumlah_fungsi fungsi (+ folder _shared)"

# ===========================================================================
judul "4. firestore.rules (temuan H-1)"
# ===========================================================================
if [ ! -f firestore.rules ]; then
  tolak "firestore.rules tidak ada"
else
  ok "firestore.rules ada ($(wc -l <firestore.rules | tr -d ' ') baris)"
  if grep -q "request.resource.data.userId == request.auth.uid" firestore.rules; then
    ok "pengikat pemilik pesanan ada (inti perbaikan H-1)"
  else
    tolak "pola pengikat pemilik (userId == uid) tidak ditemukan — H-1 belum diperbaiki!"
  fi
  if grep -q "match /rateLimits/{id}" firestore.rules && grep -q "allow read, write: if false" firestore.rules; then
    ok "rateLimits dikunci hanya-server"
  fi
  if command -v java >/dev/null 2>&1 && [ "$CEPAT" != 1 ]; then
    if bash tools/check_firestore_rules.sh >/tmp/gate-rules.log 2>&1; then
      ok "13 uji keamanan lulus di Firestore Emulator"
    else
      tolak "uji emulator GAGAL — jangan publish rules ini"; tail -20 /tmp/gate-rules.log | sed 's/^/      /'
    fi
  else
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      ci="$(gh run list --workflow backend-check.yml --limit 1 \
             --json conclusion,headBranch -q '.[0] | .conclusion + " (" + .headBranch + ")"' 2>/dev/null || echo '?')"
      case "$ci" in
        success*) ok "job CI 'Aturan Firestore (emulator)' terakhir: $ci" ;;
        *) kuning "  ! job CI backend-check terakhir: $ci — periksa sebelum publish" ;;
      esac
    else
      lewati "Java tidak ada → uji emulator dilewati (jalan di CI: workflow 'Backend check')"
    fi
  fi
  info "Status di SERVER diperiksa terpisah: bash tools/verify_published_rules.sh"
fi

# ===========================================================================
judul "5. Keystore & sidik jari"
# ===========================================================================
if command -v openssl >/dev/null 2>&1 && [ -f android/debug.keystore ]; then
  cert="$(mktemp)"
  openssl pkcs12 -in android/debug.keystore -passin pass:android -nokeys -clcerts -legacy \
      -out "$cert" 2>/dev/null \
    || openssl pkcs12 -in android/debug.keystore -passin pass:android -nokeys -clcerts \
      -out "$cert" 2>/dev/null
  sha1="$(openssl x509 -in "$cert" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//' | tr -d ' :')"
  sha256="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ' :')"
  rm -f "$cert"
  if [ -n "$sha1" ]; then
    # Bandingkan tanpa titik dua & tanpa memedulikan besar/kecil huruf.
    sidik_dokumen="$(tr -d ':' <android/SHA_FINGERPRINTS.txt 2>/dev/null | tr 'A-Z' 'a-z')"
    if printf '%s' "$sidik_dokumen" | grep -qi "$sha1"; then
      ok "SHA-1 debug.keystore cocok dengan android/SHA_FINGERPRINTS.txt"
    else
      tolak "SHA-1 debug.keystore TIDAK cocok dengan SHA_FINGERPRINTS.txt"
    fi
    if printf '%s' "$sidik_dokumen" | grep -qi "$sha256"; then
      ok "SHA-256 juga cocok (dipakai Play Integrity / App Check)"
    else
      tolak "SHA-256 debug.keystore TIDAK cocok dengan SHA_FINGERPRINTS.txt"
    fi
    if grep -qi "$sha1" android/app/google-services.json 2>/dev/null; then
      ok "SHA-1 itu terdaftar di google-services.json (= sudah di Firebase)"
    else
      tolak "SHA-1 belum terdaftar di google-services.json → login Google/OTP bisa gagal"
    fi
  else
    lewati "sidik jari tidak terbaca (openssl tanpa dukungan pkcs12?)"
  fi
else
  lewati "openssl/debug.keystore tidak ada — sidik jari tidak diperiksa"
fi
if [ -f android/key.properties ]; then
  ok "android/key.properties ada di mesin ini (tidak ter-commit)"
else
  info "android/key.properties belum ada → build CI memakai debug key (APK belum siap Play)"
  info "Buat keystore rilis: bash tools/check_sha.sh --gen-keystore"
fi
if ls "$HOME"/rara-keystore-backup/*.enc >/dev/null 2>&1; then
  ok "bundel backup keystore ditemukan di ~/rara-keystore-backup"
else
  info "belum ada bundel backup: bash tools/backup_keystore.sh create --keystore <file.jks>"
fi

# ===========================================================================
judul "6. Artefak rilis Play Store"
# ===========================================================================
for f in DATA_SAFETY.md docs/hapus-akun.html RILIS_PRODUKSI.md LAPORAN_KEAMANAN.md \
         AUDIT_RILIS.md MIGRASI_SUPABASE.md PANDUAN_BUILD_APK.md; do
  [ -f "$f" ] && ok "$f" || tolak "$f belum ada"
done

# Halaman hapus akun dinilai Play secara manual: harus menyebut nama aplikasi,
# memberi kanal kontak, dan terbuka tanpa error. Sumber eksternal (CDN, font,
# gambar) adalah cara termudah membuat halaman itu gagal dibuka reviewer.
halaman="docs/hapus-akun.html"
if [ -f "$halaman" ]; then
  if grep -q 'Rara Travel' "$halaman"; then
    ok "halaman hapus akun menyebut nama aplikasi"
  else
    tolak "halaman hapus akun tidak menyebut nama aplikasi (Play bisa menolaknya)"
  fi
  if grep -q 'mailto:' "$halaman" || grep -q 'wa\.me' "$halaman"; then
    ok "halaman hapus akun punya kanal kontak (email / WhatsApp)"
  else
    tolak "halaman hapus akun tanpa kanal kontak — permintaan penghapusan tidak bisa masuk"
  fi
  eksternal="$(grep -oE '<(script|link|img)[^>]*(src|href)="https?://[^"]+"' "$halaman" || true)"
  if [ -n "$eksternal" ]; then
    tolak "halaman hapus akun memuat sumber eksternal:"
    printf '%s\n' "$eksternal" | sed 's/^/      /'
  else
    ok "halaman hapus akun mandiri (tanpa script/css/gambar dari luar)"
  fi
  if grep -q 'http://' "$halaman"; then
    tolak "ada tautan http:// (tidak terenkripsi) di halaman hapus akun"
  else
    ok "tautan di halaman hapus akun semuanya https/mailto"
  fi
fi

versi="$(sed -n 's/^version: *//p' pubspec.yaml | head -1)"
info "versi aplikasi: ${versi:-?}"
proyek="$(python3 -c 'import json;print((json.load(open(".firebaserc")).get("projects") or {}).get("default",""))' 2>/dev/null || echo '')"
[ -n "$proyek" ] && [ "$proyek" != "PROJECT_ID_KAMU" ] && ok ".firebaserc → $proyek" \
  || tolak ".firebaserc belum menunjuk proyek Firebase"
if grep -q 'android:allowBackup="false"' android/app/src/main/AndroidManifest.xml; then
  ok "allowBackup=false (temuan M-1)"
else
  tolak "allowBackup belum dimatikan (temuan M-1)"
fi
if grep -q 'android:usesCleartextTraffic="false"' android/app/src/main/AndroidManifest.xml; then
  ok "usesCleartextTraffic=false (temuan M-3)"
fi
if grep -q 'AndroidProvider.playIntegrity' lib/services/firebase_bootstrap.dart; then
  ok "App Check aktif di kode (Play Integrity untuk rilis)"
fi
if grep -q 'Hapus Akun' lib/screens/profile_screen.dart; then
  ok "tombol Hapus Akun ada di aplikasi (temuan H-2)"
fi

# ===========================================================================
judul "7. Kesiapan deploy (workflow + secrets Actions)"
# ===========================================================================
# Deploy jalan di GitHub Actions, jadi pastikan workflow-nya ada dan rahasianya
# sudah terpasang — supaya `gh workflow run` tidak gagal di tengah jalan.
for w in deploy-firebase.yml deploy-supabase.yml; do
  jalur=".github/workflows/$w"
  if [ ! -f "$jalur" ]; then
    tolak "$jalur belum ada — deploy tidak bisa dijalankan dari Actions"
    continue
  fi
  if grep -q 'workflow_dispatch' "$jalur"; then
    ok "$w siap dipanggil: gh workflow run $w"
  else
    tolak "$w tidak punya pemicu workflow_dispatch"
  fi
  keras="$(grep -nE 'sb_secret_[A-Za-z0-9]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOi[A-Za-z0-9_-]{20,}' "$jalur" || true)"
  if [ -n "$keras" ]; then
    tolak "$w memuat rahasia hardcoded — pindahkan ke secrets:"
    printf '%s\n' "$keras" | sed 's/^/      /'
  fi
done

rahasia_wajib="SUPABASE_ACCESS_TOKEN SUPABASE_DB_PASSWORD"
rahasia_pilih="FIREBASE_SERVICE_ACCOUNT_JSON FIREBASE_TOKEN"
rahasia_opsional="NOTIFY_WEBHOOK_SECRET MIDTRANS_SERVER_KEY"
vars_wajib="SUPABASE_PROJECT_REF SUPABASE_ANON_KEY FIREBASE_PROJECT_ID"

ada_di() { printf '%s\n' "$1" | grep -qx "$2"; }

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  daftar_secret="$(gh secret list 2>/dev/null | awk 'NR>1 {print $1}')"
  daftar_vars="$(gh variable list 2>/dev/null | awk 'NR>1 {print $1}')"
  if [ -z "$daftar_secret" ] && [ -z "$daftar_vars" ]; then
    lewati "daftar secrets/variables tidak terbaca (token kurang izin) — periksa di Settings → Secrets and variables → Actions"
    info "Wajib: $rahasia_wajib · variables: $vars_wajib"
  else
    for s in $rahasia_wajib; do
      ada_di "$daftar_secret" "$s" && ok "secret $s terpasang" || tolak "secret $s BELUM terpasang"
    done
    # Cukup salah satu dari dua cara autentikasi Firebase.
    if ada_di "$daftar_secret" "FIREBASE_SERVICE_ACCOUNT_JSON"; then
      ok "secret FIREBASE_SERVICE_ACCOUNT_JSON terpasang"
    elif ada_di "$daftar_secret" "FIREBASE_TOKEN"; then
      ok "secret FIREBASE_TOKEN terpasang"
    else
      tolak "belum ada FIREBASE_SERVICE_ACCOUNT_JSON / FIREBASE_TOKEN → deploy Firebase akan gagal"
    fi
    for v in $vars_wajib; do
      ada_di "$daftar_vars" "$v" && ok "variable $v terpasang" || tolak "variable $v BELUM terpasang"
    done
    for s in $rahasia_opsional; do
      ada_di "$daftar_secret" "$s" && ok "secret opsional $s terpasang" \
        || info "secret opsional $s belum ada (boleh dibiarkan kosong)"
    done
  fi
  # Workflow baru muncul di tab Actions setelah berkasnya ada di branch default.
  daftar_wf="$(gh workflow list --limit 100 2>/dev/null)"
  for w in deploy-firebase.yml deploy-supabase.yml; do
    [ -f ".github/workflows/$w" ] || continue
    nama="$(sed -n 's/^name:[[:space:]]*//p' ".github/workflows/$w" | head -1)"
    [ -n "$nama" ] || continue
    if printf '%s\n' "$daftar_wf" | grep -qF "$nama"; then
      ok "workflow '$nama' terdaftar di tab Actions"
    else
      info "workflow '$nama' belum terdaftar di Actions — merge ke branch default dulu (batas workflow_dispatch GitHub); sementara pakai: gh workflow run $w --ref <branch>"
    fi
  done
else
  lewati "gh tidak ada / belum login → secrets & registrasi workflow tidak diperiksa"
  info "Secrets wajib: $rahasia_wajib (+ salah satu: $rahasia_pilih)"
  info "Variables wajib: $vars_wajib"
fi

# ===========================================================================
judul "Status 6 tugas rilis"
# ===========================================================================
printf '  %-34s %-22s %s\n' "TUGAS" "LOKAL" "LANGKAH BERIKUTNYA (butuh kredensial/Console)"
printf '  %s\n' "───────────────────────────────── ────────────────────── ─────────────────────────────────────────────"
printf '  %-34s %-22s %s\n' "1. Deploy migrasi + Edge Function" "kode & uji ✔" \
  "gh workflow run deploy-supabase.yml -f dry_run=true  →  tanpa dry_run"
printf '  %-34s %-22s %s\n' "2. Publish firestore.rules (H-1)" "rules + uji ✔" \
  "gh workflow run deploy-firebase.yml  →  bash tools/verify_published_rules.sh"
printf '  %-34s %-22s %s\n' "3. App Check + token debug" "kode ✔" \
  "bash tools/appcheck_admin.sh --status → --from-logcat → --enforce all"
printf '  %-34s %-22s %s\n' "4. SMS region policy / kuota" "skrip ✔" \
  "bash tools/sms_region_policy.sh --status → --allow ID"
printf '  %-34s %-22s %s\n' "5. Backup keystore" "debug ✔" \
  "bash tools/backup_keystore.sh create --keystore <rilis.jks>  (+ 2 tempat)"
printf '  %-34s %-22s %s\n' "6. Data Safety Play Console" "lembar jawab ✔" \
  "isi formulir dari DATA_SAFETY.md + unggah docs/hapus-akun.html ke web"

judul "Ringkasan"
if [ "$GAGAL" = 0 ]; then
  hijau "SEMUA PEMERIKSAAN LOKAL LULUS$([ "$LEWAT" -gt 0 ] && printf ' (%d dilewati — lihat ↷ di atas)' "$LEWAT")."
  info "Tabel di atas = yang masih harus kamu jalankan dengan kredensialmu."
else
  merah "ADA PEMERIKSAAN LOKAL YANG GAGAL — perbaiki tanda ✖ sebelum deploy/rilis."
fi
exit "$GAGAL"
