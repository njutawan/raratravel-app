#!/usr/bin/env bash
# appcheck_admin.sh — urus App Check tanpa bolak-balik Firebase Console.
#
# Yang bisa dikerjakan skrip ini (lewat Firebase App Check API):
#   --status              laporan: provider Play Integrity, debug token,
#                         enforcement per layanan (Firestore, Auth, Storage)
#   --register <TOKEN>    daftarkan debug token (UUID dari logcat HP)
#   --from-logcat         ambil token dari `adb logcat` lalu langsung daftar
#   --tokens              daftar debug token yang terdaftar
#   --revoke <ID|NAMA>    cabut debug token
#   --enforce <LAYANAN>   nyalakan enforcement (firestore|auth|storage|all)
#   --unenforce <LAYANAN> matikan enforcement (unenforced/off) — jalur rollback
#
# Syarat: access token Google dengan hak Firebase Admin/Owner pada proyek.
#   bash tools/appcheck_admin.sh --status
#   GOOGLE_APPLICATION_CREDENTIALS=~/kunci/firebase-sa.json \
#     bash tools/appcheck_admin.sh --status
#   (alternatif: sudah `gcloud auth login` — token diambil otomatis)
#
# URUTAN WAJIB saat pertama menyalakan enforcement:
#   1. --from-logcat (atau --register) → token debug HP kamu terdaftar
#   2. --enforce all
# Kalau terbalik, build debug kamu sendiri ikut terblokir.
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="${APPCHECK_API_BASE:-https://firebaseappcheck.googleapis.com/v1}"
GS_JSON="$AKAR/android/app/google-services.json"
SA_ARGS=()
AKSI=""
TARGET=""
NAMA=""
YES=0
JSON_MODE=0
SERIAL="${ANDROID_SERIAL:-}"
GAGAL=0

hijau()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul()  { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok()     { hijau "  ✔ $*"; }
info()   { printf '  · %s\n' "$*"; }
tolak()  { merah "  ✖ $*"; GAGAL=1; }
perhati(){ kuning "  ! $*"; }

pakai_help() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --status)        AKSI="status"; shift ;;
    --register)      AKSI="register"; TARGET="${2:-}"; shift 2 ;;
    --register=*)    AKSI="register"; TARGET="${1#*=}"; shift ;;
    --from-logcat)   AKSI="logcat"; shift ;;
    --tokens)        AKSI="tokens"; shift ;;
    --revoke)        AKSI="revoke"; TARGET="${2:-}"; shift 2 ;;
    --revoke=*)      AKSI="revoke"; TARGET="${1#*=}"; shift ;;
    --enforce)       AKSI="enforce"; TARGET="${2:-}"; shift 2 ;;
    --enforce=*)     AKSI="enforce"; TARGET="${1#*=}"; shift ;;
    --unenforce)     AKSI="unenforce"; TARGET="${2:-}"; shift 2 ;;
    --unenforce=*)   AKSI="unenforce"; TARGET="${1#*=}"; shift ;;
    --off)           AKSI="off"; TARGET="${2:-}"; shift 2 ;;
    --name)          NAMA="${2:-}"; shift 2 ;;
    --name=*)        NAMA="${1#*=}"; shift ;;
    --sa)            SA_ARGS+=(--sa "${2:-}"); shift 2 ;;
    --app-id)        APP_ID_PAKSA="${2:-}"; shift 2 ;;
    --project-number) NOMOR_PAKSA="${2:-}"; shift 2 ;;
    --serial)        SERIAL="${2:-}"; shift 2 ;;
    --json)          JSON_MODE=1; shift ;;
    --yes|-y)        YES=1; shift ;;
    -h|--help)       pakai_help ;;
    *) merah "Argumen tidak dikenal: $1"; pakai_help ;;
  esac
done
: "${AKSI:=status}"

command -v curl >/dev/null 2>&1   || { merah "❌ curl tidak ada."; exit 1; }
command -v python3 >/dev/null 2>&1 || { merah "❌ python3 tidak ada."; exit 1; }

# ---------------------------------------------------------------------------
# Identitas proyek + aplikasi Android (dari google-services.json)
# ---------------------------------------------------------------------------
NOMOR_PROYEK="${NOMOR_PAKSA:-}"
APP_ID="${APP_ID_PAKSA:-}"
if [ -z "$NOMOR_PROYEK" ] || [ -z "$APP_ID" ]; then
  if [ -f "$GS_JSON" ]; then
    baca="$(python3 - "$GS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
