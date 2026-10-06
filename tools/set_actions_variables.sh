#!/usr/bin/env bash
# set_actions_variables.sh — isi Repository variables Supabase untuk CI.
#
# Ini yang membuat APK hasil CI benar-benar memakai backend Supabase +
# menyalakan tombol pembayaran ("Bayar Sekarang"). Tanpa variables ini, APK
# tetap memakai katalog lokal + Firestore dan tombol pembayaran disembunyikan.
#
# Kunci yang dipakai aman berada di APK (publishable/anon key hanya bisa
# menjangkau data yang diizinkan policy RLS) — JANGAN memakai service_role /
# secret key di sini.
#
# Pemakaian:
#   bash tools/set_actions_variables.sh                 # tanya interaktif
#   bash tools/set_actions_variables.sh --check         # lihat isi sekarang
#   bash tools/set_actions_variables.sh --build         # setelah mengisi, jalankan CI
#   bash tools/set_actions_variables.sh --url … --key … --verify
#       # cek dulu URL + kunci benar-benar diterima Supabase (butuh internet)
#   bash tools/set_actions_variables.sh \
#     --url https://xxxx.supabase.co --key sb_publishable_xxx \
#     --catalog supabase --booking dual --payments true
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
BUILD=0
VERIFY=0
URL=""; KEY=""; CATALOG=""; BOOKING=""; PAYMENTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --build) BUILD=1 ;;
    --verify) VERIFY=1 ;;
    --url) URL="${2:-}"; shift ;;
    --key) KEY="${2:-}"; shift ;;
    --catalog) CATALOG="${2:-}"; shift ;;
    --booking) BOOKING="${2:-}"; shift ;;
    --payments) PAYMENTS="${2:-}"; shift ;;
    -h|--help)
      # Hanya blok komentar di awal berkas (bukan komentar isi kode).
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; lanjut=1; next } NR>1 && lanjut { exit }' "$0"
      exit 0 ;;
    *) echo "Argumen tidak dikenal: $1 (coba --help)"; exit 2 ;;
  esac
  shift
done

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1"; }

command -v gh >/dev/null 2>&1 || { fail "GitHub CLI (gh) tidak ditemukan — pasang dulu: https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { fail "gh belum login. Jalankan: gh auth login"; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
echo "Repositori: $REPO"
echo ""

# Daftar variables (butuh izin baca variabel Actions; kalau ditolak, tetap lanjut).
list_vars() {
  gh api "repos/$REPO/actions/variables" --jq '.variables[] | "  \(.name) = \(.value)"' 2>/dev/null || {
    warn "Tidak bisa membaca daftar variables (token gh kurang izin 'Variables: read')."
    return 1
  }
}

# Cek URL + kunci benar-benar diterima proyek Supabase (tanpa mengubah apa pun).
verifikasi_supabase() {
  local url="$1" key="$2" kode_url kode_key
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl tidak tersedia — verifikasi dilewati."
    return 0
  fi
  kode_url="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url/auth/v1/health" 2>/dev/null || echo 000)"
  if [ "$kode_url" = "000" ]; then
    warn "Tidak bisa menghubungi $url (offline / DNS / proyek dijeda). Verifikasi dilewati."
    return 0
  fi
  if [ "$kode_url" != "200" ]; then
    warn "Auth Supabase menjawab HTTP $kode_url — pastikan URL proyek benar & aktif."
    return 0
  fi
  ok "URL proyek hidup (auth/v1/health → 200)."
  kode_key="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "apikey: $key" "$url/rest/v1/" 2>/dev/null || echo 000)"
  case "$kode_key" in
    200|204) ok "Kunci diterima Supabase (HTTP $kode_key)." ;;
    401|403)
      warn "Kunci DITOLAK Supabase (HTTP $kode_key). Salin ulang anon/publishable key dari Dashboard → Project Settings → API."
      return 1
      ;;
    404)     warn "REST menjawab 404 — jalankan migrasi dulu (bash tools/setup_supabase.sh)." ;;
    *)       warn "REST menjawab HTTP $kode_key — cek migrasi/RLS bila ada keluhan." ;;
  esac
}

if [ "$CHECK" -eq 1 ]; then
  echo "Variables saat ini:"
  list_vars || true
  echo ""
  echo "Yang dibutuhkan: SUPABASE_URL, SUPABASE_ANON_KEY"
  echo "(opsional: CATALOG_SOURCE, BOOKING_WRITE, PAYMENTS_ENABLED)"
  exit 0
fi

