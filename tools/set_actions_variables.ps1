# set_actions_variables.ps1 — isi Repository variables Supabase untuk CI (Windows).
#
# Ini yang membuat APK hasil CI memakai backend Supabase + menyalakan tombol
# pembayaran ("Bayar Sekarang"). Kunci yang dipakai aman berada di APK
# (publishable/anon key) — JANGAN memakai service_role / secret key.
#
# Pemakaian:
#   .\tools\set_actions_variables.ps1                 # tanya interaktif
#   .\tools\set_actions_variables.ps1 -Check          # lihat isi sekarang
#   .\tools\set_actions_variables.ps1 -Build          # isi + jalankan CI
#   .\tools\set_actions_variables.ps1 `
#     -Url "https://xxxx.supabase.co" -Key "sb_publishable_xxx" `
#     -Catalog "supabase" -Booking "dual" -Payments "true"
[CmdletBinding()]
param(
  [string]$Url,
  [string]$Key,
  [string]$Catalog,
  [string]$Booking,
  [string]$Payments,
  [switch]$Check,
  [switch]$Build
)

$ErrorActionPreference = 'Stop'

function Ok($m)   { Write-Host "OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!    $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "X    $m" -ForegroundColor Red }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Fail "GitHub CLI (gh) tidak ditemukan - pasang dulu: https://cli.github.com"
  exit 1
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail "gh belum login. Jalankan: gh auth login"; exit 1 }

$repo = (gh repo view --json nameWithOwner -q .nameWithOwner)
Write-Host "Repositori: $repo`n"

if ($Check) {
  Write-Host "Variables saat ini:"
  try { gh api "repos/$repo/actions/variables" --jq '.variables[] | \"  \(.name) = \(.value)\"' }
  catch { Warn "Tidak bisa membaca daftar variables (token gh kurang izin 'Variables: read')." }
  Write-Host "`nYang dibutuhkan: SUPABASE_URL, SUPABASE_ANON_KEY"
  Write-Host "(opsional: CATALOG_SOURCE, BOOKING_WRITE, PAYMENTS_ENABLED)"
  exit 0
}

if (-not $Url) { $Url = Read-Host "SUPABASE_URL (https://<ref>.supabase.co)" }
if (-not $Key) {
  $secure = Read-Host "SUPABASE_ANON_KEY (anon 'eyJ...' atau 'sb_publishable_...')" -AsSecureString
  $Key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

$Url = $Url.Trim()
$Key = $Key.Trim()

if ($Url -notmatch '^https://[a-z0-9-]+\.supabase\.co$') {
  Fail "URL tidak seperti proyek Supabase (harus https://<ref>.supabase.co)."; exit 1
}
if ($Key -match 'service_role|sb_secret_') {
  Fail "Itu kunci RAHASIA (service_role/secret). Jangan ditaruh di aplikasi!"; exit 1
}
if ($Key -notmatch '^(sb_publishable_|eyJ)') {
  Fail "Kunci tidak dikenali. Pakai publishable/anon key, BUKAN service_role."; exit 1
}

if (-not $Catalog)  { $Catalog  = Read-Host "CATALOG_SOURCE [supabase] (kosong = biarkan bawaan 'local')" }
if (-not $Booking)  { $Booking  = Read-Host "BOOKING_WRITE [dual] (dual|supabase|firestore, kosong = biarkan)" }
if (-not $Payments) { $Payments = Read-Host "PAYMENTS_ENABLED [true] (kosong = false)" }

function Set-Var([string]$name, [string]$value) {
  gh api -X PATCH "repos/$repo/actions/variables/$name" -f name=$name -f value=$value *> $null
  if ($LASTEXITCODE -eq 0) { Ok "$name diperbarui"; return $true }
  gh api -X POST "repos/$repo/actions/variables" -f name=$name -f value=$value *> $null
  if ($LASTEXITCODE -eq 0) { Ok "$name dibuat"; return $true }
  Fail "Gagal menulis $name - token gh perlu izin 'Variables: write' (repo admin)."
  return $false
}

$gagal = $false
if (-not (Set-Var 'SUPABASE_URL' $Url)) { $gagal = $true }
if (-not (Set-Var 'SUPABASE_ANON_KEY' $Key)) { $gagal = $true }
if ($Catalog)  { if (-not (Set-Var 'CATALOG_SOURCE' $Catalog))  { $gagal = $true } }
if ($Booking)  { if (-not (Set-Var 'BOOKING_WRITE' $Booking))   { $gagal = $true } }
if ($Payments) { if (-not (Set-Var 'PAYMENTS_ENABLED' $Payments)) { $gagal = $true } }

if ($gagal) { Fail "Sebagian variables gagal ditulis."; exit 1 }

Write-Host "`nRingkasan yang akan dipakai APK berikutnya:"
Write-Host ("   katalog    : " + ($(if ($Catalog) { $Catalog } else { 'local (bawaan)' })))
Write-Host ("   pesanan    : " + ($(if ($Booking) { $Booking } else { 'dual (bawaan)' })))
Write-Host ("   pembayaran : " + ($(if ($Payments -eq 'true') { 'AKTIF (tombol Bayar Sekarang muncul)' } else { 'nonaktif' })))

if ($Build) {
  $branch = (git rev-parse --abbrev-ref HEAD)
  Write-Host "`nMenjalankan ulang CI untuk branch $branch..."
  gh workflow run build-apk.yml --ref $branch
  Ok "CI dijalankan. Pantau: gh run watch"
} else {
  Write-Host "`nLangkah berikutnya: .\tools\set_actions_variables.ps1 -Build"
}