nomor = (d.get("project_info") or {}).get("project_number") or ""
klien = (d.get("client") or [{}])[0]
app = (klien.get("client_info") or {}).get("mobilesdk_app_id") or ""
pkg = ((klien.get("client_info") or {}).get("android_client_info") or {}).get("package_name") or ""
print(f"{nomor}\t{app}\t{pkg}")
PY
)"
    NOMOR_PROYEK="${NOMOR_PROYEK:-$(printf '%s' "$baca" | cut -f1)}"
    APP_ID="${APP_ID:-$(printf '%s' "$baca" | cut -f2)}"
    PAKET="$(printf '%s' "$baca" | cut -f3)"
  fi
fi
: "${PAKET:=com.raratravel.app}"

if [ -z "$NOMOR_PROYEK" ] || [ -z "$APP_ID" ]; then
  merah "❌ Project number / app id tidak terbaca."
  info "Isi manual: --project-number 132948234436 --app-id 1:...:android:..."
  info "atau taruh google-services.json di android/app/."
  exit 1
fi

# ---------------------------------------------------------------------------
# Token akses
# ---------------------------------------------------------------------------
TOKEN="$(bash "$AKAR/tools/gcp_token.sh" --quiet \
  --scope "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/firebase" \
  ${SA_ARGS[@]+"${SA_ARGS[@]}"})" || {
  merah "❌ Tidak bisa memperoleh access token Google (lihat pesan di atas)."
  exit 1
}

# ---------------------------------------------------------------------------
# Pemanggil API kecil
# ---------------------------------------------------------------------------
BADAN=""
KODE=""
api() { # api <METHOD> <path-tanpa-API> [json-body]
  local metode="$1" path="$2" badan="${3:-}" tmp
  tmp="$(mktemp)"
  local args=(-sS -o "$tmp" -w '%{http_code}' -X "$metode" "$API$path"
              -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
  [ -n "$badan" ] && args+=(--data-binary "$badan")
  KODE="$(curl "${args[@]}" 2>/dev/null)" || KODE="000"
  [ -n "$KODE" ] || KODE="000"
  BADAN="$(cat "$tmp")"; rm -f "$tmp"
}

ringkas_galat() {
  python3 -c '
import json, sys
mentah = sys.argv[1]
try:
    e = (json.loads(mentah) or {}).get("error") or {}
    print(str(e.get("code", "?")) + " " + str(e.get("status", "")) + ": "
          + str(e.get("message", ""))[:300])
except Exception:
    print(mentah[:300])
' "$BADAN" 2>/dev/null || printf '%s\n' "$BADAN" | head -c 300
}

sarankan_galat() {
  case "$KODE" in
    401) perhati "Token ditolak — jalankan ulang (token kedaluwarsa) atau periksa service account." ;;
    403) perhati "403: API App Check belum aktif ATAU service account belum punya hak."
         info "Aktifkan: https://console.cloud.google.com/apis/library/firebaseappcheck.googleapis.com"
         info "Beri peran: Firebase Console → Project settings → Users and roles → Firebase Admin." ;;
    404) perhati "404: aplikasi Android belum terdaftar di App Check (atau app id salah)."
         info "Firebase Console → Project settings → Your apps → pastikan paket $PAKET ada,"
         info "lalu App Check → Apps → daftarkan provider Play Integrity untuk aplikasi itu." ;;
    400) perhati "400: permintaan ditolak — periksa bentuk token/nama layanan." ;;
    000) perhati "Tidak ada jawaban dari API (jaringan/proxy?)." ;;
  esac
}

pyfield() { # pyfield <json> <expr-python 'd'>
  python3 -c "import json,sys
d=json.loads(sys.argv[1])
try:
    v=$2
except Exception:
    v=''
print('' if v is None else v)" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Pemetaan layanan
# ---------------------------------------------------------------------------
id_layanan() {
  case "$1" in
    firestore|fs)      printf 'firestore.googleapis.com' ;;
    auth|authentication|identitytoolkit) printf 'identitytoolkit.googleapis.com' ;;
    storage)           printf 'firebasestorage.googleapis.com' ;;
    database|rtdb)     printf 'firebasedatabase.googleapis.com' ;;
    *) return 1 ;;
  esac
}
daftar_layanan() {
  case "$1" in
    all|semua) printf 'firestore auth storage\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

