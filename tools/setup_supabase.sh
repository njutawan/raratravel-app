#!/usr/bin/env bash
# ============================================================================
# tools/setup_supabase.sh — menyiapkan proyek Supabase untuk Rara Travel.
#
#   cp .env.supabase.example .env.supabase   # lalu isi nilainya
#   bash tools/setup_supabase.sh             # jalankan semua langkah
#   bash tools/setup_supabase.sh --step 4    # hanya langkah tertentu (boleh >1)
#   bash tools/setup_supabase.sh --check     # periksa saja, tidak mengubah apa pun
#   bash tools/setup_supabase.sh --help
#
# Langkah:
#   1 periksa alat & isi .env.supabase      5 kirim secrets Edge Function
#   2 login Supabase CLI                    6 deploy 10 Edge Function
#   3 link ke proyek                        7 setelan database (pg_net + cron)
#   4 terapkan migrasi (db push)            8 verifikasi hasil
#
# Aman dijalankan berulang: langkah yang sudah beres akan dilewati.
# ============================================================================
set -uo pipefail

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SUPABASE_ENV_FILE:-$AKAR/.env.supabase}"
MODE_CHECK=0
LANGKAH_DIMINTA=()
NAMA_FUNGSI=(
  auth-user-sync register-device search-routes create-booking manage-booking
  notify-booking-status payment-intent payment-webhook storage-sign admin-import
)
GAGAL=0

# ---------------------------------------------------------------------------
# Utilitas tampilan
# ---------------------------------------------------------------------------
biru() { printf '\033[1;34m%s\033[0m\n' "$*"; }
hijau() { printf '\033[1;32m%s\033[0m\n' "$*"; }
kuning() { printf '\033[1;33m%s\033[0m\n' "$*"; }
merah() { printf '\033[1;31m%s\033[0m\n' "$*"; }
judul() { printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }
ok() { hijau "  ✔ $*"; }
tolak() { merah "  ✖ $*"; GAGAL=1; }
info() { printf '  · %s\n' "$*"; }

pakai_help() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argumen
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) pakai_help ;;
    --check) MODE_CHECK=1; shift ;;
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
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

: "${SUPABASE_PROJECT_REF:=}"
: "${SUPABASE_DB_PASSWORD:=}"
: "${SUPABASE_URL:=}"
: "${SUPABASE_ANON_KEY:=}"
: "${SUPABASE_SERVICE_ROLE_KEY:=}"
: "${FIREBASE_PROJECT_ID:=}"
: "${FIREBASE_SERVICE_ACCOUNT_FILE:=}"
: "${NOTIFY_WEBHOOK_SECRET:=}"
: "${MIDTRANS_SERVER_KEY:=}"
: "${MIDTRANS_IS_PRODUCTION:=false}"
: "${XENDIT_CALLBACK_TOKEN:=}"
: "${PAYMENT_HMAC_SECRET:=}"
: "${ALLOWED_ORIGINS:=*}"

# Perintah CLI: pakai `supabase` bila ada, kalau tidak lewat npx.
if command -v supabase >/dev/null 2>&1; then
  SB=(supabase)
  SUMBER_CLI="terpasang (supabase $(supabase --version 2>/dev/null | head -1))"
elif command -v npx >/dev/null 2>&1; then
  SB=(npx --yes supabase@latest)
  SUMBER_CLI="lewat npx (Node $(node --version 2>/dev/null))"
else
  SB=()
  SUMBER_CLI="tidak ada"
fi
jalankan_sb() { "${SB[@]}" "$@"; }

jalankan_curl() { command -v curl >/dev/null 2>&1; }

