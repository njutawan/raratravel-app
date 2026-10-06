#!/usr/bin/env bash
# gcp_token.sh — cetak access token Google (OAuth2) ke STDOUT.
#
# Dipakai skrip lain yang memanggil API Google/Firebase langsung:
#   tools/appcheck_admin.sh      (App Check: debug token + enforcement)
#   tools/sms_region_policy.sh   (SMS region policy Firebase Auth)
#   workflow deploy-firebase.yml (verifikasi rules yang terpasang di server)
#
# Sumber token, dicoba berurutan:
#   1. $GOOGLE_ACCESS_TOKEN              → dipakai apa adanya
#   2. `gcloud auth print-access-token`  → bila gcloud terpasang & sudah login
#   3. Service account JSON              → token ditempa sendiri (JWT RS256
#      ditandatangani openssl), dari salah satu:
#        --sa <berkas>  |  $GOOGLE_APPLICATION_CREDENTIALS
#        $FIREBASE_SERVICE_ACCOUNT_FILE  |  $FIREBASE_SERVICE_ACCOUNT (JSON sebaris)
#
# Pemakaian:
#   TOKEN=$(bash tools/gcp_token.sh)
#   TOKEN=$(bash tools/gcp_token.sh --sa ~/kunci/firebase-sa.json)
#   TOKEN=$(bash tools/gcp_token.sh --scope https://www.googleapis.com/auth/cloud-platform)
#
# Semua pesan penjelasan dicetak ke STDERR — stdout murni token, jadi aman
# dipakai di dalam $(...).
#
# Catatan: `FIREBASE_TOKEN` (hasil `firebase login:ci`) TIDAK dipakai di sini —
# token itu untuk firebase-tools, bukan untuk API Google.
set -uo pipefail

SA_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-}"
SCOPE="https://www.googleapis.com/auth/cloud-platform"
QUIET=0

say()   { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }
gagal() { say "❌ $*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sa)      SA_FILE="${2:-}"; shift 2 ;;
    --sa=*)    SA_FILE="${1#*=}"; shift ;;
    --scope)   SCOPE="${2:-}"; shift 2 ;;
    --scope=*) SCOPE="${1#*=}"; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) gagal "Argumen tidak dikenal: $1 (coba --help)" ;;
  esac
done

# --- 1. token yang sudah disediakan -----------------------------------------
if [ -n "${GOOGLE_ACCESS_TOKEN:-}" ]; then
  printf '%s' "$GOOGLE_ACCESS_TOKEN"
  exit 0
fi

# --- 2. gcloud (Application Default Credentials) ----------------------------
if command -v gcloud >/dev/null 2>&1; then
  tok="$(gcloud auth print-access-token 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    printf '%s' "$tok"
    exit 0
  fi
  say "· gcloud ada tapi belum login/aktif — lanjut ke service account."
fi

# --- 3. service account JSON -------------------------------------------------
SA_JSON=""
if [ -n "$SA_FILE" ] && [ -f "$SA_FILE" ]; then
  SA_JSON="$(cat "$SA_FILE")"
elif [ -n "${FIREBASE_SERVICE_ACCOUNT_FILE:-}" ] && [ -f "${FIREBASE_SERVICE_ACCOUNT_FILE}" ]; then
  SA_JSON="$(cat "${FIREBASE_SERVICE_ACCOUNT_FILE}")"
elif [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  SA_JSON="$FIREBASE_SERVICE_ACCOUNT"
fi

[ -n "$SA_JSON" ] || gagal "Tidak ada sumber token. Pilih salah satu:
     • gcloud auth login            (lalu ulangi perintah ini)
     • export GOOGLE_APPLICATION_CREDENTIALS=/path/firebase-sa.json
     • bash tools/gcp_token.sh --sa /path/firebase-sa.json
   Berkas service account: Firebase Console → Project settings → Service
   accounts → Generate new private key. Simpan DI LUAR repositori."

command -v python3 >/dev/null 2>&1 || gagal "python3 tidak ada (dipakai menempa token)."
command -v openssl >/dev/null 2>&1 || gagal "openssl tidak ada (dipakai menandatangani JWT)."

SA_TMP="$(mktemp "${TMPDIR:-/tmp}/rara-sa.XXXXXX")" || gagal "tidak bisa membuat berkas sementara."
chmod 600 "$SA_TMP"
printf '%s' "$SA_JSON" >"$SA_TMP"
trap 'rm -f "$SA_TMP"' EXIT

if SCOPE="$SCOPE" python3 - "$SA_TMP" <<'PY'
import base64, json, os, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        sa = json.load(f)
except Exception as e:
    sys.stderr.write(f"❌ JSON service account tidak terbaca: {e}\n")
    raise SystemExit(1)

client_email = sa.get("client_email") or ""
private_key = sa.get("private_key") or ""
token_uri = sa.get("token_uri") or "https://oauth2.googleapis.com/token"
if not client_email or not private_key:
    sys.stderr.write("❌ Service account tidak punya client_email/private_key.\n")
    raise SystemExit(1)

now = int(time.time())
header = {"alg": "RS256", "typ": "JWT"}
claims = {
    "iss": client_email,
    "scope": os.environ.get("SCOPE") or "https://www.googleapis.com/auth/cloud-platform",
    "aud": token_uri,
    "iat": now,
    "exp": now + 3600,
}
signing_input = (
    b64url(json.dumps(header, separators=(",", ":")).encode())
    + "."
    + b64url(json.dumps(claims, separators=(",", ":")).encode())
)

# Kunci privat ditulis ke berkas sementara 0600, dihapus apa pun hasilnya.
pem = tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False)
try:
    pem.write(private_key if private_key.endswith("\n") else private_key + "\n")
    pem.close()
    os.chmod(pem.name, 0o600)
    signed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", pem.name, "-binary"],
        input=signing_input.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
finally:
    try:
        os.unlink(pem.name)
    except OSError:
        pass

if signed.returncode != 0:
    sys.stderr.write(
        "❌ openssl gagal menandatangani: "
        + signed.stderr.decode(errors="replace").strip() + "\n"
    )
    raise SystemExit(1)

assertion = signing_input + "." + b64url(signed.stdout)
body = urllib.parse.urlencode({
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion": assertion,
}).encode()

try:
    with urllib.request.urlopen(
        urllib.request.Request(
            token_uri, data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        ),
        timeout=30,
    ) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:400]
    sys.stderr.write(f"❌ Ditolak {token_uri} (HTTP {e.code}): {detail}\n")
    raise SystemExit(1)
except Exception as e:
    sys.stderr.write(f"❌ Tidak bisa menghubungi {token_uri}: {e}\n")
    raise SystemExit(1)

token = data.get("access_token") or ""
if not token:
    sys.stderr.write("❌ Balasan tidak memuat access_token.\n")
    raise SystemExit(1)
sys.stdout.write(token)
PY
then
  say "· token service account siap (berlaku ±1 jam)."
else
  exit 1
fi
