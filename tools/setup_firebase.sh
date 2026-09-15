#!/usr/bin/env bash
# ============================================================================
# tools/setup_firebase.sh — menyambungkan proyek Rara Travel ke Firebase.
#
#   cp .env.firebase.example .env.firebase   # lalu isi FIREBASE_PROJECT_ID
#   bash tools/setup_firebase.sh             # jalankan semua langkah
#   bash tools/setup_firebase.sh --check     # periksa saja, tidak mengubah apa pun
#   bash tools/setup_firebase.sh --step 5    # hanya langkah tertentu (boleh >1)
#   bash tools/setup_firebase.sh --sha       # cetak SHA-1 / SHA-256 debug
#   bash tools/setup_firebase.sh --functions # ikut deploy Cloud Functions (Blaze)
#   bash tools/setup_firebase.sh --help
#
# Langkah:
#   1 periksa alat & berkas yang kurang     5 flutterfire configure (json + options)
#   2 pasang firebase-tools + flutterfire   6 deploy rules + indexes Firestore
#   3 login Firebase CLI                    7 SHA-1 + checklist Console
#   4 sambungkan project (.firebaserc)
#
# Yang TIDAK bisa diotomatisasi (wajib di Console, langkah 7 mencetak daftar):
#   Auth Phone, Auth Google, nomor uji, daftar SHA, App Check, buat Firestore DB.
#
# Aman dijalankan berulang: langkah yang sudah beres akan dilewati.
# ============================================================================
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${FIREBASE_ENV_FILE:-$AKAR/.env.firebase}"
MODE_CHECK=0
MODE_SHA=0
MODE_FUNCTIONS=0
LANGKAH_DIMINTA=()
GAGAL=0
PACKAGE_ANDROID="com.raratravel.app"

# ---------------------------------------------------------------------------
# Utilitas tampilan
# ---------------------------------------------------------------------------
hijau() { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah() { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul() { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok() { hijau "  ✔ $*"; }
tolak() { merah "  ✖ $*"; GAGAL=1; }
info() { printf '  · %s\n' "$*"; }
lewat() { kuning "  ↷ $*"; }

pakai_help() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argumen
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) pakai_help ;;
    --check) MODE_CHECK=1; shift ;;
    --sha) MODE_SHA=1; shift ;;
    --functions) MODE_FUNCTIONS=1; shift ;;
    --step) LANGKAH_DIMINTA+=("$2"); shift 2 ;;
    --step=*) LANGKAH_DIMINTA+=("${1#*=}"); shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    *) merah "Argumen tidak dikenal: $1"; pakai_help ;;
  esac
done