# Simpan/perbarui satu nilai di .env.supabase tanpa menyentuh baris lain.
simpan_env() {
  local kunci="$1" nilai="$2"
  [ -f "$ENV_FILE" ] || return 0
  ada_python || return 0
  if grep -qE "^${kunci}=" "$ENV_FILE"; then
    python3 - "$ENV_FILE" "$kunci" "$nilai" <<'PY' 2>/dev/null || return 0
import sys
jalur, kunci, nilai = sys.argv[1], sys.argv[2], sys.argv[3]
baris = open(jalur, encoding='utf-8').read().splitlines()
for i, b in enumerate(baris):
    if b.startswith(kunci + '='):
        baris[i] = f"{kunci}={nilai}"
open(jalur, 'w', encoding='utf-8').write("\n".join(baris) + "\n")
PY
  else
    printf '%s=%s\n' "$kunci" "$nilai" >>"$ENV_FILE"
  fi
}

# ===========================================================================
# 1. Pemeriksaan awal
# ===========================================================================
langkah_1() {
  judul "1. Memeriksa alat & setelan"
  [ -f "$ENV_FILE" ] \
    && ok "berkas setelan: $ENV_FILE" \
    || kuning "  ! $ENV_FILE belum ada — salin dari .env.supabase.example"

  [ ${#SB[@]} -gt 0 ] && ok "Supabase CLI $SUMBER_CLI" \
    || tolak "Supabase CLI tidak ada. Pasang: npm i -g supabase  (atau pakai Node/npx)"

  [ -n "$SUPABASE_PROJECT_REF" ] && ok "project ref: $SUPABASE_PROJECT_REF" \
    || tolak "SUPABASE_PROJECT_REF belum diisi"
  [ -n "$SUPABASE_DB_PASSWORD" ] && ok "password database: terisi" \
    || tolak "SUPABASE_DB_PASSWORD belum diisi"
  [ -n "$FIREBASE_PROJECT_ID" ] && ok "FIREBASE_PROJECT_ID: $FIREBASE_PROJECT_ID" \
    || tolak "FIREBASE_PROJECT_ID belum diisi"

  if [ -n "$FIREBASE_SERVICE_ACCOUNT_FILE" ]; then
    if [ -f "$FIREBASE_SERVICE_ACCOUNT_FILE" ]; then
      ok "service account: $FIREBASE_SERVICE_ACCOUNT_FILE"
    else
      tolak "berkas service account tidak ditemukan: $FIREBASE_SERVICE_ACCOUNT_FILE"
    fi
  else
    kuning "  ! FIREBASE_SERVICE_ACCOUNT_FILE kosong → push FCM (notifikasi) tidak aktif"
  fi

  [ -n "$SUPABASE_URL" ] || info "SUPABASE_URL kosong → akan diisi otomatis dari project ref"
  if [ -n "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    ok "kunci server (service_role/secret): terisi"
  else
    info "kunci server belum ada → akan dicoba diambil lewat CLI; bila gagal, Edge Function tetap jalan karena platform Supabase menyediakannya otomatis"
  fi
}

# ===========================================================================
# 2. Login
# ===========================================================================
langkah_2() {
  judul "2. Login Supabase CLI"
  [ ${#SB[@]} -gt 0 ] || { tolak "Supabase CLI tidak ada"; return 1; }
  if jalankan_sb projects list >/dev/null 2>&1; then
    ok "sudah login"
    return 0
  fi
  if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    ok "memakai SUPABASE_ACCESS_TOKEN dari lingkungan"
    return 0
  fi
  if [ "$MODE_CHECK" = 1 ]; then
    tolak "belum login (jalankan tanpa --check untuk login)"
    return 1
  fi
  info "membuka peramban untuk login Supabase…"
  if jalankan_sb login; then
    ok "login berhasil"
  else
    tolak "login gagal. Alternatif: set SUPABASE_ACCESS_TOKEN lalu ulangi"
  fi
}

# ===========================================================================
# 3. Link
# ===========================================================================
langkah_3() {
  judul "3. Menyambungkan ke proyek $SUPABASE_PROJECT_REF"
  [ ${#SB[@]} -gt 0 ] || { tolak "Supabase CLI tidak ada"; return 1; }
  if [ -f "$AKAR/supabase/.temp/project-ref" ] \
     && [ "$(cat "$AKAR/supabase/.temp/project-ref")" = "$SUPABASE_PROJECT_REF" ]; then
    ok "sudah tersambung ke proyek ini"
  else
    [ "$MODE_CHECK" = 1 ] && { tolak "belum tersambung (jalankan tanpa --check)"; return 1; }
    if ( cd "$AKAR" && SUPABASE_DB_PASSWORD="$SUPABASE_DB_PASSWORD" \
         jalankan_sb link --project-ref "$SUPABASE_PROJECT_REF" ); then
      ok "tersambung"
    else
      tolak "gagal menyambung — periksa project ref & password database"
      return 1
    fi
  fi
  [ -n "$SUPABASE_URL" ] || SUPABASE_URL="https://$SUPABASE_PROJECT_REF.supabase.co"
}

# Jumlah migrasi yang belum diterapkan di remote (0 bila sudah sinkron).
migrasi_tertunda() {
  local keluaran
  keluaran="$(cd "$AKAR" && jalankan_sb db push --dry-run --linked 2>&1)"
  printf '%s\n' "$keluaran" | grep -cE '[0-9]{14}_[a-z0-9_]+\.sql' || true
}

# ===========================================================================
# 4. Migrasi
# ===========================================================================
langkah_4() {
  judul "4. Menerapkan migrasi database"
  [ ${#SB[@]} -gt 0 ] || { tolak "Supabase CLI tidak ada"; return 1; }
  info "riwayat migrasi (lokal ↔ remote):"
  ( cd "$AKAR" && jalankan_sb migration list 2>&1 | sed 's/^/    /' )

  if [ "$MODE_CHECK" = 1 ]; then
    ( cd "$AKAR" && jalankan_sb db push --dry-run --linked 2>&1 | sed 's/^/    /' )
    return 0
  fi

  ( cd "$AKAR" && SUPABASE_DB_PASSWORD="$SUPABASE_DB_PASSWORD" jalankan_sb db push --linked )
  if [ $? -eq 0 ]; then
    ok "11 migrasi diterapkan"
    local sisa
    sisa="$(migrasi_tertunda)"
    [ "${sisa:-0}" -eq 0 ] && ok "tidak ada migrasi tertunda"
  else
    tolak "db push gagal — lihat pesan di atas"
    return 1
  fi

  # Bucket & kebijakan Storage bisa dilewati bila peran migrasi tidak berhak
  # (Supabase membatasi skema storage sejak 2025). Beri tahu bila itu terjadi.
  info "bila di atas ada PERINGATAN [0008], buat bucket lewat Dashboard → Storage:"
  info "  public-assets (public, 5 MB) · avatars (public, 2 MB) · payment-proofs (privat, 5 MB)"
}

# ===========================================================================
# 5. Secrets
# ===========================================================================
ada_python() { command -v python3 >/dev/null 2>&1; }

ambil_api_keys() {
  [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$SUPABASE_ANON_KEY" ] && return 0
  [ ${#SB[@]} -gt 0 ] || return 1
  ada_python || return 1
  local keluaran hasil baris
  keluaran="$(jalankan_sb projects api-keys --project-ref "$SUPABASE_PROJECT_REF" --output json 2>/dev/null)" || return 1
  [ -n "$keluaran" ] || return 1
  hasil="$(printf '%s' "$keluaran" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(data, dict):
    data = data.get("data") or [data]
for item in data:
    nama = str(item.get("name") or item.get("id") or "").lower()
    nilai = item.get("api_key") or item.get("key") or item.get("secret") or item.get("value") or ""
    if not nilai:
        continue
    # Nama kunci lama: anon / service_role. Model baru: publishable / secret.
    if "service" in nama or "secret" in nama:
        print("SERVICE=" + nilai)
    elif "anon" in nama or "publishable" in nama or "public" in nama:
        print("ANON=" + nilai)
' 2>/dev/null)"
  while IFS= read -r baris; do
    case "$baris" in
      SERVICE=*) [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] || SUPABASE_SERVICE_ROLE_KEY="${baris#SERVICE=}" ;;
      ANON=*) [ -n "$SUPABASE_ANON_KEY" ] || SUPABASE_ANON_KEY="${baris#ANON=}" ;;
    esac
  done <<<"$hasil"
  [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] || [ -n "$SUPABASE_ANON_KEY" ]
}

langkah_5() {
  judul "5. Mengirim secrets Edge Function"
  [ ${#SB[@]} -gt 0 ] || { tolak "Supabase CLI tidak ada"; return 1; }
  [ -n "$SUPABASE_URL" ] || SUPABASE_URL="https://$SUPABASE_PROJECT_REF.supabase.co"

  if [ -z "$NOTIFY_WEBHOOK_SECRET" ]; then
    if command -v openssl >/dev/null 2>&1; then
      NOTIFY_WEBHOOK_SECRET="$(openssl rand -hex 24)"
    else
      NOTIFY_WEBHOOK_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    simpan_env NOTIFY_WEBHOOK_SECRET "$NOTIFY_WEBHOOK_SECRET"
    ok "NOTIFY_WEBHOOK_SECRET dibuat & disimpan di $ENV_FILE"
  fi

  info "SUPABASE_URL & kunci server biasanya sudah otomatis di Edge Function — mengisinya di sini hanya untuk kejelasan."
  if [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && [ -n "$SUPABASE_ANON_KEY" ]; then
    ok "kunci API anon & service_role terisi dari $ENV_FILE"
  elif ambil_api_keys; then
    ok "kunci API diambil lewat CLI (anon: $([ -n "$SUPABASE_ANON_KEY" ] && echo ada || echo belum), service_role: $([ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && echo ada || echo belum))"
    [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] || kuning "  ! service_role key belum ada → salin dari Dashboard → Settings → API"
  else
    kuning "  ! kunci API belum lengkap → salin dari Dashboard → Settings → API"
  fi

  local args=()
  [ -n "$SUPABASE_URL" ] && args+=("SUPABASE_URL=$SUPABASE_URL")
  [ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && args+=("SUPABASE_SERVICE_ROLE_KEY=$SUPABASE_SERVICE_ROLE_KEY")
  [ -n "$FIREBASE_PROJECT_ID" ] && args+=("FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID")
  [ -n "$NOTIFY_WEBHOOK_SECRET" ] && args+=("NOTIFY_WEBHOOK_SECRET=$NOTIFY_WEBHOOK_SECRET")
  [ -n "$MIDTRANS_SERVER_KEY" ] && args+=("MIDTRANS_SERVER_KEY=$MIDTRANS_SERVER_KEY" "MIDTRANS_IS_PRODUCTION=$MIDTRANS_IS_PRODUCTION")
  [ -n "$XENDIT_CALLBACK_TOKEN" ] && args+=("XENDIT_CALLBACK_TOKEN=$XENDIT_CALLBACK_TOKEN")
  [ -n "$PAYMENT_HMAC_SECRET" ] && args+=("PAYMENT_HMAC_SECRET=$PAYMENT_HMAC_SECRET")
  [ -n "$ALLOWED_ORIGINS" ] && args+=("ALLOWED_ORIGINS=$ALLOWED_ORIGINS")

  if [ -n "$FIREBASE_SERVICE_ACCOUNT_FILE" ] && [ -f "$FIREBASE_SERVICE_ACCOUNT_FILE" ]; then
    # JSON dirapikan jadi satu baris supaya aman dilewatkan sebagai argumen.
    args+=("FIREBASE_SERVICE_ACCOUNT=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",", ":")))' "$FIREBASE_SERVICE_ACCOUNT_FILE")")
  fi

  if [ ${#args[@]} -eq 0 ]; then
    tolak "tidak ada secret yang bisa dikirim"
    return 1
  fi

  if [ "$MODE_CHECK" = 1 ]; then
    local a daftar=""
    for a in "${args[@]}"; do daftar+="${a%%=*}=*** "; done
    info "akan mengirim ${#args[@]} secret: $daftar"
    return 0
  fi

  if ( cd "$AKAR" && jalankan_sb secrets set "${args[@]}" >/dev/null 2>&1 ); then
    ok "${#args[@]} secret terkirim"
  else
    # Kirim satu per satu agar jelas mana yang bermasalah.
    local a nama
    for a in "${args[@]}"; do
      nama="${a%%=*}"
      if ( cd "$AKAR" && jalankan_sb secrets set "$a" >/dev/null 2>&1 ); then
        ok "$nama"
      else
        tolak "$nama gagal dikirim"
      fi
    done
    return 1
  fi
}

# ===========================================================================
# 6. Deploy fungsi
# ===========================================================================
langkah_6() {
  judul "6. Deploy ${#NAMA_FUNGSI[@]} Edge Function"
  [ ${#SB[@]} -gt 0 ] || { tolak "Supabase CLI tidak ada"; return 1; }
  if [ "$MODE_CHECK" = 1 ]; then
    info "fungsi: ${NAMA_FUNGSI[*]}"
    return 0
  fi
  local f
  for f in "${NAMA_FUNGSI[@]}"; do
    if ( cd "$AKAR" && jalankan_sb functions deploy "$f" >/dev/null 2>&1 ); then
      ok "$f"
    else
      tolak "$f — jalankan manual untuk melihat galat:"
      merah "      supabase functions deploy $f"
    fi
  done
  info "verify_jwt=false diambil dari supabase/config.toml (login memakai Firebase)."
}

# ===========================================================================
# 7. Setelan database (notifikasi otomatis)
# ===========================================================================
SQL_SETELAN() {
  cat <<SQL
create extension if not exists pg_net;
alter database postgres set app.settings.notify_endpoint = '${SUPABASE_URL}/functions/v1/notify-booking-status';
alter database postgres set app.settings.notify_secret = '${NOTIFY_WEBHOOK_SECRET}';
select pg_reload_conf();
SQL
}

langkah_7() {
  judul "7. Setelan database untuk notifikasi"
  local token="${SUPABASE_ACCESS_TOKEN:-}"
  if [ -z "$token" ] && [ -f "$HOME/.supabase/access-token" ]; then
    token="$(cat "$HOME/.supabase/access-token")"
  fi

  if [ "$MODE_CHECK" = 1 ]; then
    info "SQL yang akan dijalankan:"; SQL_SETELAN | sed 's/^/    /'
    return 0
  fi

  if [ -z "$token" ] || ! jalankan_curl; then
    kuning "  ! Tidak bisa menjalankan SQL otomatis (butuh SUPABASE_ACCESS_TOKEN + curl)."
    info "Tempel SQL ini sekali di Dashboard → SQL Editor:"
    SQL_SETELAN | sed 's/^/    /'
    info "Tanpa ini: notifikasi FCM tetap jalan, tapi dikirim saat fungsi drain dipanggil"
    info "(Scheduled Function tiap 5 menit, body {\"drain\": true})."
    return 0
  fi

  local jawab
  jawab="$(python3 -c 'import json,sys; print(json.dumps({"query": sys.stdin.read()}))' <<<"$(SQL_SETELAN)" \
    | curl -sS -X POST \
      "https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/database/query" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data-binary @-)"
  if printf '%s' "$jawab" | grep -qi '"error"'; then
    kuning "  ! SQL otomatis ditolak platform. Tempel manual di SQL Editor:"
    SQL_SETELAN | sed 's/^/    /'
  else
    ok "pg_net + app.settings.notify_endpoint/notify_secret terpasang"
  fi
}

# ===========================================================================
# 8. Verifikasi
# ===========================================================================
GET() { # GET <url> <header...>
  local url="$1"; shift
  curl -sS -o /tmp/rara_verifikasi.json -w '%{http_code}' "$@" "$url" 2>/dev/null
}

cek_http() { # cek_http <judul> <kode-diharapkan> <kode-nyata>
  if [ "$2" = "$3" ]; then ok "$1 → HTTP $3"
  elif [ "$3" = "000" ]; then tolak "$1 → tidak bisa dihubungi (jaringan/URL salah)"
  else
    tolak "$1 → HTTP $3 (diharapkan $2)"
    [ -s /tmp/rara_verifikasi.json ] && sed 's/^/      /' /tmp/rara_verifikasi.json | head -3
  fi
}

langkah_8() {
  judul "8. Verifikasi hasil"
  [ -n "$SUPABASE_URL" ] || SUPABASE_URL="https://$SUPABASE_PROJECT_REF.supabase.co"
  info "alamat proyek: $SUPABASE_URL"

  if [ ${#SB[@]} -gt 0 ]; then
    local terpasang
    terpasang="$(cd "$AKAR" && jalankan_sb functions list 2>/dev/null | grep -cE 'auth-user-sync|register-device|search-routes|create-booking|manage-booking|notify-booking-status|payment-intent|payment-webhook|storage-sign|admin-import' || true)"
    if [ "${terpasang:-0}" -ge 10 ]; then ok "10 Edge Function terdaftar di proyek"
    else kuning "  ! terdaftar $terpasang/10 fungsi — ulangi langkah 6"; fi

    local belum
    belum="$(migrasi_tertunda)"
    if [ "${belum:-0}" -eq 0 ]; then ok "semua migrasi sudah diterapkan di remote"
    else tolak "masih ada $belum migrasi tertunda — jalankan langkah 4"; fi
  fi

  if ! jalankan_curl; then
    kuning "  ! curl tidak ada → pemeriksaan HTTP dilewati"
    return 0
  fi
  [ -n "$SUPABASE_ANON_KEY" ] || kuning "  ! SUPABASE_ANON_KEY kosong → pemeriksaan REST dilewati"

  if [ -n "$SUPABASE_ANON_KEY" ]; then
    cek_http "RPC catalog_cities (katalog publik)" 200 \
      "$(GET "$SUPABASE_URL/rest/v1/rpc/catalog_cities" \
          -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
          -H 'Content-Type: application/json' -X POST -d '{}')"
    cek_http "RPC search_routes (katalog publik)" 200 \
      "$(GET "$SUPABASE_URL/rest/v1/rpc/search_routes" \
          -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
          -H 'Content-Type: application/json' -X POST -d '{"p_limit":3}')"
    cek_http "Edge Function tanpa token ditolak" 401 \
      "$(GET "$SUPABASE_URL/functions/v1/manage-booking" -X POST \
          -H 'Content-Type: application/json' -d '{"action":"history"}')"
  fi

  if [ -n "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    cek_http "bucket Storage public-assets ada" 200 \
      "$(GET "$SUPABASE_URL/storage/v1/bucket/public-assets" \
          -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")"
    cek_http "bucket Storage payment-proofs ada" 200 \
      "$(GET "$SUPABASE_URL/storage/v1/bucket/payment-proofs" \
          -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")"
  fi

  info "Pemeriksaan tambahan dengan token Firebase (dari aplikasi) — lihat MIGRASI_SUPABASE.md §7."
}

# ===========================================================================
# Jalankan
# ===========================================================================
judul "Penyiapan Supabase Rara Travel"
[ "$MODE_CHECK" = 1 ] && kuning "Mode periksa: tidak ada yang diubah."
[ -f "$ENV_FILE" ] || kuning "Berkas setelan belum ada: $ENV_FILE (lihat .env.supabase.example)"

for n in 1 2 3 4 5 6 7 8; do
  ingin "$n" || continue
  "langkah_$n" || true
done

printf '\n'
if [ "$GAGAL" -eq 0 ]; then
  hijau "SELESAI — semua langkah berhasil."
  printf 'Lanjut: build aplikasi dengan dart-define (MIGRASI_SUPABASE.md §5), mis.\n'
  printf '  flutter build apk --release \\\n'
  printf '    --dart-define=SUPABASE_URL=%s \\\n' "${SUPABASE_URL:-https://$SUPABASE_PROJECT_REF.supabase.co}"
  printf '    --dart-define=SUPABASE_ANON_KEY=<anon-key> \\\n'
  printf '    --dart-define=CATALOG_SOURCE=supabase --dart-define=BOOKING_WRITE=dual\n'
else
  merah "ADA YANG PERLU DIPERBAIKI — lihat tanda ✖ di atas."
fi
exit "$GAGAL"
