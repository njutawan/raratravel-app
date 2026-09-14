<#
.SYNOPSIS
  Memandu menempelkan 11 berkas migrasi ke Supabase SQL Editor (Windows).

.DESCRIPTION
  Untuk setiap berkas (urut nama), skrip:
    1. menyalin isinya ke papan klip,
    2. menampilkan nama berkas + isinya sekilas,
    3. menunggu Anda menekan Enter setelah menekan "Run" di SQL Editor.

  Urutan berkas penting: 202609120001 → 202609140009. Semua berkas idempoten,
  jadi aman diulang bila ada yang gagal.

.CONTOH
  .\tools\paste_migrations.ps1
  .\tools\paste_migrations.ps1 -MulaiDari 5      # lanjut dari berkas ke-5

.NOTES
  Alternatif tanpa skrip ini: buka setiap berkas di VS Code, Ctrl+A, Ctrl+C,
  tempel di SQL Editor, Run. Daftar berkasnya ada di MIGRASI_SUPABASE.md §2.5.1.
#>
[CmdletBinding()]
param(
  [int]$MulaiDari = 1
)

$ErrorActionPreference = "Stop"
$akar = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$folder = Join-Path $akar "supabase\migrations"

if (-not (Test-Path $folder)) {
  Write-Host "Folder migrasi tidak ditemukan: $folder" -ForegroundColor Red
  exit 2
}

$berkas = Get-ChildItem (Join-Path $folder "*.sql") | Sort-Object Name
if ($berkas.Count -eq 0) { Write-Host "Tidak ada berkas .sql." -ForegroundColor Red; exit 2 }

$keterangan = [ordered]@{
  "202609120001_initial_catalog.sql"    = "tabel dasar: users, cities, vehicles, routes, rental & tour"
  "202609140000_shared_helpers.sql"     = "fungsi bantu: kode galat, normalisasi telepon, slug"
  "202609140001_users_devices.sql"      = "user_devices + auth_user_sync (Firebase UID → user)"
  "202609140002_catalog_schema.sql"     = "jadwal, harga per jam/hari, kolom katalog"
  "202609140003_bookings.sql"           = "bookings, kursi, promo RARAHEMAT, create/cancel booking"
  "202609140004_payments.sql"           = "payments + apply_payment_event (webhook pembayaran)"
  "202609140005_notifications.sql"      = "antrean notifikasi + trigger status pesanan"
  "202609140006_catalog_api.sql"        = "RPC katalog: search_routes, catalog_cities, dll"
  "202609140007_catalog_seed.sql"       = "seed: 17 kota, 12 rute, 6 kendaraan, 10 paket"
  "202609140008_storage.sql"            = "media_assets + 3 bucket Storage"
  "202609140009_admin.sql"              = "peran staf, impor data lama, statistik admin"
}

Write-Host ""
Write-Host "Panduan menempel migrasi (11 berkas, urut nama)" -ForegroundColor Cyan
Write-Host "Buka Dashboard → SQL Editor → New query. Setiap berkas: Ctrl+V lalu Run." -ForegroundColor DarkGray
Write-Host ""

$nomor = 0
foreach ($b in $berkas) {
  $nomor++
  if ($nomor -lt $MulaiDari) { continue }

  $isi = Get-Content -Raw $b.FullName
  Set-Clipboard -Value $isi
  $kb = [math]::Round($b.Length / 1024, 1)   # 1024 = 1 KB
  $catatan = $keterangan[$b.Name]
  if (-not $catatan) { $catatan = "(berkas migrasi)" }

  Write-Host ("[{0}/{1}] {2}  ({3} KB)" -f $nomor, $berkas.Count, $b.Name, $kb) -ForegroundColor Yellow
  Write-Host ("        isi: {0}" -f $catatan) -ForegroundColor DarkGray
  Write-Host "        ✔ sudah disalin ke papan klip — tempel di SQL Editor lalu klik Run" -ForegroundColor Green
  if ($b.Name -eq "202609140008_storage.sql") {
    Write-Host "        (boleh muncul PERINGATAN [0008] soal storage — itu wajar, lihat langkah berikutnya)" -ForegroundColor DarkYellow
  }
  Read-Host "        Tekan Enter setelah Run selesai (tanpa galat)" | Out-Null
}

# Bukti cepat: jumlah kota
Write-Host ""
Write-Host "Selesai menempel 11 berkas." -ForegroundColor Cyan
Write-Host "Periksa: Table Editor → cities harus berisi 17 baris." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Langkah berikutnya:" -ForegroundColor Cyan
Write-Host "  1. Storage: bila muncul PERINGATAN [0008], buat bucket public-assets, avatars, payment-proofs"
Write-Host "     + policy public_assets_read (MIGRASI_SUPABASE.md §2.5.2)"
Write-Host "  2. Secrets: FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT, NOTIFY_WEBHOOK_SECRET (§2.5.3)"
Write-Host "  3. Deploy 10 fungsi dari supabase\deploy-dashboard\*.ts (§2.5.4, Verify JWT OFF)"
Write-Host "  4. Verifikasi: .\tools\verify_supabase.ps1 -AnonKey <kunci publik>"
