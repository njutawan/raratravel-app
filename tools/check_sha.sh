#!/usr/bin/env bash
# check_sha.sh — cetak & verifikasi fingerprint SHA untuk Rara Travel.
#
# Fungsi:
#   1. Cetak SHA-1 / SHA-256 debug keystore (untuk development).
#   2. Cetak SHA-1 / SHA-256 release keystore (dari android/key.properties,
#      atau ~/upload-keystore.jks kalau key.properties belum ada).
#   3. Verifikasi otomatis: SHA-1 mana saja yang SUDAH terdaftar di
#      android/app/google-services.json (= sudah didaftarkan di Firebase).
#   4. --gen-keystore : buat keystore rilis + android/key.properties otomatis.
#
# Pemakaian:
#   bash tools/check_sha.sh                  # cetak + verifikasi semua SHA
#   bash tools/check_sha.sh --gen-keystore   # buat keystore rilis + key.properties
#   bash tools/check_sha.sh --force          # (dengan --gen-keystore) timpa key.properties
#
# Lihat juga: PANDUAN_BUILD_APK.md langkah 3, PANDUAN_FIREBASE.md langkah 4.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GS_JSON="$ROOT/android/app/google-services.json"
KEY_PROPS="$ROOT/android/key.properties"
ALIAS="rara-travel"
GEN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --gen-keystore) GEN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumen tidak dikenal: $arg (coba --help)"; exit 2 ;;
  esac
done

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1"; }

# ---------------------------------------------------------------- util
find_keytool() {
  if command -v keytool >/dev/null 2>&1; then command -v keytool; return; fi
  local c
  for c in \
    "$HOME/AppData/Local/Programs/Android Studio/jbr/bin/keytool.exe" \
    "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
    ; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  return 1
}

# Ekstrak fingerprint dari teks berisi token heksadesimal dipisah titik dua.
# SHA-1 = 20 byte (20 token), SHA-256 = 32 byte (32 token).
fp_sha1()   { grep -Eo '([0-9A-Fa-f]{2}:)+[0-9A-Fa-f]{2}' | awk -F: 'NF==20 {print; exit}'; }
fp_sha256() { grep -Eo '([0-9A-Fa-f]{2}:)+[0-9A-Fa-f]{2}' | awk -F: 'NF==32 {print; exit}'; }

norm() { tr -d ':' | tr '[:upper:]' '[:lower:]'; }  # AA:BB:.. -> aabb..

# SHA-1 & SHA-256 dari keystore. $1=file, $2=storepass, $3=alias (opsional)
fingerprint_keytool() {
  local ks="$1" pw="$2" alias="${3:-}" out
  local args=(-list -v -keystore "$ks" -storepass "$pw")
  [ -n "$alias" ] && args+=(-alias "$alias")
  out="$("$(find_keytool)" "${args[@]}" 2>/dev/null)" || return 1
  SHA1="$(printf '%s\n' "$out" | fp_sha1 || true)"
  SHA256="$(printf '%s\n' "$out" | fp_sha256 || true)"
}

fingerprint_openssl() {
  local ks="$1" pw="$2" cert
  cert="$(openssl pkcs12 -in "$ks" -passin "pass:$pw" -nokeys -clcerts 2>/dev/null)" || return 1
  # OpenSSL 3.x hanya mencetak fingerprint terakhir bila digabung, jadi pisah:
  SHA1="$(printf '%s\n' "$cert" | openssl x509 -noout -fingerprint -sha1 2>/dev/null | fp_sha1 || true)"
  SHA256="$(printf '%s\n' "$cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | fp_sha256 || true)"
  [ -n "$SHA1" ] || return 1
}

