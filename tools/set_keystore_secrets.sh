#!/usr/bin/env bash
# set_keystore_secrets.sh — simpan keystore rilis ke GitHub Secrets agar CI bisa
# membangun AAB bertanda tangan rilis untuk Play Store (lihat PANDUAN_BUILD_APK.md §3).
#
# Pemakaian:
#   bash tools/set_keystore_secrets.sh --keystore ~/upload-keystore.jks \
#        --alias rara-travel [--build]
#
# Lalu minta CI membangun AAB:
#   gh workflow run build-apk.yml -f aab=true
#
# Catatan: kunci TIDAK ikut ke repo. Secrets hanya bisa dibaca oleh workflow.
# Skrip ini tetap mencetak SHA-1/SHA-256 kunci upload — daftarkan ke Firebase
# Console (Project Settings → aplikasi Android → Add fingerprint), dan jangan
# lupa SHA Play App Signing setelah unggah AAB pertama (RILIS_PRODUKSI.md poin 3).
set -euo pipefail

JKS=""
ALIAS=""
BUILD=0
SEMENTARA=""

msg()  { printf '%s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
warn() { printf '!    %s\n' "$*"; }
fail() { printf 'X    %s\n' "$*" >&2; exit 1; }

pemakaian() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore) JKS="${2:-}"; shift 2 ;;
    --alias)    ALIAS="${2:-}"; shift 2 ;;
    --build)    BUILD=1; shift ;;
    -h|--help)  pemakaian ;;
    *) fail "Argumen tidak dikenal: $1 (pakai --help)" ;;
  esac
done

command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) tidak ditemukan — pasang dulu: https://cli.github.com"
gh auth status >/dev/null 2>&1 || fail "gh belum login. Jalankan: gh auth login"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
msg "Repositori: $REPO"

[ -n "$JKS" ] || read -r -p "Lokasi file keystore (.jks): " JKS
[ -f "$JKS" ] || fail "Berkas keystore tidak ditemukan: $JKS"
[ -n "$ALIAS" ] || read -r -p "Alias kunci (mis. rara-travel): " ALIAS
[ -n "$ALIAS" ] || fail "Alias tidak boleh kosong."

# --- sandi (disembunyikan saat diketik) --------------------------------------
baca_sandi() {
  local label="$1" variabel="$2" nilai=""
  if [ -t 0 ]; then
    read -r -s -p "$label" nilai
    printf '\n' >&2
  else
    read -r -p "$label" nilai
  fi
  printf -v "$variabel" '%s' "$nilai"
}
baca_sandi "Password keystore: " KS_PASS
baca_sandi "Password kunci (Enter = sama): " KEY_PASS
[ -n "$KEY_PASS" ] || KEY_PASS="$KS_PASS"
[ -n "$KS_PASS" ] || fail "Password keystore tidak boleh kosong."

# --- validasi: keystore & alias benar-benar cocok ----------------------------
if command -v keytool >/dev/null 2>&1; then
  if ! keytool -list -keystore "$JKS" -storepass "$KS_PASS" -alias "$ALIAS" >/dev/null 2>&1; then
    fail "Tidak bisa membuka keystore dengan alias/password itu. Cek lagi (tools/check_sha.sh --gen-keystore bila belum punya)."
  fi
  msg "Sidik jari kunci upload (daftarkan ke Firebase):"
  keytool -list -v -keystore "$JKS" -storepass "$KS_PASS" -alias "$ALIAS" 2>/dev/null \
    | grep -E "SHA1:|SHA256:" | sed 's/^/     /'
else
  warn "keytool tidak ada di PATH — sidik jari tidak bisa dicetak sekarang."
  warn "Buka Android Studio → JBR, atau jalankan: bash tools/check_sha.sh"
fi

# --- base64 (tanpa baris baru) ----------------------------------------------
B64="$(mktemp "${TMPDIR:-/tmp}/ks.XXXXXX")"
trap 'rm -f "$B64"' EXIT
if command -v openssl >/dev/null 2>&1; then
  openssl base64 -A -in "$JKS" -out "$B64"
else
  base64 < "$JKS" | tr -d '\n' > "$B64"
fi

set_secret() {
  local nama="$1" isi="$2"
  printf '%s' "$isi" | gh secret set "$nama" >/dev/null \
    || fail "Gagal menulis secret $nama (butuh izin repo admin)."
  ok "$nama tersimpan"
}

set_secret KEYSTORE_BASE64 "$(cat "$B64")"
set_secret KEYSTORE_PASSWORD "$KS_PASS"
set_secret KEY_ALIAS "$ALIAS"
set_secret KEY_PASSWORD "$KEY_PASS"

msg ""
msg "Selesai. Langkah berikutnya:"
msg "  1. gh workflow run build-apk.yml -f aab=true      # bangun AAB bertanda tangan rilis"
msg "  2. Daftarkan SHA di atas ke Firebase Console (wajib untuk login Google)."
msg "  3. Unggah AAB ke Play Console (pengujian tertutup lebih dulu)."
msg "  4. Setelah unggah pertama: daftarkan SHA-256 Play App Signing ke Firebase."
msg ""
msg "Backup keystore + password ke 2 tempat — kalau hilang, aplikasi di Play"
msg "tidak bisa diperbarui lewat kunci upload yang sama."

if [ "$BUILD" = "1" ]; then
  msg ""
  msg "Menjalankan CI (AAB)..."
  gh workflow run build-apk.yml -f aab=true
  ok "CI dijalankan. Pantau: gh run watch"
fi