mode_layanan() { # mode_layanan <id-layanan> → ENFORCED/UNENFORCED/OFF/?
  api GET "/projects/$NOMOR_PROYEK/services/$1"
  [ "$KODE" = 200 ] || { printf '?'; return 1; }
  pyfield "$BADAN" "d.get('enforcementMode') or ('ENFORCED' if d.get('enforce') else 'UNENFORCED')"
}

# ===========================================================================
# STATUS
# ===========================================================================
aksi_status() {
  judul "App Check — proyek $NOMOR_PROYEK / $PAKET"
  info "app id: $APP_ID"

  # Provider Play Integrity
  api GET "/projects/$NOMOR_PROYEK/apps/$APP_ID/playIntegrityConfig"
  if [ "$KODE" = 200 ]; then
    ok "provider Play Integrity terdaftar"
    [ "$JSON_MODE" = 1 ] && printf '%s\n' "$BADAN" | sed 's/^/      /'
    vm="$(pyfield "$BADAN" "d.get('verificationMode')")"
    [ -n "$vm" ] && info "verificationMode: $vm"
  else
    tolak "Play Integrity belum terdaftar untuk aplikasi ini (HTTP $KODE)"
    sarankan_galat
    info "Firebase Console → App Check → Apps → $PAKET → Play Integrity → Register."
    info "Syarat: SHA-256 keystore rilis/debug terdaftar di Project settings,"
    info "dan (untuk versi Play Store) SHA-256 Play App Signing sudah disalin."
  fi

  # Debug token
  api GET "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens"
  if [ "$KODE" = 200 ]; then
    jumlah="$(pyfield "$BADAN" "len(d.get('debugTokens') or [])")"
    if [ "${jumlah:-0}" -gt 0 ]; then
      ok "debug token terdaftar: $jumlah (maks 20 per aplikasi)"
      python3 - "$BADAN" <<'PY' | sed 's/^/      /'
import json, sys
for t in (json.loads(sys.argv[1]).get("debugTokens") or []):
    print(f'- {t.get("displayName","(tanpa nama)")}  ·  {t.get("name","").split("/")[-1]}  ·  diperbarui {t.get("updateTime","-")}')
PY
    else
      perhati "belum ada debug token — build DEBUG akan terblokir begitu enforcement nyala."
      info "Ambil token: bash tools/appcheck_debug_token.sh --watch"
      info "Daftarkan  : bash tools/appcheck_admin.sh --from-logcat"
    fi
  else
    perhati "daftar debug token tidak terbaca (HTTP $KODE)"; sarankan_galat
  fi

  # Enforcement
  printf '\n'
  info "Enforcement per layanan:"
  local n id mode
  for n in firestore auth storage; do
    id="$(id_layanan "$n")"
    mode="$(mode_layanan "$id" || true)"
    case "$mode" in
      ENFORCED)   ok "$(printf '%-10s' "$n") ENFORCED  ($id)" ;;
      UNENFORCED) perhati "$(printf '%-9s' "$n") UNENFORCED — hanya dipantau, belum dilindungi" ;;
      OFF)        perhati "$(printf '%-9s' "$n") OFF — App Check tidak dipakai layanan ini" ;;
      *)          tolak "$(printf '%-9s' "$n") tidak terbaca ($id)" ;;
    esac
  done

  printf '\n'
  info "Di aplikasi (lib/services/firebase_bootstrap.dart):"
  if grep -q "AndroidProvider.playIntegrity" "$AKAR/lib/services/firebase_bootstrap.dart" 2>/dev/null; then
    ok "rilis → AndroidProvider.playIntegrity · debug → AndroidProvider.debug"
  else
    perhati "pola aktivasi App Check tidak dikenali — periksa firebase_bootstrap.dart"
  fi
  info "Enforcement Firestore + Authentication = pelindung nyata API key (temuan M-2)."

  [ "$GAGAL" = 0 ] || return 1
}