# ------------------------------------------------------------------ input
if [ -z "$URL" ]; then
  read -rp "SUPABASE_URL (https://<ref>.supabase.co): " URL
fi
if [ -z "$KEY" ]; then
  read -rsp "SUPABASE_ANON_KEY (anon lama 'eyJ…' atau 'sb_publishable_…'): " KEY; echo ""
fi

URL="$(printf '%s' "$URL" | tr -d '[:space:]')"
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"

case "$URL" in
  https://*.supabase.co) ;;
  *) fail "URL tidak seperti proyek Supabase (harus https://<ref>.supabase.co)."; exit 1 ;;
esac
case "$KEY" in
  sb_publishable_*|eyJ*) ;;
  *) fail "Kunci tidak dikenali. Pakai publishable/anon key, BUKAN service_role."; exit 1 ;;
esac
case "$KEY" in
  *service_role*|sb_secret_*) fail "Itu kunci RAHASIA (service_role/secret). Jangan ditaruh di aplikasi!"; exit 1 ;;
esac

if [ "$VERIFY" -eq 1 ]; then
  if ! verifikasi_supabase "$URL" "$KEY"; then
    fail "Verifikasi gagal — variables TIDAK diubah. Perbaiki URL/kunci lalu ulangi."
    exit 1
  fi
fi

# Sakelar opsional: tanya hanya bila belum diberikan lewat argumen.
if [ -z "$CATALOG" ]; then
  read -rp "CATALOG_SOURCE [supabase] (kosong = biarkan bawaan 'local'): " CATALOG || true
fi
if [ -z "$BOOKING" ]; then
  read -rp "BOOKING_WRITE [dual] (dual|supabase|firestore, kosong = biarkan): " BOOKING || true
fi
if [ -z "$PAYMENTS" ]; then
  read -rp "PAYMENTS_ENABLED [true] (true = tampilkan tombol bayar, kosong = false): " PAYMENTS || true
fi

# ------------------------------------------------------------------ set
set_var() { # $1 = nama, $2 = nilai
  local nama="$1" nilai="$2"
  # PATCH = perbarui yang sudah ada; POST = buat baru (404 bila belum ada).
  if gh api -X PATCH "repos/$REPO/actions/variables/$nama" \
       -f name="$nama" -f value="$nilai" >/dev/null 2>&1; then
    ok "$nama diperbarui"
  elif gh api -X POST "repos/$REPO/actions/variables" \
       -f name="$nama" -f value="$nilai" >/dev/null 2>&1; then
    ok "$nama dibuat"
  else
    fail "Gagal menulis $nama — token gh perlu izin 'Variables: write' (repo admin)."
    return 1
  fi
}

GAGAL=0
set_var SUPABASE_URL "$URL" || GAGAL=1
set_var SUPABASE_ANON_KEY "$KEY" || GAGAL=1
# CATALOG_SOURCE sengaja TIDAK dipaksa 'supabase' oleh skrip ini (lihat README
# §5: uji katalog server dulu). Isi manual bila sudah siap.
[ -n "$CATALOG" ] && { set_var CATALOG_SOURCE "$CATALOG" || GAGAL=1; }
[ -n "$BOOKING" ] && { set_var BOOKING_WRITE "$BOOKING" || GAGAL=1; }
[ -n "$PAYMENTS" ] && { set_var PAYMENTS_ENABLED "$PAYMENTS" || GAGAL=1; }

echo ""
[ "$GAGAL" -eq 0 ] || { fail "Sebagian variables gagal ditulis (lihat pesan di atas)."; exit 1; }

echo "Ringkasan yang akan dipakai APK berikutnya:"
printf '   katalog     : %s\n' "${CATALOG:-local (bawaan)}"
printf '   pesanan     : %s\n' "${BOOKING:-dual (bawaan)}"
printf '   pembayaran  : %s\n' "$([ "${PAYMENTS:-false}" = "true" ] && echo 'AKTIF (tombol Bayar Sekarang muncul)' || echo 'nonaktif')"
echo ""

if [ "$BUILD" -eq 1 ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  echo "Menjalankan ulang CI untuk branch $BRANCH…"
  gh workflow run build-apk.yml --ref "$BRANCH"
  ok "CI dijalankan. Lihat progres: gh run watch"
  echo "   Ringkasan run akan menampilkan mode backend APK (pastikan 'pembayaran : AKTIF')."
else
  echo "Langkah berikutnya (bangun ulang APK dengan variables ini):"
  echo "  bash tools/set_actions_variables.sh --build"
  echo "atau: gh workflow run build-apk.yml --ref <branch>"
fi