fingerprint() {  # pilih cara sesuai jenis file
  local ks="$1" pw="$2" alias="${3:-}"
  case "$ks" in
    *.p12|*.pfx|*.keystore)
      if find_keytool >/dev/null 2>&1; then
        fingerprint_keytool "$ks" "$pw" "$alias" || fingerprint_openssl "$ks" "$pw"
      else
        fingerprint_openssl "$ks" "$pw"
      fi ;;
    *) fingerprint_keytool "$ks" "$pw" "$alias" ;;
  esac
}

# Daftar SHA-1 (lowercase, tanpa titik dua) yang terdaftar di google-services.json
registered_hashes() {
  [ -f "$GS_JSON" ] || return 0
  grep -o '"certificate_hash"[[:space:]]*:[[:space:]]*"[^"]*"' "$GS_JSON" \
    | sed 's/.*"\([0-9a-fA-F]*\)"$/\1/' | tr '[:upper:]' '[:lower:]' || true
}

check_registered() {  # $1=label  $2=sha1 (format titik dua)
  local label="$1" sha1="$2"
  if [ -z "$sha1" ]; then
    warn "$label: fingerprint tidak terbaca."
    return
  fi
  printf '   %-9s %s\n' "SHA-1:" "$sha1"
  [ -n "${SHA256:-}" ] && printf '   %-9s %s\n' "SHA-256:" "$SHA256"
  local needle
  needle="$(printf '%s' "$sha1" | norm)"
  if registered_hashes | grep -qx "$needle"; then
    ok "$label SUDAH terdaftar di google-services.json (Firebase)."
  else
    fail "$label BELUM terdaftar di Firebase."
    echo "   → Firebase Console → Project Settings → Your apps → Android →"
    echo "     Add fingerprint → tempel SHA-1 (dan SHA-256) di atas, lalu"
    echo "     unduh ulang google-services.json ke android/app/google-services.json."
  fi
}

# ---------------------------------------------------------------- gen keystore
gen_keystore() {
  if [ -f "$KEY_PROPS" ] && [ "$FORCE" -ne 1 ]; then
    warn "android/key.properties sudah ada. Pakai --force untuk menimpanya."
    return 0
  fi

  local pw ks ext tmp
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)"

  if find_keytool >/dev/null 2>&1; then
    ks="$ROOT/android/app/upload-keystore.jks"
    [ -e "$ks" ] && { fail "$ks sudah ada — hapus dulu atau pakai keystore itu."; exit 1; }
    "$(find_keytool)" -genkeypair -v -storetype JKS -keystore "$ks" \
      -keyalg RSA -keysize 2048 -validity 10000 -alias "$ALIAS" \
      -storepass "$pw" -keypass "$pw" \
      -dname "CN=Rara Travel, OU=Android, O=Rara Travel, C=ID" >/dev/null
    ok "Keystore rilis dibuat: $ks"
  else
    warn "keytool tidak ditemukan — memakai openssl (format PKCS12, sama sah-nya)."
    ks="$ROOT/android/app/upload-keystore.p12"
    [ -e "$ks" ] && { fail "$ks sudah ada — hapus dulu atau pakai keystore itu."; exit 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 9999 \
      -subj "/CN=Rara Travel/OU=Android/O=Rara Travel/C=ID" 2>/dev/null
    openssl pkcs12 -export -in "$tmp/cert.pem" -inkey "$tmp/key.pem" \
      -out "$ks" -name "$ALIAS" -passout "pass:$pw"
    ok "Keystore rilis dibuat: $ks"
  fi

  {
    echo "# Dibuat otomatis oleh tools/check_sha.sh --gen-keystore"
    echo "# JANGAN di-commit (sudah masuk .gitignore). BACKUP file keystore + password ini!"
    echo "storePassword=$pw"
    echo "keyPassword=$pw"
    echo "keyAlias=$ALIAS"
    echo "storeFile=$ks"
  } > "$KEY_PROPS"
  ok "android/key.properties ditulis (storeFile: $ks)"
  echo ""
  echo "🔐 Password keystore : $pw"
  echo "   SIMPAN di tempat aman (password manager). Kalau hilang, aplikasi"
  echo "   TIDAK BISA di-update di Play Store selamanya."
  echo ""
}

