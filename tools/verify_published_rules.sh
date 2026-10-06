#!/usr/bin/env bash
# verify_published_rules.sh — buktikan firestore.rules SUDAH berlaku di server.
#
# Ini jawaban untuk temuan keamanan H-1: perbaikan di repo tidak ada artinya
# sebelum rules dipublikasikan. Skrip ini memeriksa proyek Firebase NYATA,
# bukan emulator:
#
#   A. Isi rules yang terpasang di server == isi firestore.rules di repo
#      (Firebase Rules API — butuh access token Google)
#   B. Tulis tanpa login ke /bookings (userId orang lain) → DITOLAK   ← inti H-1
#   C. Baca /bookings tanpa login                        → DITOLAK
#   D. Baca /users/{uid} tanpa login                     → DITOLAK
#   E. Baca/tulis /rateLimits tanpa login                → DITOLAK
#
# Pemakaian:
#   bash tools/verify_published_rules.sh                     # semua pemeriksaan
#   bash tools/verify_published_rules.sh --skip-content      # hanya uji akses (B–E)
#   bash tools/verify_published_rules.sh --project rara-xxx --api-key AIza…
#   GOOGLE_APPLICATION_CREDENTIALS=~/kunci/firebase-sa.json \
#     bash tools/verify_published_rules.sh                   # + pemeriksaan A
#
# Uji B–E tidak menulis apa pun ke database bila rules benar (semua ditolak).
# Bila rules ternyata TERBUKA, dokumen uji langsung dihapus kembali.
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GS_JSON="$AKAR/android/app/google-services.json"
RULES_FILE="$AKAR/firestore.rules"
PROYEK=""
API_KEY=""
SA_ARGS=()
SKIP_CONTENT=0
GAGAL=0
HASIL=()
BUKTI_AKSES=0   # berapa uji akses yang benar-benar memberi kesimpulan

hijau()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul()  { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok()     { hijau "  ✔ $*"; HASIL+=("✔ $*"); }
info()   { printf '  · %s\n' "$*"; }
tolak()  { merah "  ✖ $*"; GAGAL=1; HASIL+=("✖ $*"); }
perhati(){ kuning "  ! $*"; HASIL+=("! $*"); }
lewati() { kuning "  ↷ $*"; }

pakai_help() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROYEK="${2:-}"; shift 2 ;;
    --project=*) PROYEK="${1#*=}"; shift ;;
    --api-key)   API_KEY="${2:-}"; shift 2 ;;
    --api-key=*) API_KEY="${1#*=}"; shift ;;
    --rules)     RULES_FILE="${2:-}"; shift 2 ;;
    --rules=*)   RULES_FILE="${1#*=}"; shift ;;
    --sa)        SA_ARGS+=(--sa "${2:-}"); shift 2 ;;
    --skip-content) SKIP_CONTENT=1; shift ;;
    -h|--help)   pakai_help; exit 0 ;;
    *) merah "Argumen tidak dikenal: $1"; pakai_help; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { merah "❌ curl tidak ada."; exit 1; }
command -v python3 >/dev/null 2>&1 || { merah "❌ python3 tidak ada."; exit 1; }

# --- identitas proyek + api key ---------------------------------------------
if [ -f "$GS_JSON" ]; then
  baca="$(python3 - "$GS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
pid = (d.get("project_info") or {}).get("project_id") or ""
klien = (d.get("client") or [{}])[0]
key = ((klien.get("api_key") or [{}])[0]).get("current_key") or ""
print(pid + "\t" + key)
PY
)"
  PROYEK="${PROYEK:-$(printf '%s' "$baca" | cut -f1)}"
  API_KEY="${API_KEY:-$(printf '%s' "$baca" | cut -f2)}"
fi
if [ -z "$PROYEK" ] && [ -f "$AKAR/.firebaserc" ]; then
  PROYEK="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print((d.get("projects") or {}).get("default") or "")' "$AKAR/.firebaserc" 2>/dev/null)"
fi
[ -n "$PROYEK" ] || { merah "❌ Project id tidak diketahui — pakai --project <ID>."; exit 1; }
[ -n "$API_KEY" ] || { merah "❌ API key tidak diketahui — pakai --api-key <KEY>."; exit 1; }

FS="${FIRESTORE_API_BASE:-https://firestore.googleapis.com/v1/projects/$PROYEK/databases/(default)/documents}"
RULES_API="${RULES_API_BASE:-https://firebaserules.googleapis.com/v1}"

