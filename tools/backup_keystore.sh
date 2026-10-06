#!/usr/bin/env bash
# backup_keystore.sh — bundel backup keystore rilis (terenkripsi) + verifikasinya.
#
#   bash tools/backup_keystore.sh sha      --keystore <file> [--storepass X] [--alias Y]
#   bash tools/backup_keystore.sh create   --keystore <file> [--alias rara-travel]
#                                          [--out DIR] [--include-password]
#   bash tools/backup_keystore.sh verify   <bundel.tar.gz.enc>
#   bash tools/backup_keystore.sh restore  <bundel.tar.gz.enc> --to <dir>
#   bash tools/backup_keystore.sh checklist
#
# `create` menghasilkan SATU berkas terenkripsi (AES-256-CBC + PBKDF2) berisi:
#   keystore/…            salinan keystore
#   SIDIK_JARI.txt        SHA-1 / SHA-256 / MD5 + masa berlaku sertifikat
#   key.properties        siap dipakai sebagai android/key.properties
#   INFO_BACKUP.txt       kapan, dari mesin mana, commit & versi aplikasi
#   PANDUAN_PULIHKAN.md   langkah pemulihan + jalur cadangan Play Console
#   MANIFEST.sha256       checksum semua berkas (dipakai `verify`)
#
# Sandi bundel DITANYA (tersembunyi) atau diambil dari $RARA_BACKUP_PASS.
# Simpan sandi itu TERPISAH dari bundelnya (mis. di password manager).
#
# PENTING: bundel JANGAN ditaruh di dalam repositori. Bawaan: ~/rara-keystore-backup.
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERINTAH="${1:-checklist}"
[ $# -gt 0 ] && shift

KEYSTORE=""
ALIAS=""
STOREPASS="${RARA_KEYSTORE_PASSWORD:-}"
OUT="${RARA_BACKUP_DIR:-$HOME/rara-keystore-backup}"
OUT_DISODORKAN=0
BUNDEL=""
INCLUDE_PASSWORD=0
GAGAL=0

ok()      { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
info()    { printf '  · %s\n' "$*"; }
baris()   { printf '    %s\n' "$*"; }
perhati() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
tolak()   { printf '\033[1;31m  ✖ %s\033[0m\n' "$*"; GAGAL=1; }
judul()   { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
gagal()   { printf '\033[1;31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

pakai_help() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore)   KEYSTORE="${2:-}"; shift 2 ;;
    --keystore=*) KEYSTORE="${1#*=}"; shift ;;
    --alias)      ALIAS="${2:-}"; shift 2 ;;
    --alias=*)    ALIAS="${1#*=}"; shift ;;
    --storepass)  STOREPASS="${2:-}"; shift 2 ;;
    --storepass=*) STOREPASS="${1#*=}"; shift ;;
    --out|--to)   OUT="${2:-}"; OUT_DISODORKAN=1; shift 2 ;;
    --out=*|--to=*) OUT="${1#*=}"; OUT_DISODORKAN=1; shift ;;
    --include-password) INCLUDE_PASSWORD=1; shift ;;
    -h|--help)    pakai_help; exit 0 ;;
    -*)           gagal "Argumen tidak dikenal: $1 (coba --help)" ;;
    *)            [ -z "$BUNDEL" ] && BUNDEL="$1"; shift ;;
  esac
done

command -v openssl >/dev/null 2>&1 || gagal "openssl tidak ada."

