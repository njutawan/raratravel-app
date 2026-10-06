#!/usr/bin/env bash
# sms_region_policy.sh — SMS region policy + kuota OTP Firebase Auth.
#
# Ini pembatas BIAYA SMS yang nyata (temuan M-2 & RILIS_PRODUKSI.md poin 2):
# cooldown 60 detik di aplikasi hanya lapis tampilan, jadi yang melindungi
# tagihan SMS adalah kebijakan region di server + App Check.
#
#   --status              (bawaan) kebijakan sekarang + batas tetap Firebase Auth
#   --allow ID[,MY]       allowlist-only: HANYA region itu yang boleh terima OTP
#   --deny XX[,YY]        denylist: semua boleh kecuali region yang disebut
#   --semua-region        kembalikan ke "semua region diizinkan" (TIDAK disarankan)
#   --metrik              nama metrik Cloud Monitoring untuk pantau SMS masuk/blokir
#   --json                cetak balasan API mentah
#   --project <ID>        paksa project id (bawaan: .env.firebase / .firebaserc)
#
# Syarat: access token Google dengan hak Firebase Admin pada proyek
# (gcloud auth login, atau GOOGLE_APPLICATION_CREDENTIALS=<service account>).
#
# Contoh yang disarankan untuk Rara Travel (melayani 17 kota di Indonesia):
#   bash tools/sms_region_policy.sh --status
#   bash tools/sms_region_policy.sh --allow ID
#   bash tools/sms_region_policy.sh --status      # pastikan berubah
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="${IDENTITYTOOLKIT_API_BASE:-https://identitytoolkit.googleapis.com/admin/v2/projects}"
SA_ARGS=()
AKSI="status"
REGION=""
PROYEK="${FIREBASE_PROJECT_ID:-}"
JSON_MODE=0
YES=0
GAGAL=0

hijau()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul()  { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok()     { hijau "  ✔ $*"; }
info()   { printf '  · %s\n' "$*"; }
baris()  { printf '    %s\n' "$*"; }
ya_tidak() { case "$1" in True|true) printf 'aktif' ;; False|false) printf 'mati' ;; *) printf 'tidak terbaca' ;; esac; }
tolak()  { merah "  ✖ $*"; GAGAL=1; }
perhati(){ kuning "  ! $*"; }

pakai_help() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --status)        AKSI="status"; shift ;;
    --allow)         AKSI="allow"; REGION="${2:-}"; shift 2 ;;
    --allow=*)       AKSI="allow"; REGION="${1#*=}"; shift ;;
    --deny)          AKSI="deny"; REGION="${2:-}"; shift 2 ;;
    --deny=*)        AKSI="deny"; REGION="${1#*=}"; shift ;;
    --semua-region)  AKSI="semua"; shift ;;
    --metrik)        AKSI="metrik"; shift ;;
    --project)       PROYEK="${2:-}"; shift 2 ;;
    --project=*)     PROYEK="${1#*=}"; shift ;;
    --sa)            SA_ARGS+=(--sa "${2:-}"); shift 2 ;;
    --json)          JSON_MODE=1; shift ;;
    --yes|-y)        YES=1; shift ;;
    -h|--help)       pakai_help ;;
    *) merah "Argumen tidak dikenal: $1"; pakai_help ;;
  esac
done

# ---------------------------------------------------------------------------
# Project id: .env.firebase → .firebaserc → google-services.json
# ---------------------------------------------------------------------------
baca_firebaserc() {
  [ -f "$AKAR/.firebaserc" ] || return 1
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
pid = (d.get("projects") or {}).get("default") or ""
if pid and pid != "PROJECT_ID_KAMU":
    print(pid)
' "$AKAR/.firebaserc" 2>/dev/null
}
baca_google_services() {
  [ -f "$AKAR/android/app/google-services.json" ] || return 1
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print((d.get("project_info") or {}).get("project_id") or "")
' "$AKAR/android/app/google-services.json" 2>/dev/null
}
if [ -z "$PROYEK" ] && [ -f "$AKAR/.env.firebase" ]; then
  PROYEK="$(sed -n 's/^FIREBASE_PROJECT_ID=//p' "$AKAR/.env.firebase" | tail -1 | tr -d '"'"'"' \r')"
fi
[ -n "$PROYEK" ] || PROYEK="$(baca_firebaserc || true)"
[ -n "$PROYEK" ] || PROYEK="$(baca_google_services || true)"
[ -n "$PROYEK" ] || { merah "❌ Project id tidak diketahui. Pakai --project <ID> atau isi .env.firebase."; exit 1; }

# ---------------------------------------------------------------------------
# Token + pemanggil API
# ---------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { merah "❌ curl tidak ada."; exit 1; }
TOKEN="$(bash "$AKAR/tools/gcp_token.sh" --quiet \
  --scope "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/identitytoolkit https://www.googleapis.com/auth/firebase" \
  ${SA_ARGS[@]+"${SA_ARGS[@]}"})" || {
  merah "❌ Tidak bisa memperoleh access token Google."; exit 1; }