# ===========================================================================
# A. Isi rules di server == repo
# ===========================================================================
cek_isi_rules() {
  [ "$SKIP_CONTENT" = 1 ] && { lewati "perbandingan isi rules dilewati (--skip-content)"; return 0; }
  local token release ruleset isi server lokal
  token="$(bash "$AKAR/tools/gcp_token.sh" --quiet \
    --scope "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/firebase" \
    ${SA_ARGS[@]+"${SA_ARGS[@]}"} 2>/dev/null)" || token=""
  if [ -z "$token" ]; then
    lewati "tidak ada access token Google → isi rules di server tidak dibandingkan."
    info "  (opsional: GOOGLE_APPLICATION_CREDENTIALS=<service account> atau gcloud auth login)"
    return 0
  fi

  local tmp; tmp="$(mktemp)"
  kode="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    "$RULES_API/projects/$PROYEK/releases/cloud.firestore/%28default%29" \
    2>/dev/null)" || kode="000"
  release="$(cat "$tmp")"; rm -f "$tmp"
  if [ "$kode" != 200 ]; then
    perhati "release rules tidak terbaca (HTTP $kode) — pemeriksaan A dilewati."
    printf '%s\n' "$release" | head -c 200 | sed 's/^/      /'; printf '\n'
    return 0
  fi
  ruleset="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
rel = d.get("release") or d
print(rel.get("rulesetName") or "")' "$release" 2>/dev/null)"
  [ -n "$ruleset" ] || { perhati "rulesetName kosong di release."; return 0; }

  tmp="$(mktemp)"
  kode="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" \
    "$RULES_API/$ruleset" 2>/dev/null)" || kode="000"
  isi="$(cat "$tmp")"; rm -f "$tmp"
  if [ "$kode" != 200 ]; then
    perhati "ruleset $ruleset tidak terbaca (HTTP $kode)."
    return 0
  fi
  server="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
files = ((d.get("source") or {}).get("files")) or []
for f in files:
    if f.get("name", "").endswith("firestore.rules") or len(files) == 1:
        print(f.get("content") or "")
        break
' "$isi" 2>/dev/null)"

  if [ -z "$server" ]; then
    perhati "isi rules di server kosong/tidak terbaca — bandingkan manual di Console."
    return 0
  fi

  normal() { sed -e 's/[[:space:]]*$//' -e 's/\r$//' "$1" | grep -vE '^[[:space:]]*$' | grep -vE '^[[:space:]]*//' ; }
  lokal="$(normal "$RULES_FILE")"
  server_n="$(printf '%s\n' "$server" | sed -e 's/[[:space:]]*$//' -e 's/\r$//' | grep -vE '^[[:space:]]*$' | grep -vE '^[[:space:]]*//')"
  info "ruleset aktif: $ruleset"
  if [ "$lokal" = "$server_n" ]; then
    ok "isi rules di server SAMA dengan $(basename "$RULES_FILE") (H-1 sudah berlaku)."
  else
    tolak "isi rules di server BERBEDA dari $(basename "$RULES_FILE") → PUBLISH belum jalan!"
    info "  Deploy: bash tools/setup_firebase.sh --step 6"
    info "  atau workflow CI: gh workflow run deploy-firebase.yml"
    printf '%s\n' "$server_n" > /tmp/rules-server.txt
    printf '%s\n' "$lokal" > /tmp/rules-lokal.txt
    info "  Selisih (server vs repo):"
    diff -u /tmp/rules-server.txt /tmp/rules-lokal.txt | head -40 | sed 's/^/      /' || true
  fi
}

# ===========================================================================
# B–E. Uji akses tanpa login (aturan harus menolak)
# ===========================================================================
KODE=""; BADAN=""
fs_api() { # fs_api <METHOD> <path-sesudah-/documents> [json]
  local metode="$1" path="$2" badan="${3:-}" tmp args
  tmp="$(mktemp)"
  args=(-sS -o "$tmp" -w '%{http_code}' -X "$metode" "$FS$path"
        -H "Content-Type: application/json" -H "X-Goog-Api-Key: $API_KEY")
  [ -n "$badan" ] && args+=(--data-binary "$badan")
  KODE="$(curl "${args[@]}" 2>/dev/null)" || KODE="000"
  BADAN="$(cat "$tmp")"; rm -f "$tmp"
}

status_galat() {
  python3 -c '
import json, sys
try:
    e = (json.loads(sys.argv[1]) or {}).get("error") or {}
    print(str(e.get("status") or "") + "|" + str(e.get("message") or "")[:160])
except Exception:
    print("|")' "$BADAN" 2>/dev/null
}