# ===========================================================================
# REGISTER DEBUG TOKEN
# ===========================================================================
token_dari_logcat() {
  command -v adb >/dev/null 2>&1 || { merah "❌ adb tidak ada (Android SDK platform-tools)."; return 1; }
  local args=(-d)
  [ -n "$SERIAL" ] && args=(-s "$SERIAL" -d)
  local baris
  baris="$(adb logcat "${args[@]}" 2>/dev/null \
    | grep -iE 'app.?check|debug.?(token|secret)' \
    | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
    | tail -1 || true)"
  [ -n "$baris" ] || {
    merah "❌ Token belum terlihat di logcat."
    info "1) jalankan aplikasi debug: flutter run"
    info "2) pantau: bash tools/appcheck_debug_token.sh --watch"
    info "3) ulangi: bash tools/appcheck_admin.sh --from-logcat"
    return 1
  }
  printf '%s' "$baris"
}

cek_uuid() {
  printf '%s' "$1" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
}

aksi_register() {
  local token="$1"
  [ -n "$token" ] || { merah "❌ Token kosong. Contoh: --register 12345678-1234-4123-8123-123456789abc"; return 1; }
  if ! cek_uuid "$token"; then
    perhati "Token ini bukan UUID v4 — API bisa menolaknya (App Check mencetak UUID)."
  fi
  [ -n "$NAMA" ] || NAMA="dev-$(hostname -s 2>/dev/null || echo hp)-$(date +%Y%m%d)"
  # displayName masuk ke JSON: buang karakter yang bisa merusak permintaan.
  NAMA="$(printf '%s' "$NAMA" | tr -d '"\\' | cut -c1-60)"
  [ -n "$NAMA" ] || NAMA="debug-token"
  judul "Mendaftarkan debug token ($NAMA)"
  api POST "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens" \
      "{\"displayName\":\"$NAMA\",\"token\":\"$token\"}"
  case "$KODE" in
    200) ok "debug token terdaftar: $NAMA"
         info "id: $(pyfield "$BADAN" "d.get('name','').split('/')[-1]")"
         info "Token TIDAK bisa dibaca lagi dari API — simpan bila perlu."
         info "Uji: jalankan aplikasi debug → login OTP + booking harus tetap jalan." ;;
    409) tolak "sudah ada / bentrok (HTTP 409)"; ringkas_galat
         info "Maksimal 20 debug token per aplikasi: cabut yang lama dengan --tokens lalu --revoke." ;;
    *)   tolak "gagal mendaftar (HTTP $KODE)"; ringkas_galat; sarankan_galat ;;
  esac
}

aksi_tokens() {
  api GET "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens"
  [ "$KODE" = 200 ] || { tolak "HTTP $KODE"; ringkas_galat; sarankan_galat; return 1; }
  [ "$JSON_MODE" = 1 ] && { printf '%s\n' "$BADAN"; return 0; }
  judul "Debug token terdaftar"
  python3 - "$BADAN" <<'PY'
import json, sys
data = json.loads(sys.argv[1]).get("debugTokens") or []
if not data:
    print("  (belum ada)")
for t in data:
    print(f'  · {t.get("displayName","(tanpa nama)")}')
    print(f'    id  : {t.get("name","").split("/")[-1]}')
    print(f'    waktu: {t.get("updateTime","-")}')
PY
}

aksi_revoke() {
  local cari="$1" id=""
  [ -n "$cari" ] || { merah "❌ Sebutkan id atau nama token: --revoke <id|nama>"; return 1; }
  api GET "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens"
  if [ "$KODE" = 200 ]; then
    id="$(python3 - "$BADAN" "$cari" <<'PY'
import json, sys
cari = sys.argv[2].lower()
for t in (json.loads(sys.argv[1]).get("debugTokens") or []):
    nama = (t.get("name") or "").split("/")[-1]
    tampil = (t.get("displayName") or "")
    if cari == nama.lower() or cari == tampil.lower() or cari in tampil.lower():
        print(nama); break
PY
)"
  fi
  [ -n "$id" ] || id="$cari"
  judul "Mencabut debug token $id"
  api DELETE "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens/$id"
  if [ "$KODE" = 200 ]; then ok "token dicabut"
  else tolak "gagal (HTTP $KODE)"; ringkas_galat; sarankan_galat; fi
}

