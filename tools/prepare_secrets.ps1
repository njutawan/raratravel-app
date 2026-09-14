<#
.SYNOPSIS
  Memandu mengisi secrets Edge Function di Dashboard Supabase (Windows).

.DESCRIPTION
  SUPABASE_URL dan kunci server sudah otomatis dari platform. Skrip ini
  hanya menyiapkan nilai yang perlu diisi manual:

    FIREBASE_PROJECT_ID        wajib (verifikasi login)
    FIREBASE_SERVICE_ACCOUNT   dianjurkan (push FCM)
    NOTIFY_WEBHOOK_SECRET      dianjurkan (webhook notifikasi)
    MIDTRANS_* / XENDIT_*      opsional (bayar online)

  Untuk setiap secret: nilai disalin ke papan klip, Anda tempel di
  Dashboard → Edge Functions → Manage secrets, lalu tekan Enter.

  Nilai yang dihasilkan (NOTIFY_WEBHOOK_SECRET) disimpan ke .env.supabase
  (sudah di .gitignore) supaya langkah SQL notifikasi nanti memakai nilai
  yang sama.

.CONTOH
  .\tools\prepare_secrets.ps1
  .\tools\prepare_secrets.ps1 -FirebaseProjectId "rara-travel-xxxx"
  .\tools\prepare_secrets.ps1 -ServiceAccountFile "$env:USERPROFILE\kunci\firebase-sa.json"
#>
[CmdletBinding()]
param(
  [string]$FirebaseProjectId = "",
  [string]$ServiceAccountFile = "",
  [string]$EnvFile = ""
)

$ErrorActionPreference = "Stop"
$akar = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $EnvFile) { $EnvFile = Join-Path $akar ".env.supabase" }
$contoh = Join-Path $akar ".env.supabase.example"

function Baca-Env([string]$jalur) {
  $hasil = @{}
  if (-not (Test-Path $jalur)) { return $hasil }
  foreach ($baris in Get-Content $jalur) {
    if ($baris -match '^\s*#' -or $baris -notmatch '=') { continue }
    $nama, $nilai = $baris -split '=', 2
    $hasil[$nama.Trim()] = $nilai.Trim().Trim('"')
  }
  return $hasil
}

function Simpan-Env([string]$jalur, [string]$kunci, [string]$nilai) {
  if (-not (Test-Path $jalur)) {
    if (Test-Path $contoh) { Copy-Item $contoh $jalur }
    else { New-Item -ItemType File -Path $jalur | Out-Null }
  }
  $baris = Get-Content $jalur
  $ketemu = $false
  for ($i = 0; $i -lt $baris.Count; $i++) {
    if ($baris[$i] -match ("^" + [regex]::Escape($kunci) + "=")) {
      $baris[$i] = "$kunci=$nilai"
      $ketemu = $true
      break
    }
  }
  if (-not $ketemu) { $baris += "$kunci=$nilai" }
  Set-Content -Path $jalur -Value $baris -Encoding utf8
}

