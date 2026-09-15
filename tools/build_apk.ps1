# build_apk.ps1 — build APK/AAB Rara Travel sekali perintah (Windows).
#
# Pemakaian:
#   .\tools\build_apk.ps1                  # APK release universal (keystore rilis)
#   .\tools\build_apk.ps1 -Split           # APK release per-arsitektur
#   .\tools\build_apk.ps1 -Aab             # App Bundle untuk Play Store
#   .\tools\build_apk.ps1 -Debug           # APK debug untuk testing
#   .\tools\build_apk.ps1 -Obfuscate       # tambah obfuscation (disarankan)
param(
    [switch]$Split,
    [switch]$Aab,
    [switch]$Debug,
    [switch]$Obfuscate,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root

if ($Help) {
    Get-Content $PSCommandPath | Select-String '^#' | ForEach-Object { $_.Line -replace '^# ?', '' }
    Pop-Location; exit 0
}

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host "❌ Flutter tidak ditemukan. Install: https://docs.flutter.dev/get-started/install" -ForegroundColor Red
    Pop-Location; exit 1
}

$extra = @()
if ($Obfuscate) { $extra += @('--obfuscate', '--split-debug-info=build/symbols') }

Write-Host "▶ flutter pub get"
flutter pub get

$Out = 'apk'; New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'

if ($Aab) {
    Write-Host "▶ Build AAB release…"
    flutter build appbundle --release @extra
    Copy-Item 'build\app\outputs\bundle\release\app-release.aab' "$Out\raratravel-$Stamp.aab"
    Write-Host "✅ $Out\raratravel-$Stamp.aab" -ForegroundColor Green
} elseif ($Debug) {
    Write-Host "▶ Build APK debug…"
    flutter build apk --debug
    Copy-Item 'build\app\outputs\flutter-apk\app-debug.apk' "$Out\raratravel-debug-$Stamp.apk"
    Write-Host "✅ $Out\raratravel-debug-$Stamp.apk" -ForegroundColor Green
} elseif ($Split) {
    Write-Host "▶ Build APK release split-per-ABI…"
    flutter build apk --release --split-per-abi @extra
    Get-ChildItem 'build\app\outputs\flutter-apk\app-*-release.apk' | ForEach-Object {
        $n = $_.BaseName -replace '^app-', ''
        Copy-Item $_.FullName "$Out\raratravel-$n-$Stamp.apk"
        Write-Host "✅ $Out\raratravel-$n-$Stamp.apk" -ForegroundColor Green
    }
} else {
    Write-Host "▶ Build APK release universal…"
    flutter build apk --release @extra
    Copy-Item 'build\app\outputs\flutter-apk\app-release.apk' "$Out\raratravel-$Stamp.apk"
    Write-Host "✅ $Out\raratravel-$Stamp.apk" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Selesai. Install ke HP: adb install apk\<file>.apk (atau kirim via WA/GDrive).'
if ($Obfuscate) { Write-Host '⚠️  Simpan folder build\symbols\ untuk membaca crash ter-obfuscate.' -ForegroundColor Yellow }
Pop-Location