# ===========================================================================
# ENFORCEMENT
# ===========================================================================
konfirmasi() { # konfirmasi <label>
  [ "$YES" = 1 ] && return 0
  if [ ! -t 0 ]; then
    merah "  ✖ ${1:-aksi ini} butuh persetujuan eksplisit saat dijalankan non-interaktif."
    info "Ulangi dengan --yes bila memang disengaja."
    return 1
  fi
  printf '  Lanjutkan? ketik "ya" lalu Enter: '
  local j; read -r j || return 1
  [ "$j" = "ya" ] || [ "$j" = "y" ]
}

aksi_enforce() {
  local target="$1" mode="$2" n id
  [ -n "$target" ] || { merah "❌ Sebutkan layanan: --enforce firestore|auth|storage|all"; return 1; }

  if [ "$mode" = "ENFORCED" ]; then
    judul "Menyalakan enforcement ($target)"
    # Syarat: debug token harus sudah ada, atau HP dev ikut terblokir.
    api GET "/projects/$NOMOR_PROYEK/apps/$APP_ID/debugTokens"
    jumlah="$(pyfield "$BADAN" "len(d.get('debugTokens') or [])" 2>/dev/null || echo 0)"
    if [ "${jumlah:-0}" = 0 ]; then
      perhati "Belum ada debug token terdaftar — build DEBUG kamu akan ikut terblokir."
      info "Disarankan: bash tools/appcheck_admin.sh --from-logcat  (dahulukan ini)"
    fi
    perhati "Enforcement menolak SEMUA klien tanpa token App Check yang sah."
    info "Pastikan APK/AAB yang beredar memakai Play Integrity + SHA-256 terdaftar,"
    info "termasuk SHA-256 Play App Signing setelah unggah AAB pertama."
    konfirmasi "menyalakan enforcement $target" || { info "dibatalkan"; GAGAL=1; return 1; }
  else
    judul "Mematikan enforcement ($target → $mode)"
    # Rollback: aman dijalankan non-interaktif (mis. dari CI saat insiden).
    [ "$YES" = 1 ] || [ ! -t 0 ] || konfirmasi "mematikan enforcement $target" \
      || { info "dibatalkan"; return 1; }
  fi

  for n in $(daftar_layanan "$target"); do
    id="$(id_layanan "$n")" || { tolak "layanan tidak dikenal: $n"; continue; }
    api PATCH "/projects/$NOMOR_PROYEK/services/$id?updateMask=enforcementMode" \
        "{\"enforcementMode\":\"$mode\"}"
    if [ "$KODE" = 200 ]; then
      ok "$n ($id) → $(pyfield "$BADAN" "d.get('enforcementMode')")"
    else
      # API lama memakai field boolean `enforce` — coba sekali lagi bila perlu.
      api PATCH "/projects/$NOMOR_PROYEK/services/$id?updateMask=enforce" \
          "{\"enforce\":$([ "$mode" = ENFORCED ] && echo true || echo false)}"
      if [ "$KODE" = 200 ]; then
        ok "$n ($id) → $mode (field lama 'enforce')"
      else
        tolak "$n ($id) gagal (HTTP $KODE)"; ringkas_galat; sarankan_galat
      fi
    fi
  done

  if [ "$mode" = "ENFORCED" ]; then
    printf '\n'
    info "Uji sekarang di HP fisik: login OTP → buat pesanan → buka Riwayat."
    info "Pantau 15 menit pertama: Firebase Console → App Check → tab Requests"
    info "(lihat jumlah 'Verified' vs 'Unverified' per layanan)."
    info "Rollback cepat: bash tools/appcheck_admin.sh --unenforce all --yes"
  fi
}

# ===========================================================================
# Jalankan
# ===========================================================================
case "$AKSI" in
  status)    aksi_status ;;
  register)  aksi_register "$TARGET" ;;
  logcat)    tok="$(token_dari_logcat)" && aksi_register "$tok" ;;
  tokens)    aksi_tokens ;;
  revoke)    aksi_revoke "$TARGET" ;;
  enforce)   aksi_enforce "$TARGET" ENFORCED ;;
  unenforce) aksi_enforce "$TARGET" UNENFORCED ;;
  off)       aksi_enforce "$TARGET" OFF ;;
  *)         merah "Aksi tidak dikenal: $AKSI"; pakai_help ;;
esac

exit "$GAGAL"