function Buat-WebhookSecret {
  $bytes = New-Object byte[] 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Rapikan-ServiceAccount([string]$jalur) {
  $mentah = Get-Content -Raw $jalur
  $obj = $mentah | ConvertFrom-Json
  if (-not $obj.client_email -or -not $obj.private_key) {
    throw "Berkas service account tidak valid (butuh client_email + private_key): $jalur"
  }
  return ($obj | ConvertTo-Json -Compress -Depth 8)
}

if (-not (Test-Path $EnvFile) -and (Test-Path $contoh)) {
  Copy-Item $contoh $EnvFile
  Write-Host "Berkas $EnvFile dibuat dari contoh (tidak akan di-commit)." -ForegroundColor DarkGray
}

$envNilai = Baca-Env $EnvFile
if (-not $FirebaseProjectId) { $FirebaseProjectId = $envNilai["FIREBASE_PROJECT_ID"] }
if (-not $ServiceAccountFile) { $ServiceAccountFile = $envNilai["FIREBASE_SERVICE_ACCOUNT_FILE"] }

$notify = $envNilai["NOTIFY_WEBHOOK_SECRET"]
if (-not $notify) {
  $notify = Buat-WebhookSecret
  Simpan-Env $EnvFile "NOTIFY_WEBHOOK_SECRET" $notify
  Write-Host "NOTIFY_WEBHOOK_SECRET dibuat & disimpan di .env.supabase" -ForegroundColor Green
}

Write-Host ""
Write-Host "Secrets Edge Function — isi di Dashboard" -ForegroundColor Cyan
Write-Host "Buka: Dashboard → Edge Functions → Manage secrets (tingkat proyek)." -ForegroundColor DarkGray
Write-Host "SUPABASE_URL dan kunci server TIDAK perlu diisi — sudah otomatis." -ForegroundColor DarkGray
Write-Host ""

$langkah = @()

if ($FirebaseProjectId) {
  Simpan-Env $EnvFile "FIREBASE_PROJECT_ID" $FirebaseProjectId
  $langkah += [pscustomobject]@{ Nama = "FIREBASE_PROJECT_ID"; Nilai = $FirebaseProjectId; Catatan = "Project ID Firebase (Console → Project settings → General)" }
} else {
  Write-Host "FIREBASE_PROJECT_ID belum ada." -ForegroundColor Yellow
  Write-Host "  Ambil dari Firebase Console → Project settings → General → Project ID" -ForegroundColor DarkGray
  $masukan = Read-Host "  Tempel Project ID lalu Enter (kosong = lewati dulu)"
  if ($masukan) {
    $FirebaseProjectId = $masukan.Trim()
    Simpan-Env $EnvFile "FIREBASE_PROJECT_ID" $FirebaseProjectId
    $langkah += [pscustomobject]@{ Nama = "FIREBASE_PROJECT_ID"; Nilai = $FirebaseProjectId; Catatan = "verifikasi ID token login" }
  }
}

$saJson = $null
if ($ServiceAccountFile -and (Test-Path $ServiceAccountFile)) {
  $saJson = Rapikan-ServiceAccount $ServiceAccountFile
} else {
  Write-Host "FIREBASE_SERVICE_ACCOUNT (untuk push FCM) — opsional sekarang, wajib nanti agar notifikasi jalan." -ForegroundColor Yellow
  Write-Host "  Firebase Console → Project settings → Service accounts → Generate new private key" -ForegroundColor DarkGray
  Write-Host "  Simpan JSON di LUAR repo, lalu tempel path-nya di bawah." -ForegroundColor DarkGray
  $pathSa = Read-Host "  Path berkas JSON (kosong = lewati)"
  if ($pathSa -and (Test-Path $pathSa.Trim('"'))) {
    $ServiceAccountFile = $pathSa.Trim().Trim('"')
    Simpan-Env $EnvFile "FIREBASE_SERVICE_ACCOUNT_FILE" $ServiceAccountFile
    $saJson = Rapikan-ServiceAccount $ServiceAccountFile
  }
}
if ($saJson) {
  $langkah += [pscustomobject]@{ Nama = "FIREBASE_SERVICE_ACCOUNT"; Nilai = $saJson; Catatan = "JSON service account 1 baris — untuk FCM" }
}

$langkah += [pscustomobject]@{ Nama = "NOTIFY_WEBHOOK_SECRET"; Nilai = $notify; Catatan = "kunci webhook notifikasi (simpan, dipakai SQL langkah 7)" }

$n = 0
foreach ($s in $langkah) {
  $n++
  Set-Clipboard -Value $s.Nilai
  Write-Host ("[{0}/{1}] {2}" -f $n, $langkah.Count, $s.Nama) -ForegroundColor Yellow
  Write-Host ("        {0}" -f $s.Catatan) -ForegroundColor DarkGray
  Write-Host "        ✔ nilai sudah di papan klip — Name = $($s.Nama), Value = Ctrl+V, Save" -ForegroundColor Green
  Read-Host "        Tekan Enter setelah secret tersimpan" | Out-Null
}

Write-Host ""
Write-Host "Selesai mengisi secrets yang tersedia." -ForegroundColor Cyan
Write-Host "Lanjut deploy fungsi:  .\tools\paste_functions.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "SQL notifikasi (tempel di SQL Editor SETELAH 10 fungsi ACTIVE):" -ForegroundColor DarkGray
Write-Host "  ganti <project-ref> lalu jalankan:" -ForegroundColor DarkGray
Write-Host @"
create extension if not exists pg_net;
alter database postgres set app.settings.notify_endpoint =
  'https://<project-ref>.supabase.co/functions/v1/notify-booking-status';
alter database postgres set app.settings.notify_secret = '$notify';
select pg_reload_conf();
"@