BADAN=""; KODE=""
api() { # api <METHOD> <path-sesudah-/admin/v2> [body]
  local metode="$1" path="$2" badan="${3:-}" tmp args
  tmp="$(mktemp)"
  args=(-sS -o "$tmp" -w '%{http_code}' -X "$metode" "$API$path"
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
    401) perhati "Token ditolak — ulangi (token kedaluwarsa) atau periksa service account." ;;
    403) perhati "403: kurang hak atau API belum aktif."
         info "Aktifkan: https://console.cloud.google.com/apis/library/identitytoolkit.googleapis.com"
         info "Peran yang dibutuhkan: Firebase Admin (atau Owner) pada proyek $PROYEK." ;;
    404) perhati "404: proyek '$PROYEK' tidak ditemukan / bukan proyek Firebase Auth." ;;
    000) perhati "Tidak ada jawaban dari API (jaringan/proxy?)." ;;
    *)   perhati "HTTP $KODE"; ringkas_galat ;;
  esac
}

# Baca satu field dari $BADAN (ekspresi python atas variabel d).
pyfield() {
  python3 -c "import json, sys
d = json.loads(sys.argv[1])
try:
    v = $2
except Exception:
    v = ''
if v is None:
    v = ''
print(v if not isinstance(v, (list, dict)) else json.dumps(v, ensure_ascii=False))" "$1" 2>/dev/null
}

# ===========================================================================
# Ringkasan kebijakan (dipakai --status dan setelah perubahan)
# ===========================================================================
cetak_kebijakan() {
  local src daftar
  src="$(pyfield "$BADAN" "(d.get('smsRegionConfig') or {})")"
  if [ -z "$src" ] || [ "$src" = "{}" ]; then
    perhati "smsRegionConfig BELUM disetel → SEMUA region boleh menerima OTP."
    info "Ini celah biaya: nomor luar negeri (tarif SMS mahal) bisa dipakai spam."
    info "Perbaiki: bash tools/sms_region_policy.sh --allow ID"
    return 1
  fi
  daftar="$(pyfield "$BADAN" "(d.get('smsRegionConfig') or {}).get('allowlistOnly', {}).get('allowedRegions')")"
  if [ -n "$daftar" ] && [ "$daftar" != "[]" ]; then
    ok "Allowlist-only: $daftar"
    if printf '%s' "$daftar" | grep -q '"ID"'; then
      ok "Indonesia (ID) termasuk → OTP nomor +62 tetap jalan."
    else
      tolak "ID tidak ada di allowlist → login OTP nomor Indonesia akan GAGAL."
    fi
    return 0
  fi
  daftar="$(pyfield "$BADAN" "(d.get('smsRegionConfig') or {}).get('allowByDefault', {}).get('disallowedRegions')")"
  if [ -n "$daftar" ]; then
    perhati "Denylist: semua region diizinkan KECUALI $daftar"
    info "Allowlist lebih aman untuk menekan biaya SMS (rekomendasi Google)."
    return 0
  fi
  perhati "smsRegionConfig ada tapi kosong → semua region diizinkan."
  return 1
}

cetak_provider() {
  local phone email anon jumlah log
  phone="$(pyfield "$BADAN" "(d.get('signIn') or {}).get('phoneNumber', {}).get('enabled')")"
  email="$(pyfield "$BADAN" "(d.get('signIn') or {}).get('email', {}).get('enabled')")"
  anon="$(pyfield "$BADAN" "(d.get('signIn') or {}).get('anonymous', {}).get('enabled')")"
  info "Provider: phone=$(ya_tidak "$phone") · email=$(ya_tidak "$email") · anonymous=$(ya_tidak "$anon")"
  jumlah="$(pyfield "$BADAN" "len((d.get('signIn') or {}).get('phoneNumber', {}).get('testPhoneNumbers') or {})")"
  [ "${jumlah:-0}" != "0" ] && ok "nomor uji (testing): $jumlah terdaftar" \
    || perhati "belum ada nomor uji — uji OTP gratis belum bisa (Console → Phone numbers for testing)"
  log="$(pyfield "$BADAN" "(d.get('monitoring') or {}).get('requestLogging', {}).get('enabled')")"
  if [ "$log" = "True" ]; then ok "Activity Logging aktif → jumlah kode per nomor bisa dilacak"
  else perhati "Activity Logging mati — nyalakan untuk melacak OTP per nomor (Console → Monitoring)"; fi
}