ingin() {
  [ ${#LANGKAH_DIMINTA[@]} -eq 0 ] && return 0
  local n
  for n in "${LANGKAH_DIMINTA[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Muat setelan
# ---------------------------------------------------------------------------
muat_env() {
  local f
  for f in "$ENV_FILE" "$AKAR/.env.supabase"; do
    [ -f "$f" ] || continue
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  done
}
muat_env
: "${FIREBASE_PROJECT_ID:=}"

# Baca project id dari .firebaserc bila env kosong.
baca_firebaserc() {
  local f="$AKAR/.firebaserc"
  [ -f "$f" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
pid = (data.get("projects") or {}).get("default") or ""
if pid and pid != "PROJECT_ID_KAMU":
    print(pid)
PY
}

if [ -z "$FIREBASE_PROJECT_ID" ]; then
  FIREBASE_PROJECT_ID="$(baca_firebaserc || true)"
fi

# PATH pub-cache (flutterfire)
export PATH="$PATH:${HOME}/.pub-cache/bin:${LOCALAPPDATA:-}/Pub/Cache/bin"

# ---------------------------------------------------------------------------
# Deteksi CLI
# ---------------------------------------------------------------------------
FB=()
SUMBER_FB="tidak ada"
if command -v firebase >/dev/null 2>&1; then
  FB=(firebase)
  SUMBER_FB="terpasang ($(firebase --version 2>/dev/null | head -1))"
elif [ "$MODE_CHECK" != 1 ] && command -v npx >/dev/null 2>&1; then
  # npx mengunduh paket — jangan dipakai saat --check (bisa menggantung).
  FB=(npx --yes firebase-tools)
  SUMBER_FB="lewat npx"
fi
jalankan_fb() { [ ${#FB[@]} -gt 0 ] && "${FB[@]}" "$@"; }

FF=()
SUMBER_FF="tidak ada"
if command -v flutterfire >/dev/null 2>&1; then
  FF=(flutterfire)
  SUMBER_FF="terpasang ($(flutterfire --version 2>/dev/null | head -1))"
fi

firebase_siap_login() {
  # Hanya cek biner global — npx/projects:list butuh jaringan dan bisa lama.
  command -v firebase >/dev/null 2>&1 || return 1
  [ "$MODE_CHECK" = 1 ] && return 1
  firebase projects:list >/dev/null 2>&1
}

options_sudah_isi() {
  local f="$AKAR/lib/firebase_options.dart"
  [ -f "$f" ] || return 1
  grep -q "apiKey:" "$f" && grep -q "static const FirebaseOptions android" "$f"
}

json_ada() { [ -f "$AKAR/android/app/google-services.json" ]; }

# ===========================================================================
# 1. Pemeriksaan berkas & alat
# ===========================================================================
langkah_1() {
  judul "1. Memeriksa alat & berkas Firebase"

  info "Kode aplikasi (sudah ada di repo — tidak perlu ditulis ulang):"
  [ -f "$AKAR/lib/services/firebase_bootstrap.dart" ] && ok "FirebaseBootstrap + mode offline"
  [ -f "$AKAR/lib/services/auth_service.dart" ] && ok "Auth OTP SMS + Google Sign-In"
  [ -f "$AKAR/lib/services/firestore_service.dart" ] && ok "Firestore users + bookings"
  [ -f "$AKAR/lib/services/messaging_service.dart" ] && ok "FCM (token + notifikasi)"
  [ -f "$AKAR/firestore.rules" ] && ok "firestore.rules"
  [ -f "$AKAR/firestore.indexes.json" ] && ok "firestore.indexes.json"
  [ -f "$AKAR/functions_sample/index.js" ] && ok "functions_sample (notifikasi status)"
  [ -f "$AKAR/firebase.json" ] && ok "firebase.json (siap deploy CLI)" \
    || tolak "firebase.json belum ada"

  printf '\n'
  info "Sambungan ke project Firebase (yang biasanya masih kurang):"

  if json_ada; then
    ok "android/app/google-services.json"
  else
    tolak "android/app/google-services.json belum ada → langkah 5 (flutterfire configure)"
  fi

  if options_sudah_isi; then
    ok "lib/firebase_options.dart sudah terisi"
  else
    tolak "lib/firebase_options.dart masih STUB → langkah 5 (flutterfire configure)"
  fi

  if [ -f "$AKAR/.firebaserc" ]; then
    ok ".firebaserc (project: ${FIREBASE_PROJECT_ID:-terbaca})"
  else
    tolak ".firebaserc belum ada → langkah 4"
  fi

  if [ -n "$FIREBASE_PROJECT_ID" ]; then
    ok "FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID"
  else
    tolak "FIREBASE_PROJECT_ID kosong — isi .env.firebase atau buat project di Console"
  fi

  printf '\n'
  info "Perkakas CLI:"
  if command -v node >/dev/null 2>&1; then
    ok "Node.js $(node -v)"
  else
    tolak "Node.js tidak ada — pasang LTS dari https://nodejs.org"
  fi
  if command -v npm >/dev/null 2>&1; then
    ok "npm $(npm -v)"
  else
    tolak "npm tidak ada"
  fi
  if command -v firebase >/dev/null 2>&1; then
    ok "firebase-tools $SUMBER_FB"
  elif command -v npx >/dev/null 2>&1; then
    kuning "  ! firebase-tools belum global → langkah 2 (npm i -g firebase-tools); cadangan: npx"
  else
    tolak "firebase-tools tidak ada → langkah 2 (npm i -g firebase-tools)"
  fi
  if [ ${#FF[@]} -gt 0 ]; then
    ok "flutterfire $SUMBER_FF"
  else
    kuning "  ! flutterfire CLI belum ada → langkah 2 (dart pub global activate flutterfire_cli)"
  fi
  if command -v dart >/dev/null 2>&1; then
    ok "dart $(dart --version 2>&1 | head -1)"
  else
    kuning "  ! dart/flutter tidak ada di PATH — langkah 5 perlu Flutter SDK"
  fi
  if command -v flutter >/dev/null 2>&1; then
    ok "flutter $(flutter --version 2>/dev/null | head -1)"
  else
    kuning "  ! flutter tidak ada di PATH"
  fi

  if [ "$MODE_CHECK" = 1 ]; then
    if command -v firebase >/dev/null 2>&1; then
      info "uji login nanti: firebase projects:list"
    else
      kuning "  ! belum login Firebase → langkah 3 (firebase login)"
    fi
  elif firebase_siap_login; then
    ok "sudah login Firebase CLI"
  else
    kuning "  ! belum login Firebase → langkah 3 (firebase login)"
  fi
}

# ===========================================================================
# 2. Pasang CLI
# ===========================================================================
langkah_2() {
  judul "2. Memasang firebase-tools + flutterfire CLI"
  if [ "$MODE_CHECK" = 1 ]; then
    if command -v firebase >/dev/null 2>&1; then
      ok "firebase-tools sudah ada"
    else
      kuning "  ! firebase-tools belum global — langkah 2 akan memasangnya"
    fi
    [ ${#FF[@]} -gt 0 ] && ok "flutterfire sudah ada" || kuning "  ! flutterfire belum terpasang"
    return 0
  fi

  if [ ${#FB[@]} -eq 0 ] || [ "$SUMBER_FB" = "lewat npx" ]; then
    if ! command -v npm >/dev/null 2>&1; then
      tolak "npm tidak ada — tidak bisa memasang firebase-tools"
    else
      info "memasang firebase-tools secara global…"
      if npm install -g firebase-tools; then
        FB=(firebase)
        SUMBER_FB="terpasang ($(firebase --version 2>/dev/null | head -1))"
        ok "firebase-tools $SUMBER_FB"
      else
        tolak "gagal memasang firebase-tools"
      fi
    fi
  else
    ok "firebase-tools sudah ada ($SUMBER_FB)"
  fi

  if [ ${#FF[@]} -eq 0 ]; then
    if ! command -v dart >/dev/null 2>&1; then
      kuning "  ! dart tidak ada — lewati flutterfire. Pasang Flutter SDK, lalu ulangi langkah 2."
    else
      info "mengaktifkan flutterfire_cli…"
      if dart pub global activate flutterfire_cli; then
        export PATH="$PATH:${HOME}/.pub-cache/bin"
        if command -v flutterfire >/dev/null 2>&1; then
          FF=(flutterfire)
          SUMBER_FF="terpasang ($(flutterfire --version 2>/dev/null | head -1))"
          ok "flutterfire $SUMBER_FF"
        else
          kuning "  ! flutterfire terpasang tapi belum di PATH. Tambahkan ~/.pub-cache/bin lalu buka terminal baru."
        fi
      else
        tolak "gagal mengaktifkan flutterfire_cli"
      fi
    fi
  else
    ok "flutterfire sudah ada ($SUMBER_FF)"
  fi
}

# ===========================================================================
# 3. Login
# ===========================================================================
langkah_3() {
  judul "3. Login Firebase CLI"
  if [ "$MODE_CHECK" = 1 ]; then
    if command -v firebase >/dev/null 2>&1; then
      ok "firebase CLI ada — uji login nanti dengan: firebase projects:list"
    else
      kuning "  ! firebase CLI belum global (langkah 2)"
    fi
    return 0
  fi
  if [ ${#FB[@]} -eq 0 ]; then
    tolak "firebase-tools tidak ada (langkah 2 dulu)"
    return 1
  fi
  if firebase_siap_login; then
    ok "sudah login"
    jalankan_fb projects:list 2>/dev/null | sed 's/^/    /' | head -20
    return 0
  fi
  if [ -n "${FIREBASE_TOKEN:-}" ] || [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    ok "memakai token/kredensial dari lingkungan"
    return 0
  fi
  if [ "$MODE_CHECK" = 1 ]; then
    tolak "belum login (jalankan tanpa --check: firebase login)"
    return 1
  fi
  info "membuka peramban untuk login Google…"
  if jalankan_fb login; then
    ok "login berhasil"
  else
    tolak "login gagal. Alternatif: firebase login --no-localhost"
  fi
}

# ===========================================================================
# 4. Sambungkan project
# ===========================================================================
tulis_firebaserc() {
  local pid="$1"
  python3 - "$AKAR/.firebaserc" "$pid" <<'PY'
import json, sys
jalur, pid = sys.argv[1], sys.argv[2]
json.dump({"projects": {"default": pid}}, open(jalur, "w", encoding="utf-8"), indent=2)
open(jalur, "a", encoding="utf-8").write("\n")
PY
}

langkah_4() {
  judul "4. Menyambungkan ke project Firebase"
  if [ -n "$FIREBASE_PROJECT_ID" ]; then
    ok "project id: $FIREBASE_PROJECT_ID"
    if [ "$MODE_CHECK" = 1 ]; then
      [ -f "$AKAR/.firebaserc" ] && ok ".firebaserc ada" \
        || kuning "  ! .firebaserc belum ditulis (jalankan tanpa --check)"
      return 0
    fi
    tulis_firebaserc "$FIREBASE_PROJECT_ID"
    ok "ditulis ke .firebaserc"
    return 0
  fi

  if [ "$MODE_CHECK" = 1 ]; then
    tolak "FIREBASE_PROJECT_ID belum diisi — buat project di https://console.firebase.google.com"
    info "Nama disarankan: rara-travel  →  catat Project ID, bukan Display name"
    info "Lalu: cp .env.firebase.example .env.firebase && isi FIREBASE_PROJECT_ID="
    return 1
  fi

  merah "  FIREBASE_PROJECT_ID belum diisi."
  info "1. Buka https://console.firebase.google.com → Add project"
  info "2. Nama: rara-travel → Analytics OFF → Create"
  info "3. Catat Project ID (mis. rara-travel-a1b2c)"
  info "4. Simpan:  echo FIREBASE_PROJECT_ID=xxxx > .env.firebase"
  info "5. Ulangi:  bash tools/setup_firebase.sh"
  if [ -t 0 ] && [ ${#FB[@]} -gt 0 ]; then
    printf '  Project ID (kosongkan untuk batal): '
    local pid=""
    read -r pid || true
    if [ -n "$pid" ]; then
      FIREBASE_PROJECT_ID="$pid"
      tulis_firebaserc "$pid"
      printf 'FIREBASE_PROJECT_ID=%s\n' "$pid" >>"$ENV_FILE"
      ok "tersimpan: $pid"
      return 0
    fi
  fi
  tolak "tidak ada project id — langkah 4 belum selesai"
  return 1
}

# Generate lib/firebase_options.dart dari google-services.json (tanpa FlutterFire).
isi_options_dari_json() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$AKAR/tools/gen_firebase_options.py" "$AKAR/android/app/google-services.json"
}

# ===========================================================================
# 5. flutterfire configure ATAU generate dari google-services.json
# ===========================================================================
langkah_5() {
  judul "5. Mengisi google-services.json + firebase_options.dart"
  if json_ada && options_sudah_isi; then
    ok "google-services.json & firebase_options.dart sudah ada — dilewati"
    return 0
  fi
  if [ "$MODE_CHECK" = 1 ]; then
    json_ada || tolak "google-services.json belum ada"
    options_sudah_isi || tolak "firebase_options.dart masih stub"
    return 0
  fi

  # Jalur A: json sudah diunduh dari Console → generate options, selesai.
  if json_ada; then
    info "google-services.json ada — mengisi firebase_options.dart…"
    if isi_options_dari_json && options_sudah_isi; then
      ok "lib/firebase_options.dart terisi dari json"
      return 0
    fi
    kuning "  ! generate options gagal — coba flutterfire bila ada"
  fi

  if [ -z "$FIREBASE_PROJECT_ID" ]; then
    tolak "FIREBASE_PROJECT_ID kosong (langkah 4 dulu)"
    return 1
  fi
  if [ ${#FF[@]} -eq 0 ]; then
    if json_ada; then
      tolak "json ada tapi firebase_options.dart gagal diisi. Jalankan: python3 tools/gen_firebase_options.py"
    else
      tolak "belum ada google-services.json dan flutterfire tidak ada."
      info "Unduh json: Console → Project settings → Your apps → Android → google-services.json"
      info "Taruh di android/app/google-services.json lalu: python3 tools/gen_firebase_options.py"
    fi
    return 1
  fi
  info "menghubungkan Android $PACKAGE_ANDROID ke $FIREBASE_PROJECT_ID…"
  if ( cd "$AKAR" && "${FF[@]}" configure \
        --project="$FIREBASE_PROJECT_ID" \
        --platforms=android \
        --android-package-name="$PACKAGE_ANDROID" \
        --yes ); then
    json_ada && ok "android/app/google-services.json" || tolak "json masih belum ada"
    if ! options_sudah_isi && json_ada; then
      isi_options_dari_json || true
    fi
    options_sudah_isi && ok "lib/firebase_options.dart terisi" || tolak "firebase_options.dart masih stub"
    if grep -c 'google-services' "$AKAR/android/app/build.gradle" | grep -q '[2-9]'; then
      kuning "  ! ada baris google-services lebih dari satu di android/app/build.gradle — sisakan yang kondisional di bawah"
    fi
  else
    tolak "flutterfire configure gagal — cek login & project id"
    return 1
  fi
}

# ===========================================================================
# 6. Deploy rules + indexes
# ===========================================================================
langkah_6() {
  judul "6. Deploy Firestore rules + indexes"
  if [ "$MODE_CHECK" = 1 ]; then
    info "akan men-deploy firestore.rules + firestore.indexes.json ke project ${FIREBASE_PROJECT_ID:-?}"
    info "Syarat: database Firestore sudah dibuat di Console (production, asia-southeast2)"
    return 0
  fi
  if [ ${#FB[@]} -eq 0 ]; then
    tolak "firebase-tools tidak ada"
    return 1
  fi
  if [ -z "$FIREBASE_PROJECT_ID" ]; then
    tolak "FIREBASE_PROJECT_ID kosong"
    return 1
  fi
  if ! firebase_siap_login && [ -z "${FIREBASE_TOKEN:-}" ]; then
    tolak "belum login (langkah 3)"
    return 1
  fi
  info "deploy rules & indexes ke $FIREBASE_PROJECT_ID…"
  if ( cd "$AKAR" && jalankan_fb deploy --only firestore:rules,firestore:indexes --project="$FIREBASE_PROJECT_ID" ); then
    ok "rules + indexes terpasang di server"
  else
    tolak "deploy gagal. Biasanya karena database belum dibuat."
    info "Console → Build → Firestore Database → Create database"
    info "  mode: Production · lokasi: asia-southeast2 (Jakarta) → Enable"
    info "Lalu ulangi: bash tools/setup_firebase.sh --step 6"
    return 1
  fi
}

# ===========================================================================
# SHA-1 / SHA-256
# ===========================================================================
cari_keytool() {
  local kandidat
  for kandidat in \
      "keytool" \
      "${JAVA_HOME:-}/bin/keytool" \
      "/usr/bin/keytool" \
      "/Library/Java/JavaVirtualMachines"/*/Contents/Home/bin/keytool \
      "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
      "${LOCALAPPDATA:-}/Android/Sdk" \
      ; do
    if command -v "$kandidat" >/dev/null 2>&1; then
      printf '%s\n' "$kandidat"
      return 0
    fi
    if [ -x "$kandidat" ]; then
      printf '%s\n' "$kandidat"
      return 0
    fi
  done
  # Windows Git Bash
  local win
  win="/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe"
  [ -x "$win" ] && { printf '%s\n' "$win"; return 0; }
  return 1
}

cetak_sha() {
  judul "Sidik jari SHA debug (wajib untuk OTP asli & login Google)"
  local keytool store
  keytool="$(cari_keytool || true)"
  store="${HOME}/.android/debug.keystore"
  if [ ! -f "$store" ]; then
    kuning "  ! debug.keystore belum ada ($store)"
    info "File ini muncul otomatis setelah satu kali build Android."
    info "Jalankan: flutter build apk --debug   lalu ulangi --sha"
    return 0
  fi
  if [ -z "$keytool" ]; then
    kuning "  ! keytool tidak ditemukan. Pasang JDK 17 / Android Studio."
    info "Windows: C:\\Program Files\\Android\\Android Studio\\jbr\\bin\\keytool.exe"
    return 0
  fi
  info "keystore: $store"
  "$keytool" -list -v -keystore "$store" -alias androiddebugkey \
    -storepass android -keypass android 2>/dev/null \
    | grep -E 'SHA1:|SHA-1:|SHA256:|SHA-256:' \
    | sed 's/^/    /'
  printf '\n'
  info "Salin SHA1 & SHA-256 ke:"
  info "  Console → Project settings → Your apps → Android (com.raratravel.app) → Add fingerprint"
  info "Lalu unduh ulang google-services.json ATAU ulangi langkah 5."
}

# ===========================================================================
# 7. Checklist Console
# ===========================================================================
langkah_7() {
  cetak_sha
  judul "7. Checklist yang wajib di Firebase Console"
  info "CLI tidak bisa mengaktifkan ini — klik satu-satu (±15 menit):"
  printf '\n'
  info "A. Authentication → Sign-in method"
  info "     • Phone  → Enable → Save"
  info "     • Google → Enable → Save"
  info "B. Authentication → Settings → Phone numbers for testing"
  info "     • tambah mis. +62 812 0000 0001 kode 123456  (gratis unlimited)"
  info "C. Build → Firestore Database"
  info "     • Create database · Production · asia-southeast2 (Jakarta)"
  info "     • (rules sudah di-deploy langkah 6; kalau belum, paste firestore.rules → Publish)"
  info "D. Project settings → Your apps → Android → Add fingerprint (SHA-1 + SHA-256 di atas)"
  info "E. App Check (disarankan sebelum rilis)"
  info "     • daftarkan app Android · provider Play Integrity"
  info "     • tambah debug token dari logcat · Enforcement: Firestore + Authentication"
  info "F. (Opsional, paket Blaze) Cloud Functions — lihat --functions / PANDUAN_FIREBASE.md langkah 8"
  printf '\n'
  info "Uji setelah A–D selesai:"
  info "  flutter pub get && flutter run"
  info "  Tab Pesananku → Masuk → nomor uji + kode uji → booking muncul di Firestore"
}

# ===========================================================================
# Functions (opsional)
# ===========================================================================
langkah_functions() {
  judul "Cloud Functions (opsional, butuh paket Blaze)"
  if [ "$MODE_CHECK" = 1 ]; then
    info "Sumber: functions_sample/  (notifStatusPesanan + mintaPenawaran)"
    return 0
  fi
  if [ ${#FB[@]} -eq 0 ] || [ -z "$FIREBASE_PROJECT_ID" ]; then
    tolak "firebase-tools / project id belum siap"
    return 1
  fi
  info "npm install di functions_sample…"
  if ! ( cd "$AKAR/functions_sample" && npm install ); then
    tolak "npm install gagal"
    return 1
  fi
  info "deploy functions ke $FIREBASE_PROJECT_ID…"
  if ( cd "$AKAR" && jalankan_fb deploy --only functions --project="$FIREBASE_PROJECT_ID" ); then
    ok "functions terpasang"
    info "Setelah itu: Firestore → TTL policies → koleksi rateLimits, field kedaluwarsa"
  else
    tolak "deploy functions gagal — biasanya karena proyek masih Spark. Naikkan ke Blaze dulu."
  fi
}

# ===========================================================================
# Jalankan
# ===========================================================================
judul "Penyiapan Firebase Rara Travel"
[ "$MODE_CHECK" = 1 ] && kuning "Mode periksa: tidak ada yang diubah."
[ -f "$ENV_FILE" ] || info "Tip: cp .env.firebase.example .env.firebase lalu isi FIREBASE_PROJECT_ID"

if [ "$MODE_SHA" = 1 ]; then
  cetak_sha
  exit 0
fi

for n in 1 2 3 4 5 6 7; do
  ingin "$n" || continue
  "langkah_$n" || true
done

if [ "$MODE_FUNCTIONS" = 1 ]; then
  langkah_functions || true
fi

printf '\n'
if [ "$GAGAL" -eq 0 ]; then
  hijau "SELESAI — berkas proyek siap."
  printf 'Sisa di Console (langkah 7): Auth Phone + Google, nomor uji, SHA, App Check.\n'
  printf 'Panduan lengkap: PANDUAN_FIREBASE.md\n'
else
  merah "ADA YANG PERLU DIPERBAIKI — lihat tanda ✖ di atas."
  printf 'Panduan klik-per-klik: PANDUAN_FIREBASE.md\n'
  printf 'Ulangi per langkah: bash tools/setup_firebase.sh --step N\n'
fi
exit "$GAGAL"
