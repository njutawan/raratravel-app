<#
.SYNOPSIS
  Memeriksa kesiapan proyek Supabase Rara Travel (Windows, tanpa CLI).

.DESCRIPTION
  Menjalankan pemeriksaan berurutan dan mencetak laporan ✔/✖ + langkah
  perbaikannya:

    1. REST API hidup & kunci publik sah
    2. Migrasi database (tabel inti + RPC katalog + jumlah kota)
    3. Bucket Storage (bila -ServiceKey diisi)
    4. 10 Edge Function sudah ter-deploy

.CONTOH
  # hanya dengan kunci publik (aman)
  .\tools\verify_supabase.ps1 -AnonKey "sb_publishable_.../eyJ..."

  # lengkap dengan kunci server (JANGAN dibagikan; hanya untuk cek Storage)
  .\tools\verify_supabase.ps1 -AnonKey "sb_publishable_..." -ServiceKey "eyJ..."

  # membaca dari .env.supabase / berkas .env mana pun
  .\tools\verify_supabase.ps1 -EnvFile .env.supabase

.NOTES
  Kunci publik bukan rahasia (aman ditaruh di aplikasi); kunci server rahasia.
#>
[CmdletBinding()]
param(
  [string]$Url = "",
  [string]$AnonKey = "",
  [string]$ServiceKey = "",
  [string]$EnvFile = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # mempercepat Invoke-* / curl.exe
$skripIni = $PSCommandPath
$akar = Split-Path -Parent (Split-Path -Parent $skripIni)

# ---------------------------------------------------------------------------
# Baca berkas setelan (.env) bila diminta
# ---------------------------------------------------------------------------
if (-not $EnvFile) {
  foreach ($kandidat in @(".env.supabase", ".env")) {
    $jalur = Join-Path $akar $kandidat
    if (Test-Path $jalur) { $EnvFile = $jalur; break }
  }
}
if ($EnvFile -and (Test-Path $EnvFile)) {
  Write-Host "Membaca setelan dari $EnvFile" -ForegroundColor DarkGray
  foreach ($baris in Get-Content $EnvFile) {
    if ($baris -match '^\s*#' -or $baris -notmatch '=') { continue }
    $nama, $nilai = $baris -split '=', 2
    $nama = $nama.Trim(); $nilai = $nilai.Trim().Trim('"')
    if (-not $nilai) { continue }
    switch ($nama) {
      "SUPABASE_URL"                { if (-not $Url)        { $Url = $nilai } }
      "SUPABASE_PROJECT_REF"        { if (-not $Url)        { $Url = "https://$nilai.supabase.co" } }
      "SUPABASE_ANON_KEY"           { if (-not $AnonKey)    { $AnonKey = $nilai } }
      "SUPABASE_PUBLISHABLE_KEY"    { if (-not $AnonKey)    { $AnonKey = $nilai } }
      "SUPABASE_SERVICE_ROLE_KEY"   { if (-not $ServiceKey) { $ServiceKey = $nilai } }
      "SUPABASE_SECRET_KEY"         { if (-not $ServiceKey) { $ServiceKey = $nilai } }
    }
  }
}

if (-not $Url)     { Write-Host "URL proyek belum ada. Pakai -Url https://<ref>.supabase.co atau -EnvFile." -ForegroundColor Red; exit 2 }
if (-not $AnonKey) { Write-Host "Kunci publik belum ada. Pakai -AnonKey atau -EnvFile." -ForegroundColor Red; exit 2 }
$Url = $Url.TrimEnd("/")

# Simpan sebagai variabel lingkungan sementara supaya perintah curl.exe rapi.
$env:SB_ANON = $AnonKey
$env:SB_SERVICE = $ServiceKey

$hasil = @()
function Catat([string]$nama, [bool]$ok, [string]$pesan, [string]$saran = "") {
  $script:hasil += [pscustomobject]@{ Nama = $nama; Ok = $ok; Pesan = $pesan; Saran = $saran }
  if ($ok) {
    Write-Host ("  [OK]   {0} — {1}" -f $nama, $pesan) -ForegroundColor Green
  } else {
    Write-Host ("  [GAGAL]{0} — {1}" -f $nama, $pesan) -ForegroundColor Red
    if ($saran) { Write-Host ("         → {0}" -f $saran) -ForegroundColor Yellow }
  }
}

# curl.exe mengembalikan kode HTTP di baris terakhir; -s menyembunyikan baris lain.
function Panggil([string]$metode, [string]$jalur, [string]$kunci, [string]$badan = "") {
  $argumen = @("-s", "-S", "-X", $metode, "$Url$jalur", "-o", "$env:TEMP\sb_jawab.json", "-w", "%{http_code}")
  if ($kunci -eq "service") {
    $argumen += @("-H", "apikey: $env:SB_SERVICE", "-H", "Authorization: Bearer $env:SB_SERVICE")
  } else {
    $argumen += @("-H", "apikey: $env:SB_ANON", "-H", "Authorization: Bearer $env:SB_ANON")
  }
  if ($badan) { $argumen += @("-H", "Content-Type: application/json", "-d", $badan) }
  $kode = (& curl.exe @argumen) 2>$null
  $isi = ""
  if (Test-Path "$env:TEMP\sb_jawab.json") { $isi = (Get-Content -Raw "$env:TEMP\sb_jawab.json") }
  return [pscustomobject]@{ Kode = "$kode".Trim(); Isi = $isi }
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  Write-Host "curl.exe tidak ditemukan (Windows 10+ seharusnya ada di C:\Windows\System32)." -ForegroundColor Red
  exit 2
}

Write-Host ""
Write-Host "Pemeriksaan proyek Supabase" -ForegroundColor Cyan
Write-Host "  $Url" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# 1. REST API + kunci publik
# ---------------------------------------------------------------------------
Write-Host "1. REST API & kunci publik" -ForegroundColor Cyan
$r = Panggil "GET" "/rest/v1/cities?select=name&limit=1" "anon"
if ($r.Kode -eq "200") {
  Catat "REST API" $true "menjawab 200 (tabel cities ada)"
} elseif ($r.Kode -eq "404" -or $r.Isi -match "PGRST205") {
  Catat "REST API" $true "menjawab (kunci sah) tetapi tabel belum ada"
  Catat "Migrasi database" $false "tabel public.cities belum ada" "jalankan 11 berkas supabase\migrations\*.sql di SQL Editor (urut nama)"
} elseif ($r.Isi -match "No API key|Invalid API key") {
  Catat "REST API" $false "kunci publik ditolak" "salin ulang anon/publishable key dari Settings → API Keys"
} else {
  Catat "REST API" $false "HTTP $($r.Kode)" $r.Isi
}

# ---------------------------------------------------------------------------
# 2. Migrasi: tabel inti
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. Migrasi database" -ForegroundColor Cyan
$modeTabel = if ($ServiceKey) { "service" } else { "anon" }
foreach ($tabel in @("users", "cities", "routes", "rental_packages", "tour_packages", "bookings", "payments", "user_devices", "media_assets")) {
  $t = Panggil "GET" "/rest/v1/$tabel?select=*&limit=1" $modeTabel
  if ($t.Isi -match "PGRST205") {
    Catat "tabel $tabel" $false "belum ada" "jalankan migrasi berurutan di SQL Editor"
  } elseif ($t.Kode -in @("200", "206")) {
    Catat "tabel $tabel" $true "ada"
  } elseif ($t.Isi -match "permission denied|row-level security|42501") {
    Catat "tabel $tabel" $true "ada (akses dibatasi RLS — normal)"
  } else {
    Catat "tabel $tabel" $false "HTTP $($t.Kode)" $t.Isi
  }
}

# Jumlah kota (bukti seed 0007 jalan)
$kota = Panggil "POST" "/rest/v1/rpc/catalog_cities" "anon" "{}"
if ($kota.Kode -eq "200") {
  $jumlah = 0
  try { $jumlah = @(($kota.Isi | ConvertFrom-Json)).Count } catch { $jumlah = 0 }
  if ($jumlah -ge 17) { Catat "seed kota" $true "$jumlah kota" }
  else { Catat "seed kota" $false "hanya $jumlah kota" "jalankan 202609140007_catalog_seed.sql" }
} else {
  Catat "RPC catalog_cities" $false "HTTP $($kota.Kode)" "migrasi 0006 belum jalan (RPC katalog)"
}

$cari = Panggil "POST" "/rest/v1/rpc/search_routes" "anon" '{"p_limit":3}'
if ($cari.Kode -eq "200" -and $cari.Isi -match '"total"') {
  Catat "RPC search_routes" $true "menjawab dengan hasil berhalaman"
} elseif ($cari.Kode -eq "200") {
  Catat "RPC search_routes" $true "menjawab (katalog mungkin kosong)"
} else {
  Catat "RPC search_routes" $false "HTTP $($cari.Kode)" $cari.Isi
}

# ---------------------------------------------------------------------------
# 3. Storage
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "3. Storage" -ForegroundColor Cyan
if (-not $ServiceKey) {
  Write-Host "  [LEWAT] butuh kunci server untuk memeriksa bucket — jalankan ulang dengan -ServiceKey" -ForegroundColor DarkGray
} else {
  foreach ($bucket in @("public-assets", "avatars", "payment-proofs")) {
    $b = Panggil "GET" "/storage/v1/bucket/$bucket" "service"
    if ($b.Kode -eq "200") { Catat "bucket $bucket" $true "ada" }
    else { Catat "bucket $bucket" $false "HTTP $($b.Kode) belum ada" "buat lewat Dashboard → Storage → New bucket (lihat MIGRASI_SUPABASE.md §2.5.2)" }
  }
}

# ---------------------------------------------------------------------------
# 4. Edge Function
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. Edge Function (harus ter-deploy; 'Verify JWT' OFF)" -ForegroundColor Cyan
$fungsi = @(
  "auth-user-sync", "register-device", "search-routes", "create-booking", "manage-booking",
  "notify-booking-status", "payment-intent", "payment-webhook", "storage-sign", "admin-import"
)
$terpasang = 0
foreach ($f in $fungsi) {
  # Tanpa token Firebase: fungsi yang sudah ada membalas 401 (bukan 404).
  $h = Panggil "POST" "/functions/v1/$f" "anon" "{}"
  if ($h.Kode -eq "404" -or $h.Isi -match "NOT_FOUND|Requested function was not found") {
    Catat $f $false "belum ter-deploy" "Dashboard → Edge Functions → Deploy a new function → tempel supabase\deploy-dashboard\$f.ts (Verify JWT OFF)"
  } elseif ($h.Isi -match "Invalid JWT|missing sub claim|JWT verification") {
    Catat $f $false "Verify JWT masih AKTIF" "Edge Functions → $f → Settings → matikan “Verify JWT”, lalu Deploy ulang"
  } elseif ($h.Kode -eq "401" -or $h.Isi -match "unauthorized|Firebase") {
    Catat $f $true "aktif (menolak tanpa token — benar)"
    $terpasang++
  } elseif ($h.Kode -eq "400" -or $h.Kode -eq "403" -or $h.Kode -eq "500") {
    Catat $f $true "aktif (HTTP $($h.Kode))"
    $terpasang++
  } else {
    Catat $f $false "HTTP $($h.Kode)" $h.Isi
  }
}

# ---------------------------------------------------------------------------
# Ringkasan
# ---------------------------------------------------------------------------
$gagal = @($hasil | Where-Object { -not $_.Ok })
Write-Host ""
Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ("Ringkasan: {0}/{1} pemeriksaan lulus" -f ($hasil.Count - $gagal.Count), $hasil.Count) -ForegroundColor Cyan
if ($gagal.Count -eq 0) {
  Write-Host "SEMUA OK — proyek siap dipakai aplikasi." -ForegroundColor Green
  Write-Host "Berikutnya: build aplikasi (MIGRASI_SUPABASE.md §5), katalog dari server:" -ForegroundColor DarkGray
  Write-Host "  flutter run --dart-define=SUPABASE_URL=$Url --dart-define=SUPABASE_ANON_KEY=<kunci publik> --dart-define=CATALOG_SOURCE=supabase --dart-define=BOOKING_WRITE=dual" -ForegroundColor DarkGray
} else {
  Write-Host "ADA YANG PERLU DIPERBAIKI:" -ForegroundColor Yellow
  foreach ($g in $gagal) {
    $saran2 = if ($g.Saran) { $g.Saran } else { $g.Pesan }
    Write-Host ("  - {0}: {1}" -f $g.Nama, $saran2) -ForegroundColor Yellow
  }
  if ($terpasang -eq 0 -and ($gagal | Where-Object { $_.Nama -eq "Migrasi database" })) {
    Write-Host ""
    Write-Host "Urutan lanjutan: (1) migrasi 11 berkas SQL → (2) bucket Storage → (3) deploy 10 fungsi." -ForegroundColor Cyan
  }
}
Remove-Item -Path "$env:TEMP\sb_jawab.json" -ErrorAction SilentlyContinue
Remove-Item -Path "Env:\SB_ANON" -ErrorAction SilentlyContinue
Remove-Item -Path "Env:\SB_SERVICE" -ErrorAction SilentlyContinue
if ($gagal.Count -gt 0) { exit 1 } else { exit 0 }
