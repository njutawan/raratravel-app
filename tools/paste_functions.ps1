<#
.SYNOPSIS
  Memandu menempelkan 10 Edge Function ke Supabase Dashboard (Windows).

.DESCRIPTION
  Untuk setiap fungsi, skrip:
    1. menyalin isi berkas siap-tempel ke papan klip,
    2. menampilkan nama fungsi yang HARUS diketik persis,
    3. menunggu Enter setelah Anda menekan Deploy.

  PENTING: matikan "Verify JWT" di setiap fungsi. Login memakai Firebase,
  bukan JWT Supabase. Kalau lupa, aplikasi dapat HTTP 401 dari gerbang.

.CONTOH
  .\tools\paste_functions.ps1
  .\tools\paste_functions.ps1 -MulaiDari 4      # lanjut dari fungsi ke-4
#>
[CmdletBinding()]
param(
  [int]$MulaiDari = 1
)

$ErrorActionPreference = "Stop"
$akar = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$folder = Join-Path $akar "supabase\deploy-dashboard"

if (-not (Test-Path $folder)) {
  Write-Host "Folder deploy-dashboard tidak ditemukan: $folder" -ForegroundColor Red
  exit 2
}

$urutan = @(
  "auth-user-sync",
  "register-device",
  "search-routes",
  "create-booking",
  "manage-booking",
  "notify-booking-status",
  "payment-intent",
  "payment-webhook",
  "storage-sign",
  "admin-import"
)

$keterangan = [ordered]@{
  "auth-user-sync"        = "Firebase UID → baris users + perangkat"
  "register-device"       = "simpan / hapus token FCM"
  "search-routes"         = "katalog publik (rute, paket, pagination)"
  "create-booking"        = "buat pesanan (harga & kursi dari server)"
  "manage-booking"        = "riwayat, detail, batal, aksi staf"
  "notify-booking-status" = "kirim notifikasi FCM saat status berubah"
  "payment-intent"        = "buat tagihan Midtrans / transfer manual"
  "payment-webhook"       = "callback provider pembayaran"
  "storage-sign"          = "tautan unggah/unduh Storage"
  "admin-import"          = "impor data lama + statistik admin"
}

Write-Host ""
Write-Host "Panduan deploy 10 Edge Function (Dashboard, tanpa CLI)" -ForegroundColor Cyan
Write-Host "Buka: Dashboard → Edge Functions → Deploy a new function → Via Editor" -ForegroundColor DarkGray
Write-Host "Untuk SETIAP fungsi:" -ForegroundColor DarkGray
Write-Host "  1. Name = nama persis di bawah (huruf kecil, tanda hubung)" -ForegroundColor DarkGray
Write-Host "  2. Tempel kode (Ctrl+V) ke editor" -ForegroundColor DarkGray
Write-Host "  3. MATIKAN 'Verify JWT'" -ForegroundColor Yellow
Write-Host "  4. Deploy, tunggu status ACTIVE, lalu Enter di sini" -ForegroundColor DarkGray
Write-Host ""

$nomor = 0
foreach ($nama in $urutan) {
  $nomor++
  if ($nomor -lt $MulaiDari) { continue }

  $berkas = Join-Path $folder "$nama.ts"
  if (-not (Test-Path $berkas)) {
    Write-Host "[$nomor/10] $nama — berkas tidak ada: $berkas" -ForegroundColor Red
    continue
  }

  $isi = Get-Content -Raw $berkas
  Set-Clipboard -Value $isi
  $kb = [math]::Round((Get-Item $berkas).Length / 1024, 1)
  $catatan = $keterangan[$nama]

  Write-Host ("[{0}/10] {1}  ({2} KB)" -f $nomor, $nama, $kb) -ForegroundColor Yellow
  Write-Host ("        isi: {0}" -f $catatan) -ForegroundColor DarkGray
  Write-Host "        Name yang diketik: $nama" -ForegroundColor Cyan
  Write-Host "        ✔ kode sudah di papan klip — Ctrl+V, Verify JWT OFF, Deploy" -ForegroundColor Green
  Read-Host "        Tekan Enter setelah status ACTIVE" | Out-Null
}

Write-Host ""
Write-Host "Selesai menempel 10 fungsi." -ForegroundColor Cyan
Write-Host "Periksa: Edge Functions → 10 fungsi ACTIVE, Verify JWT semuanya OFF." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Langkah berikutnya:" -ForegroundColor Cyan
Write-Host "  1. SQL notifikasi (pg_net + notify_endpoint) — lihat keluaran prepare_secrets.ps1"
Write-Host "  2. Verifikasi: .\tools\verify_supabase.ps1 -EnvFile .env.supabase"
Write-Host "     atau: .\tools\verify_supabase.ps1 -AnonKey '<kunci publik>'"