cetak_batas_tetap() {
  printf '\n'
  info "Batas tetap Firebase Auth (tidak bisa diubah dari API — sumber: firebase.google.com/docs/auth/limits):"
  baris "SMS verifikasi       : 3.000/hari (paket Blaze) · 900/menit"
  baris "Per alamat IP        : 50/menit · 500/jam"
  baris "Permintaan verifikasi: 150/IP/jam"
  baris "10 SMS pertama tiap hari gratis; selebihnya ditagih per SMS (lihat Pricing)"
  info "Yang bisa kamu kendalikan:"
  baris "1. SMS region policy (skrip ini) — blokir region yang tidak dilayani"
  baris "2. App Check enforcement Auth: bash tools/appcheck_admin.sh --enforce auth"
  baris "3. Nomor uji untuk development (tidak memakan kuota SMS berbayar)"
  baris "4. Budget alert: Console → Usage & billing → Budgets & alerts (wajib dipasang)"
}

cetak_metrik() {
  judul "Metrik untuk memantau SMS (Cloud Monitoring → Metrics explorer)"
  info "identitytoolkit.googleapis.com/usage/sent_sms_count      (SMS terkirim)"
  info "identitytoolkit.googleapis.com/usage/blocked_sms_count   (SMS diblokir kebijakan region)"
  info "firebaseauth.googleapis.com/phone_auth/phone_verification_count"
  info "Semuanya punya label region_code → filter 'region_code != ID' untuk melihat"
  info "percobaan dari luar negeri. Buat alert bila blocked_sms_count melonjak."
  info "Biaya: Console → Usage & billing → Reports → filter identitytoolkit.googleapis.com."
}

konfirmasi() {
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || return 0
  printf '  Lanjutkan? ketik "ya" lalu Enter: '
  local j; read -r j || return 1
  [ "$j" = "ya" ] || [ "$j" = "y" ]
}

validasi_region() { # validasi_region "ID,MY" → cetak JSON array
  local mentah="$1" daftar="" r
  mentah="$(printf '%s' "$mentah" | tr ' ' ',' | tr 'a-z' 'A-Z' | sed 's/,,*/,/g; s/^,//; s/,$//')"
  [ -n "$mentah" ] || { merah "❌ Daftar region kosong."; return 1; }
  IFS=',' read -r -a arr <<<"$mentah"
  for r in "${arr[@]}"; do
    if ! printf '%s' "$r" | grep -qE '^[A-Z]{2}$'; then
      merah "❌ Kode region tidak sah: '$r' (harus 2 huruf ISO-3166, mis. ID, MY, SG)."
      return 1
    fi
    [ -n "$daftar" ] && daftar="$daftar,"
    daftar="$daftar\"$r\""
  done
  printf '[%s]' "$daftar"
}

# ===========================================================================
# Aksi
# ===========================================================================
if [ "$AKSI" = "metrik" ]; then cetak_metrik; exit 0; fi

api GET "/$PROYEK/config"
if [ "$KODE" != 200 ]; then
  tolak "tidak bisa membaca konfigurasi Auth proyek $PROYEK (HTTP $KODE)"
  sarankan_galat
  exit 1
fi
[ "$JSON_MODE" = 1 ] && [ "$AKSI" = "status" ] && { printf '%s\n' "$BADAN"; exit 0; }

case "$AKSI" in
  status)
    judul "SMS region policy — proyek $PROYEK"
    cetak_kebijakan || true
    printf '\n'
    info "Provider & pemantauan:"
    cetak_provider
    cetak_batas_tetap
    ;;

  allow|deny|semua)
    if [ "$AKSI" = "allow" ]; then
      arr_json="$(validasi_region "$REGION")" || exit 1
      badan="{\"smsRegionConfig\":{\"allowlistOnly\":{\"allowedRegions\":$arr_json}}}"
      judul "Menyetel allowlist-only: $arr_json"
      perhati "Nomor di luar daftar ini TIDAK akan menerima OTP lagi."
      printf '%s' "$arr_json" | grep -q '"ID"' || perhati "ID tidak disertakan — login OTP Indonesia akan mati!"
    elif [ "$AKSI" = "deny" ]; then
      arr_json="$(validasi_region "$REGION")" || exit 1
      badan="{\"smsRegionConfig\":{\"allowByDefault\":{\"disallowedRegions\":$arr_json}}}"
      judul "Menyetel denylist: $arr_json"
      perhati "Semua region LAIN tetap boleh → perlindungan biaya lebih lemah."
    else
      badan='{"smsRegionConfig":{"allowByDefault":{"disallowedRegions":[]}}}'
      judul "Mengembalikan ke 'semua region diizinkan'"
      perhati "Ini membuka pintu spam OTP internasional. Yakin?"
    fi
    konfirmasi || { info "dibatalkan"; exit 0; }

    api PATCH "/$PROYEK/config?updateMask=smsRegionConfig" "$badan"
    if [ "$KODE" = 200 ]; then
      ok "kebijakan tersimpan"
      printf '\n'
      cetak_kebijakan || true
      printf '\n'
      info "Berlaku seketika. Uji dari HP: login OTP dengan nomor +62 → SMS masuk."
      info "Pantau: bash tools/sms_region_policy.sh --metrik"
    else
      tolak "gagal menyimpan (HTTP $KODE)"; ringkas_galat; sarankan_galat
      exit 1
    fi
    ;;
esac

exit "$GAGAL"
