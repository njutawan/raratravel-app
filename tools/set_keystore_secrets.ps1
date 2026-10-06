# set_keystore_secrets.ps1 — simpan keystore rilis ke GitHub Secrets (Windows),
# agar CI bisa membangun AAB bertanda tangan rilis untuk Play Store.
# Padanan PowerShell dari tools/set_keystore_secrets.sh (PANDUAN_BUILD_APK.md §3).
#
# Pemakaian:
#   .\tools\set_keystore_secrets.ps1 -Keystore $env:USERPROFILE\upload-keystore.jks `
#        -Alias rara-travel -Build
#
# Kunci TIDAK masuk ke repo — hanya ke Secrets GitHub (hanya workflow yang bisa
# membacanya). Setelah unggah AAB pertama, jangan lupa mendaftarkan SHA-256
# "Play App Signing" ke Firebase (RILIS_PRODUKSI.md poin 3).
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Keystore,
  [string]$Alias = "rara-travel",
  [switch]$Build
)

$ErrorActionPreference = 'Stop'

function Ok($m)   { Write-Host "OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!    $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "X    $m" -ForegroundColor Red }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Fail "GitHub CLI (gh) tidak ditemukan - pasang dulu: https://cli.github.com"; exit 1
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail "gh belum login. Jalankan: gh auth login"; exit 1 }

$repo = (gh repo view --json nameWithOwner -q .nameWithOwner)
Write-Host "Repositori: $repo"

if (-not (Test-Path -LiteralPath $Keystore)) {
  Fail "Berkas keystore tidak ditemukan: $Keystore"; exit 1
}
$jks = (Resolve-Path -LiteralPath $Keystore).Path

$ksSecure = Read-Host "Password keystore" -AsSecureString
$ksPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ksSecure))
if ([string]::IsNullOrEmpty($ksPass)) { Fail "Password keystore tidak boleh kosong."; exit 1 }

$keySecure = Read-Host "Password kunci (Enter = sama dengan keystore)" -AsSecureString
$keyPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($keySecure))
if ([string]::IsNullOrEmpty($keyPass)) { $keyPass = $ksPass }

# Sidik jari kunci upload (untuk didaftarkan ke Firebase Console).
if (Get-Command keytool -ErrorAction SilentlyContinue) {
  Write-Host "Sidik jari kunci upload (daftarkan ke Firebase):"
  & keytool -list -v -keystore $jks -storepass $ksPass -alias $Alias 2>$null |
    Select-String -Pattern 'SHA1:|SHA256:' | ForEach-Object { "     " + $_.Line.Trim() }
} else {
  Warn "keytool tidak ada di PATH - jalankan tools\check_sha.ps1 untuk melihat SHA."
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($jks))

function Set-Secret([string]$nama, [string]$isi) {
  gh secret set $nama --body $isi *> $null
  if ($LASTEXITCODE -ne 0) { Fail "Gagal menulis secret $nama (butuh izin repo admin)."; exit 1 }
  Ok "$nama tersimpan"
}

Set-Secret 'KEYSTORE_BASE64' $b64
Set-Secret 'KEYSTORE_PASSWORD' $ksPass
Set-Secret 'KEY_ALIAS' $Alias
Set-Secret 'KEY_PASSWORD' $keyPass

Write-Host ""
Write-Host "Selesai. Langkah berikutnya:"
Write-Host "  1. .\tools\set_keystore_secrets.ps1 -Build     # bangun AAB bertanda tangan rilis"
Write-Host "  2. Daftarkan SHA di atas ke Firebase Console (wajib untuk login Google)."
Write-Host "  3. Unggah AAB ke Play Console (pengujian tertutup lebih dulu)."
Write-Host "  4. Setelah unggah pertama: daftarkan SHA-256 Play App Signing ke Firebase."
Write-Host ""
Write-Host "Backup keystore + password ke 2 tempat - kalau hilang, aplikasi di Play"
Write-Host "tidak bisa diperbarui lewat kunci upload yang sama."

if ($Build) {
  gh workflow run build-apk.yml -f aab=true
  if ($LASTEXITCODE -ne 0) { Fail "Gagal memicu workflow build-apk.yml"; exit 1 }
  Ok "CI dijalankan. Pantau: gh run watch"
}