cari_keytool() {
  local c
  for c in keytool "${JAVA_HOME:-}/bin/keytool" \
           "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
           "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# sha256sum ada di Linux/Git Bash; macOS memakai shasum.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
cek_manifest() { # cek_manifest <dir>
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$1" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ); return $?
  fi
  ( cd "$1" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ); return $?
}
buat_manifest() { # buat_manifest <dir>
  local dir="$1" f
  : >"$dir/MANIFEST.sha256"
  while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256_of "$dir/$f")" "$f" >>"$dir/MANIFEST.sha256"
  done < <( cd "$dir" && find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' | sort )
}

# openssl mencetak 'sha1 Fingerprint=3F:40:…' (sudah bertitik dua) — normalisasi
fp_colon() {
  sed 's/.*=//' | tr -d ' \t:' | tr '[:lower:]' '[:upper:]' | sed 's/../&:/g; s/:$//'
}

# Sidik jari + info sertifikat keystore → SHA1/SHA256/MD5/SUBJECT/VALIDITY/STORETYPE.
baca_keystore() {
  local ks="$1" pass="${2:-}" alias="${3:-}" cert tmp
  SHA1=""; SHA256=""; MD5=""; SUBJECT=""; VALIDITY=""; STORETYPE=""
  [ -f "$ks" ] || { tolak "keystore tidak ditemukan: $ks"; return 1; }

  if cari_keytool >/dev/null 2>&1; then
    local args=(-list -v -keystore "$ks")
    [ -n "$pass" ]  && args+=(-storepass "$pass")
    [ -n "$alias" ] && args+=(-alias "$alias")
    tmp="$(mktemp)"
    if "$(cari_keytool)" "${args[@]}" >"$tmp" 2>/dev/null; then
      SHA1="$(grep -Eo 'SHA1: *[0-9A-Fa-f:]+'    "$tmp" | head -1 | sed 's/SHA1: *//'    | tr '[:lower:]' '[:upper:]')"
      SHA256="$(grep -Eo 'SHA256: *[0-9A-Fa-f:]+' "$tmp" | head -1 | sed 's/SHA256: *//' | tr '[:lower:]' '[:upper:]')"
      MD5="$(grep -Eo 'MD5: *[0-9A-Fa-f:]+'       "$tmp" | head -1 | sed 's/MD5: *//'     | tr '[:lower:]' '[:upper:]')"
      SUBJECT="$(grep -m1 'Owner:'      "$tmp" | sed 's/Owner: *//')"
      VALIDITY="$(grep -m1 'Valid from:' "$tmp" | sed 's/Valid from: *//')"
      STORETYPE="$(grep -m1 'Keystore type:' "$tmp" | sed 's/Keystore type: *//')"
    fi
    rm -f "$tmp"
    [ -n "$SHA1" ] && return 0
  fi

  # Tanpa Java: openssl membaca keystore PKCS#12 (.p12/.pfx, termasuk
  # android/debug.keystore bawaan Flutter yang sebenarnya PKCS12).
  # Keystore JKS lama tetap butuh keytool.
  cert="$(mktemp)"
  if openssl pkcs12 -in "$ks" -passin "pass:${pass}" -nokeys -clcerts -legacy \
        -out "$cert" 2>/dev/null \
     || openssl pkcs12 -in "$ks" -passin "pass:${pass}" -nokeys -clcerts \
        -out "$cert" 2>/dev/null; then
    SHA1="$(openssl x509 -in "$cert" -noout -fingerprint -sha1 2>/dev/null | fp_colon)"
    SHA256="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | fp_colon)"
    MD5="$(openssl x509 -in "$cert" -noout -fingerprint -md5 2>/dev/null | fp_colon)"
    SUBJECT="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject= *//')"
    VALIDITY="$(openssl x509 -in "$cert" -noout -dates 2>/dev/null | tr '\n' ' ' \
                | sed 's/notBefore=/dari /; s/notAfter=/sampai /')"
    STORETYPE="PKCS12"
  fi
  rm -f "$cert"
  [ -n "$SHA1" ] || { tolak "keystore tidak terbaca (JKS butuh keytool; atau password salah)."; return 1; }
  return 0
}

tanya_sandi() { # tanya_sandi <label> <var>
  local label="$1" nilai=""
  if [ -t 0 ]; then
    printf '  %s' "$label" >&2
    IFS= read -rs nilai >&2 || true
    printf '\n' >&2
  else
    IFS= read -r nilai || true
  fi
  printf '%s' "$nilai"
}

sandi_bundel() {
  if [ -n "${RARA_BACKUP_PASS:-}" ]; then printf '%s' "$RARA_BACKUP_PASS"; return 0; fi
  local p
  p="$(tanya_sandi "Sandi bundel backup (tidak terlihat saat diketik): ")"
  if [ -z "$p" ]; then
    printf '\033[1;31m  ✖ sandi bundel kosong\033[0m\n' >&2
    return 1
  fi
  printf '%s' "$p"
}

enkripsi() { # enkripsi <masuk> <keluar> <sandi>
  local masuk="$1" keluar="$2" sandi="$3"
  RARA_PASS="$sandi" openssl enc -aes-256-cbc -pbkdf2 -iter 300000 -salt \
    -in "$masuk" -out "$keluar" -pass env:RARA_PASS 2>/dev/null && return 0
  # OpenSSL lama tanpa -pbkdf2 → -md sha256 (tetap AES-256-CBC).
  RARA_PASS="$sandi" openssl enc -aes-256-cbc -md sha256 -salt \
    -in "$masuk" -out "$keluar" -pass env:RARA_PASS 2>/dev/null
}

dekripsi() { # dekripsi <masuk> <keluar> <sandi>
  local masuk="$1" keluar="$2" sandi="$3"
  RARA_PASS="$sandi" openssl enc -d -aes-256-cbc -pbkdf2 -iter 300000 \
    -in "$masuk" -out "$keluar" -pass env:RARA_PASS 2>/dev/null && return 0
  RARA_PASS="$sandi" openssl enc -d -aes-256-cbc -md sha256 \
    -in "$masuk" -out "$keluar" -pass env:RARA_PASS 2>/dev/null
}

versi_aplikasi() { sed -n 's/^version: *//p' "$AKAR/pubspec.yaml" | head -1; }
commit_repo()    { git -C "$AKAR" rev-parse --short HEAD 2>/dev/null || echo "-"; }

# ===========================================================================
# sha
# ===========================================================================
aksi_sha() {
  [ -n "$KEYSTORE" ] || { pakai_help; gagal "sebutkan keystore: sha --keystore <file>"; }
  judul "Sidik jari keystore: $(basename "$KEYSTORE")"
  baca_keystore "$KEYSTORE" "$STOREPASS" "$ALIAS" || return 1
  info "tipe    : ${STORETYPE:-?}"
  info "subject : ${SUBJECT:-?}"
  info "berlaku : ${VALIDITY:-?}"
  printf '  SHA-1  : %s\n' "$SHA1"
  printf '  SHA-256: %s\n' "$SHA256"
  [ -n "$MD5" ] && printf '  MD5    : %s\n' "$MD5"

  if [ -f "$AKAR/android/app/google-services.json" ] && [ -n "$SHA1" ]; then
    local needle daftar
    needle="$(printf '%s' "$SHA1" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    daftar="$(grep -o '"certificate_hash"[[:space:]]*:[[:space:]]*"[^"]*"' \
              "$AKAR/android/app/google-services.json" \
              | sed 's/.*"\([0-9a-fA-F]*\)".*/\1/' | tr '[:upper:]' '[:lower:]')"
    if printf '%s\n' "$daftar" | grep -qx "$needle"; then
      ok "SHA-1 ini SUDAH terdaftar di google-services.json (= di Firebase)."
    else
      perhati "SHA-1 ini BELUM ada di google-services.json."
      info "Firebase Console → Project settings → Your apps → Android → Add fingerprint"
      info "(SHA-1 + SHA-256), lalu unduh ulang google-services.json ke android/app/."
    fi
  fi
  info "SHA-256 juga wajib didaftarkan: dipakai Play Integrity / App Check versi rilis."
}

# ===========================================================================
# create
# ===========================================================================
aksi_create() {
  [ -n "$KEYSTORE" ] || { pakai_help; gagal "sebutkan keystore: create --keystore <file>"; }
  [ -f "$KEYSTORE" ] || gagal "keystore tidak ditemukan: $KEYSTORE"
  KEYSTORE="$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE")"
  [ -n "$ALIAS" ] || ALIAS="rara-travel"

  judul "Membuat bundel backup keystore"
  case "$KEYSTORE" in
    "$AKAR"/*debug.keystore) info "keystore debug bersama (memang di-commit) — aman." ;;
    "$AKAR"/*) tolak "keystore rilis berada DI DALAM repositori: $KEYSTORE"
               info "Pindahkan ke luar repo (mis. ~/kunci/). .gitignore sudah menolak"
               info "*.jks/*.keystore, tapi jangan mengandalkan itu saja." ;;
  esac
  case "$OUT" in
    "$AKAR"|"$AKAR"/*) gagal "folder keluaran tidak boleh di dalam repositori: $OUT" ;;
  esac

  if [ -z "$STOREPASS" ]; then
    perhati "password keystore belum diberikan — sidik jari mungkin tidak terbaca."
    STOREPASS="$(tanya_sandi "Password keystore (Enter = lewatkan): ")"
  fi
  baca_keystore "$KEYSTORE" "$STOREPASS" "$ALIAS" \
    || perhati "sidik jari tidak terbaca — bundel tetap dibuat (isi SIDIK_JARI.txt '?')."

  local staging sandi tag tgz bundel
  staging="$(mktemp -d "${TMPDIR:-/tmp}/rara-bundle.XXXXXX")" || gagal "mktemp gagal"
  chmod 700 "$staging"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  mkdir -p "$staging/keystore"
  cp "$KEYSTORE" "$staging/keystore/"
  chmod 600 "$staging/keystore/$(basename "$KEYSTORE")"

  {
    echo "Keystore : $(basename "$KEYSTORE")"
    echo "Alias    : ${ALIAS}"
    echo "Tipe     : ${STORETYPE:-?}"
    echo "Subject  : ${SUBJECT:-?}"
    echo "Berlaku  : ${VALIDITY:-?}"
    echo "SHA-1    : ${SHA1:-?}"
    echo "SHA-256  : ${SHA256:-?}"
    echo "MD5      : ${MD5:-?}"
    echo ""
    echo "SHA-1 + SHA-256 di atas harus terdaftar di Firebase Console"
    echo "(Project settings → Your apps → Android → Add fingerprint)."
  } >"$staging/SIDIK_JARI.txt"

  {
    echo "# Dibangkitkan tools/backup_keystore.sh — salin ke android/key.properties"
    echo "# (android/key.properties ada di .gitignore: JANGAN di-commit)"
    if [ "$INCLUDE_PASSWORD" = 1 ]; then
      echo "storePassword=${STOREPASS}"
      echo "keyPassword=${STOREPASS}"
    else
      echo "storePassword=ISI_DARI_PASSWORD_MANAGER"
      echo "keyPassword=ISI_DARI_PASSWORD_MANAGER"
    fi
    echo "keyAlias=${ALIAS}"
    echo "storeFile=KESTORE_INI_DARI_BUNDEL/$(basename "$KEYSTORE")"
  } >"$staging/key.properties"

  {
    echo "Dibuat        : $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Mesin         : $(hostname 2>/dev/null || echo '?') ($(uname -sr 2>/dev/null))"
    echo "Keystore asal : $KEYSTORE"
    echo "Versi aplikasi: $(versi_aplikasi)"
    echo "Commit repo   : $(commit_repo)"
    echo "Enkripsi      : openssl enc -aes-256-cbc -pbkdf2 -iter 300000 -salt"
    echo "                (cadangan otomatis: -md sha256 bila openssl lama)"
    echo ""
    echo "Sandi bundel disimpan TERPISAH dari berkas ini (password manager)."
  } >"$staging/INFO_BACKUP.txt"

  cat >"$staging/PANDUAN_PULIHKAN.md" <<'MD'
# Memulihkan keystore Rara Travel

## 1. Dekripsi bundel
```bash
bash tools/backup_keystore.sh restore rara-keystore-<tanggal>.tar.gz.enc --to ~/kunci-rara
# ditanya sandi bundel → isi (sandinya disimpan di password manager)
```
Pakai `verify` bila hanya ingin memastikan bundel utuh tanpa memakainya.

## 2. Pasang di mesin build
```bash
cp ~/kunci-rara/keystore/*.jks ~/upload-keystore.jks
cp ~/kunci-rara/key.properties <repo>/android/key.properties   # isi passwordnya
```
Bangun AAB:
`flutter build appbundle --release --obfuscate --split-debug-info=build/symbols`
atau lewat CI:
`bash tools/set_keystore_secrets.sh --keystore ~/upload-keystore.jks --alias rara-travel`
lalu `gh workflow run build-apk.yml -f aab=true`.

## 3. Cocokkan sidik jari
Bandingkan `SIDIK_JARI.txt` dengan keluaran `bash tools/check_sha.sh`.
Bila SHA berubah, daftarkan ulang di Firebase Console (Project settings →
Your apps → Android → Add fingerprint) dan unduh ulang `google-services.json`.

## 4. Kalau keystore benar-benar hilang
Aplikasi ini diunggah sebagai **AAB dengan Play App Signing**, jadi kunci
penanda tangan aplikasi dipegang Google:
* **Kunci upload hilang / password lupa** → Play Console → *Test and release →
  Setup → App signing → Request upload key reset*. Buat keystore baru
  (`bash tools/check_sha.sh --gen-keystore`), daftarkan SHA-nya ke Firebase,
  lalu unggah build berikutnya dengan kunci baru. Pengguna tetap bisa update.
* **Tanpa Play App Signing** (mis. APK di luar Play): kunci yang hilang tidak
  bisa dipulihkan dan aplikasi tidak bisa diperbarui lagi — karena itu backup
  ini wajib ada di dua tempat.
MD

  buat_manifest "$staging"

  tag="$(date -u +%Y%m%d-%H%M)"
  mkdir -p "$OUT" || gagal "tidak bisa membuat folder keluaran: $OUT"
  tgz="$OUT/rara-keystore-${ALIAS}-${tag}.tar.gz"
  bundel="$tgz.enc"
  [ -e "$bundel" ] && gagal "bundel dengan nama ini sudah ada: $bundel"
  tar -czf "$tgz" -C "$staging" . || gagal "tar gagal"

  sandi="$(sandi_bundel)" || { rm -f "$tgz"; return 1; }
  if ! enkripsi "$tgz" "$bundel" "$sandi"; then
    rm -f "$tgz"; gagal "enkripsi gagal"
  fi
  rm -f "$tgz"
  chmod 600 "$bundel"
  sha256_of "$bundel" >"$bundel.sha256"
  chmod 600 "$bundel.sha256"

  rm -rf "$staging"; trap - EXIT

  ok "bundel terenkripsi: $bundel"
  info "ukuran  : $(du -h "$bundel" 2>/dev/null | cut -f1)"
  info "SHA-256 : $(cat "$bundel.sha256")  (salinan: $bundel.sha256)"
  printf '\n'
  info "Salin ke DUA tempat berbeda (syarat AUDIT_RILIS.md §3.5):"
  baris "1. brankas cloud / password manager ber-2FA (lampiran)"
  baris "2. media offline (USB atau hard disk di tempat aman)"
  info "Sandi bundel: simpan di password manager, TERPISAH dari berkasnya."
  info "Salinan ketiga (khusus CI): bash tools/set_keystore_secrets.sh"
  info "Uji salinannya: bash tools/backup_keystore.sh verify '$bundel'"
  perhati "JANGAN commit bundel ini — biarkan di luar repositori."
}

# ===========================================================================
# verify
# ===========================================================================
aksi_verify() {
  [ -n "$BUNDEL" ] && [ -f "$BUNDEL" ] || gagal "sebutkan bundel: verify <berkas.tar.gz.enc>"
  judul "Memverifikasi $(basename "$BUNDEL")"
  local sandi tmp tgz dir harapan nyata
  if [ -f "$BUNDEL.sha256" ]; then
    harapan="$(cat "$BUNDEL.sha256")"; nyata="$(sha256_of "$BUNDEL")"
    if [ "$harapan" = "$nyata" ]; then ok "checksum berkas cocok ($nyata)"
    else tolak "checksum TIDAK cocok — salinan rusak atau berubah"; fi
  else
    perhati "tidak ada .sha256 di sebelahnya — pemeriksaan checksum dilewati"
  fi

  sandi="$(sandi_bundel)" || return 1
  tmp="$(mktemp -d)"; tgz="$tmp/b.tar.gz"; dir="$tmp/isi"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  if ! dekripsi "$BUNDEL" "$tgz" "$sandi"; then
    tolak "dekripsi gagal — sandi salah atau berkas rusak"
    rm -rf "$tmp"; trap - EXIT
    return 1
  fi
  ok "dekripsi berhasil (AES-256-CBC)"
  mkdir -p "$dir" && tar -xzf "$tgz" -C "$dir" || { tolak "ekstraksi gagal"; return 1; }
  if [ -f "$dir/MANIFEST.sha256" ]; then
    if cek_manifest "$dir"; then ok "semua isi bundel utuh (MANIFEST.sha256)"
    else
      tolak "ada isi yang tidak cocok dengan MANIFEST.sha256"
      ( cd "$dir" && sha256sum -c MANIFEST.sha256 2>&1 | sed 's/^/      /' )
    fi
  else
    perhati "MANIFEST.sha256 tidak ada di dalam bundel"
  fi
  printf '\n'
  [ -f "$dir/INFO_BACKUP.txt" ] && sed 's/^/  /' "$dir/INFO_BACKUP.txt"
  [ -f "$dir/SIDIK_JARI.txt" ] && { printf '\n'; sed 's/^/  /' "$dir/SIDIK_JARI.txt"; }
  ls "$dir/keystore" 2>/dev/null | sed 's/^/  keystore: /'
  rm -rf "$tmp"; trap - EXIT
}

# ===========================================================================
# restore
# ===========================================================================
aksi_restore() {
  [ -n "$BUNDEL" ] && [ -f "$BUNDEL" ] || gagal "sebutkan bundel: restore <berkas.tar.gz.enc> --to <dir>"
  if [ "$OUT_DISODORKAN" != 1 ]; then
    OUT="$HOME/kunci-rara-$(date -u +%Y%m%d-%H%M)"
    info "tanpa --to: dipulihkan ke $OUT (di luar repositori)."
  fi
  case "$OUT" in
    "$AKAR"|"$AKAR"/*) gagal "jangan pulihkan keystore ke dalam repositori: $OUT" ;;
  esac
  judul "Memulihkan $(basename "$BUNDEL") → $OUT"
  local sandi tmp tgz
  sandi="$(sandi_bundel)" || return 1
  tmp="$(mktemp -d)"; tgz="$tmp/b.tar.gz"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  dekripsi "$BUNDEL" "$tgz" "$sandi" || { tolak "dekripsi gagal"; return 1; }
  mkdir -p "$OUT" || { tolak "folder tujuan tidak bisa dibuat: $OUT"; return 1; }
  chmod 700 "$OUT"
  tar -xzf "$tgz" -C "$OUT" || { tolak "ekstraksi gagal"; return 1; }
  rm -rf "$tmp"; trap - EXIT
  ok "isi bundel dipulihkan ke $OUT"
  ls -1 "$OUT" | sed 's/^/      /'
  info "Lanjut: baca PANDUAN_PULIHKAN.md di dalam folder itu."
}

# ===========================================================================
# checklist
# ===========================================================================
aksi_checklist() {
  judul "Backup keystore — checklist rilis (AUDIT_RILIS.md §3.5)"
  info "1. Keystore rilis (.jks) + alias + password tersimpan di PASSWORD MANAGER."
  info "2. Bundel terenkripsi ada di DUA tempat berbeda:"
  baris "· brankas cloud ber-2FA (lampiran)"
  baris "· media offline (USB atau hard disk di tempat aman)"
  info "3. Salinan untuk CI: bash tools/set_keystore_secrets.sh --keystore <file.jks>"
  info "     (menyimpan KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD"
  info "      sebagai GitHub Secrets — hanya workflow yang bisa membacanya)"
  info "4. SHA-1 + SHA-256 kunci upload terdaftar di Firebase Console."
  info "5. Setelah unggah AAB pertama: SHA-256 PLAY APP SIGNING ikut didaftarkan"
  info "     (Play Console → Test and release → Setup → App signing)."
  info "6. symbols-*.zip tiap versi diarsipkan (untuk membaca crash rilis ter-obfuscate)."
  printf '\n'
  info "Perintah yang tersedia:"
  info "  buat bundel : bash tools/backup_keystore.sh create --keystore ~/upload-keystore.jks"
  info "  uji bundel  : bash tools/backup_keystore.sh verify  <bundel.tar.gz.enc>"
  info "  pulihkan    : bash tools/backup_keystore.sh restore <bundel.tar.gz.enc> --to ~/kunci-rara"
  info "  sidik jari  : bash tools/backup_keystore.sh sha --keystore <file> --storepass <pass>"
  printf '\n'
  info "Keystore hilang? Dengan Play App Signing masih bisa: Play Console →"
  info "App signing → 'Request upload key reset'. Tanpa Play App Signing: fatal."
  if [ -f "$AKAR/android/key.properties" ]; then
    perhati "android/key.properties ada di mesin ini — pastikan tidak pernah ter-commit"
    info "cek: git -C '$AKAR' check-ignore -v android/key.properties"
  fi
}

case "$PERINTAH" in
  sha)       aksi_sha ;;
  create)    aksi_create ;;
  verify)    aksi_verify ;;
  restore)   aksi_restore ;;
  checklist) aksi_checklist ;;
  -h|--help) pakai_help; exit 0 ;;
  *) printf '\033[1;31m❌ Perintah tidak dikenal: %s\033[0m\n' "$PERINTAH" >&2
     pakai_help; exit 2 ;;
esac

exit "$GAGAL"