# ---------------------------------------------------------------- main
echo "══════════════════════════════════════════════════════════"
echo " Rara Travel — Cek SHA fingerprint untuk Firebase / Play Store"
echo "══════════════════════════════════════════════════════════"
echo ""

[ "$GEN" -eq 1 ] && gen_keystore

# --- Debug keystore -------------------------------------------------
echo "── Debug keystore (dipakai CI + semua build lokal) ──"
DEBUG_KS="$ROOT/android/debug.keystore"
[ -f "$DEBUG_KS" ] || DEBUG_KS="${ANDROID_SDK_ROOT:-$HOME/.android}/debug.keystore"
[ -f "$DEBUG_KS" ] || DEBUG_KS="$HOME/.android/debug.keystore"
if [ -f "$DEBUG_KS" ]; then
  echo "   File: $DEBUG_KS"
  if fingerprint "$DEBUG_KS" "android" "androiddebugkey"; then
    check_registered "Debug" "$SHA1"
  else
    warn "Gagal membaca debug keystore ($DEBUG_KS)."
  fi
else
  warn "Debug keystore tidak ditemukan (repo maupun ~/.android)."
fi
echo ""

# --- Release keystore -------------------------------------------------
echo "── Release keystore (untuk build --release & Play Store) ──"
REL_KS=""
REL_PW=""
if [ -f "$KEY_PROPS" ]; then
  REL_KS="$(sed -n 's/^storeFile=//p' "$KEY_PROPS" | tail -1)"
  REL_PW="$(sed -n 's/^storePassword=//p' "$KEY_PROPS" | tail -1)"
  # path relatif di key.properties dihitung dari folder android/
  case "$REL_KS" in /*|?:*) ;; *) REL_KS="$ROOT/android/$REL_KS" ;; esac
else
  for c in "$HOME/upload-keystore.jks" "$HOME/upload-keystore.p12" \
           "$ROOT/android/app/upload-keystore.jks" "$ROOT/android/app/upload-keystore.p12"; do
    [ -f "$c" ] && { REL_KS="$c"; break; }
  done
fi

if [ -z "$REL_KS" ]; then
  warn "Keystore rilis belum ada."
  echo "   Buat otomatis : bash tools/check_sha.sh --gen-keystore"
  echo "   (atau manual sesuai PANDUAN_BUILD_APK.md langkah 3a)"
elif [ ! -f "$REL_KS" ]; then
  fail "storeFile di key.properties tidak ditemukan: $REL_KS"
else
  if [ -z "$REL_PW" ]; then
    printf 'Password keystore (%s): ' "$(basename "$REL_KS")"
    read -rs REL_PW; echo ""
  fi
  if fingerprint "$REL_KS" "$REL_PW" "$ALIAS" || fingerprint "$REL_KS" "$REL_PW"; then
    check_registered "Release ($(basename "$REL_KS"))" "$SHA1"
  else
    fail "Gagal membaca $REL_KS — password salah atau file corrupt."
  fi
fi
echo ""

# --- Status google-services.json ------------------------------------
echo "── Status google-services.json ──"
if [ ! -f "$GS_JSON" ]; then
  fail "$GS_JSON belum ada — jalankan tools/setup_firebase.sh dulu."
elif ! grep -q '"client_type": 1' "$GS_JSON"; then
  fail "Belum ada OAuth client Android (client_type 1) — artinya belum ada SHA-1 yang terdaftar di Firebase."
else
  N="$(registered_hashes | wc -l | tr -d ' ')"
  ok "$GS_JSON ada, $N SHA-1 terdaftar di Firebase."
fi

echo ""
echo "Selesai. Setelah menambah fingerprint baru di Firebase Console,"
echo "unduh ulang google-services.json lalu build ulang:"
echo "  flutter clean && flutter pub get && flutter build appbundle --release"