harus_ditolak() { # harus_ditolak <label> <method> <path> [json]
  local label="$1" metode="$2" path="$3" badan="${4:-}" st kode_galat pesan
  fs_api "$metode" "$path" "$badan"
  st="$(status_galat)"
  kode_galat="${st%%|*}"; pesan="${st#*|}"
  case "$KODE:$kode_galat" in
    000:*)
      perhati "$label → tidak bisa dihubungi (jaringan/proxy?)"
      ;;
    *:PERMISSION_DENIED|*:UNAUTHENTICATED|401:*|403:*)
      ok "$label → DITOLAK (HTTP $KODE ${kode_galat:-denied})"
      BUKTI_AKSES=$((BUKTI_AKSES + 1))
      ;;
    *:INVALID_ARGUMENT)
      if printf '%s' "$pesan" | grep -qiE 'api[_ ]?key'; then
        perhati "$label → API key ditolak ($pesan). Uji aturan tidak bisa dijalankan."
        info "  Firebase Console → Project settings → API keys: pastikan key Android tidak dibatasi"
        info "  untuk layanan Cloud Firestore, atau pakai --api-key <key lain>."
      else
        perhati "$label → INVALID_ARGUMENT: $pesan"
      fi
      ;;
    200:*)
      BUKTI_AKSES=$((BUKTI_AKSES + 1))
      tolak "$label → DITERIMA (HTTP 200)! Rules di server masih TERBUKA."
      info "  Publish rules sekarang: gh workflow run deploy-firebase.yml"
      info "  atau bash tools/setup_firebase.sh --step 6"
      # Bersihkan dokumen uji bila sempat tercipta.
      if [ "$metode" = POST ]; then
        local id; id="$(python3 -c '
import json,sys
try:
    print((json.loads(sys.argv[1]).get("name") or "").split("/")[-1])
except Exception:
    print("")' "$BADAN" 2>/dev/null)"
        if [ -n "$id" ]; then
          fs_api DELETE "/bookings/$id"
          if [ "$KODE" = 200 ]; then info "  dokumen uji $id sudah dihapus kembali."
          else perhati "  dokumen uji $id TIDAK bisa dihapus otomatis — hapus manual di Console."; fi
        fi
      fi
      ;;
    *)
      perhati "$label → HTTP $KODE ${kode_galat:-} ${pesan}"
      ;;
  esac
}

# ===========================================================================
# Jalankan
# ===========================================================================
judul "Verifikasi rules yang ter-publish — proyek $PROYEK"
info "database: (default) · api key: ${API_KEY:0:10}…${API_KEY: -4}"

printf '\n'
info "A. Kesamaan isi rules (server vs repo)"
cek_isi_rules

printf '\n'
info "B–E. Akses tanpa login harus DITOLAK semua"
acak="$RANDOM$RANDOM"
harus_ditolak "create /bookings/UJI-H1-$acak (userId orang lain)" POST \
  "/bookings?documentId=UJI-H1-$acak" \
  '{"fields":{"userId":{"stringValue":"uid-korban"},"kode":{"stringValue":"UJI-H1"},"asal":{"stringValue":"Surabaya"}}}'
harus_ditolak "list /bookings" GET "/bookings?pageSize=1"
harus_ditolak "get /users/uji-$acak" GET "/users/uji-$acak"
harus_ditolak "get /rateLimits/uji-$acak" GET "/rateLimits/uji-$acak"

if [ "$BUKTI_AKSES" -eq 0 ]; then
  tolak "tidak ada satu pun uji akses yang memberi kesimpulan (API key/jaringan)."
  info "  Perbaiki api key atau jalankan dari jaringan yang bisa mencapai Firestore,"
  info "  lalu ulangi. Tanpa bukti ini, status H-1 di server TIDAK diketahui."
fi

judul "Ringkasan"
for h in ${HASIL[@]+"${HASIL[@]}"}; do printf '  %s\n' "$h"; done
printf '\n'
if [ "$GAGAL" = 0 ]; then
  hijau "LOLOS — firestore.rules di repo sudah berlaku di proyek $PROYEK."
  info "Catatan: uji di atas hanya sisi 'tanpa login'. Uji lengkap 13 skenario"
  info "(termasuk titip pesanan antar-akun) ada di tools/firestore/rules_test.mjs"
  info "→ bash tools/check_firestore_rules.sh (emulator) atau job CI 'Aturan Firestore'."
else
  merah "BELUM LOLOS — lihat tanda ✖ di atas. Temuan H-1 belum tertutup di server."
fi
exit "$GAGAL"
