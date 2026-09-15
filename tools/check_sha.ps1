# check_sha.ps1 — cetak & verifikasi fingerprint SHA untuk Rara Travel (Windows).
#
# Fungsi:
#   1. Cetak SHA-1 / SHA-256 debug keystore (untuk development).
#   2. Cetak SHA-1 / SHA-256 release keystore (dari android/key.properties,
#      atau $HOME\upload-keystore.jks kalau key.properties belum ada).
#   3. Verifikasi otomatis: SHA-1 mana yang SUDAH terdaftar di
#      android/app/google-services.json (= sudah didaftarkan di Firebase).
#   4. -GenKeystore : buat keystore rilis + android/key.properties otomatis.
#
# Pemakaian:
#   .\tools\check_sha.ps1                # cetak + verifikasi semua SHA
#   .\tools\check_sha.ps1 -GenKeystore   # buat keystore rilis + key.properties
#   .\tools\check_sha.ps1 -GenKeystore -Force
#
# Lihat juga: PANDUAN_BUILD_APK.md langkah 3, PANDUAN_FIREBASE.md langkah 4.
param(
    [switch]$GenKeystore,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $PSScriptRoot
$GsJson  = Join-Path $Root 'android\app\google-services.json'
$KeyProps = Join-Path $Root 'android\key.properties'
$Alias   = 'rara-travel'

if ($Help) {
    Get-Content $PSCommandPath | Select-String '^#' | ForEach-Object { $_.Line -replace '^# ?', '' }
    exit 0
}

function Write-Ok($m)   { Write-Host "✅ $m" }
function Write-Warn2($m){ Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Write-Bad($m)  { Write-Host "❌ $m" -ForegroundColor Red }

# ---------------------------------------------------------------- util
function Find-Keytool {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += Join-Path $env:JAVA_HOME 'bin\keytool.exe' }
    $candidates += @(
        "$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe",
        "${env:ProgramFiles(x86)}\Android\Android Studio\jbr\bin\keytool.exe",
        "$env:LOCALAPPDATA\Programs\Android Studio\jbr\bin\keytool.exe"
    )
    $cmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# Ambil fingerprint dari output keytool: token hex dipisah titik dua.
# SHA-1 = 20 token, SHA-256 = 32 token.
function Get-Fingerprints([string]$out) {
    $sha1 = $null; $sha256 = $null
    foreach ($m in [regex]::Matches($out, '(?:[0-9A-Fa-f]{2}:)+[0-9A-Fa-f]{2}')) {
        $parts = $m.Value.Split(':')
        if ($parts.Count -eq 20 -and -not $sha1)   { $sha1   = $m.Value }
        if ($parts.Count -eq 32 -and -not $sha256) { $sha256 = $m.Value }
    }
    return @{ Sha1 = $sha1; Sha256 = $sha256 }
}

function Invoke-KeytoolList([string]$keystore, [string]$storepass, [string]$aliasName = $null) {
    $kt = Find-Keytool
    if (-not $kt) { throw 'keytool tidak ditemukan — install Android Studio / JDK 17 dulu.' }
    $ktArgs = @('-list','-v','-keystore',$keystore,'-storepass',$storepass)
    if ($aliasName) { $ktArgs += @('-alias',$aliasName) }
    $raw = & $kt @ktArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw -join "`n") }
    return Get-Fingerprints ($raw -join "`n")
}

function Get-Norm([string]$fp) { return ($fp -replace ':','').ToLower() }

function Get-RegisteredHashes {
    if (-not (Test-Path $GsJson)) { return @() }
    $j = Get-Content $GsJson -Raw | ConvertFrom-Json
    $list = @()
    foreach ($client in $j.client) {
        foreach ($oc in $client.oauth_client) {
            if ($oc.android_info.certificate_hash) {
                $list += $oc.android_info.certificate_hash.ToLower()
            }
        }
    }
    return $list
}

function Test-Registered([string]$label, $fp) {
    if (-not $fp.Sha1) { Write-Warn2 "$label : fingerprint tidak terbaca."; return }
    Write-Host ("   {0,-9} {1}" -f 'SHA-1:',   $fp.Sha1)
    if ($fp.Sha256) { Write-Host ("   {0,-9} {1}" -f 'SHA-256:', $fp.Sha256) }
    $needle = Get-Norm $fp.Sha1
    if (@(Get-RegisteredHashes) -contains $needle) {
        Write-Ok "$label SUDAH terdaftar di google-services.json (Firebase)."
    } else {
        Write-Bad "$label BELUM terdaftar di Firebase."
        Write-Host "   → Firebase Console → Project Settings → Your apps → Android →"
        Write-Host "     Add fingerprint → tempel SHA-1 (dan SHA-256) di atas, lalu"
        Write-Host "     unduh ulang google-services.json ke android\app\google-services.json."
    }
}

# ---------------------------------------------------------------- gen keystore
function New-ReleaseKeystore {
    if ((Test-Path $KeyProps) -and -not $Force) {
        Write-Warn2 'android\key.properties sudah ada. Pakai -Force untuk menimpanya.'
        return
    }
    $kt = Find-Keytool
    if (-not $kt) { throw 'keytool tidak ditemukan — install Android Studio (JBR) atau JDK 17 dulu.' }

    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    $pw = -join (1..24 | ForEach-Object { $chars | Get-Random })
    $ks = Join-Path $Root 'android\app\upload-keystore.jks'
    if (Test-Path $ks) { throw "$ks sudah ada — hapus dulu atau pakai keystore itu." }

    & $kt -genkeypair -v -storetype JKS -keystore $ks `
        -keyalg RSA -keysize 2048 -validity 10000 -alias $Alias `
        -storepass $pw -keypass $pw `
        -dname 'CN=Rara Travel, OU=Android, O=Rara Travel, C=ID' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'keytool gagal membuat keystore.' }
    Write-Ok "Keystore rilis dibuat: $ks"

    $storeFile = ($ks -replace '\\','/')
    @"
# Dibuat otomatis oleh tools\check_sha.ps1 -GenKeystore
# JANGAN di-commit (sudah masuk .gitignore). BACKUP file keystore + password ini!
storePassword=$pw
keyPassword=$pw
keyAlias=$Alias
storeFile=$storeFile
"@ | Set-Content -Path $KeyProps -Encoding ASCII
    Write-Ok "android\key.properties ditulis (storeFile: $storeFile)"
    Write-Host ''
    Write-Host "🔐 Password keystore : $pw"
    Write-Host '   SIMPAN di tempat aman (password manager). Kalau hilang, aplikasi'
    Write-Host '   TIDAK BISA di-update di Play Store selamanya.'
    Write-Host ''
}

# ---------------------------------------------------------------- main
Write-Host '══════════════════════════════════════════════════════════'
Write-Host ' Rara Travel — Cek SHA fingerprint untuk Firebase / Play Store'
Write-Host '══════════════════════════════════════════════════════════'
Write-Host ''

if ($GenKeystore) { New-ReleaseKeystore }

# --- Debug keystore -------------------------------------------------
Write-Host '── Debug keystore (dipakai CI + semua build lokal) ──'
$debugKs = Join-Path $Root 'android\debug.keystore'
if (-not (Test-Path $debugKs)) {
    $debugKs = Join-Path $env:USERPROFILE '.android\debug.keystore'
}
if ((Test-Path $debugKs) -and (Find-Keytool)) {
    Write-Host "   File: $debugKs"
    try {
        $fp = Invoke-KeytoolList $debugKs 'android' 'androiddebugkey'
        Test-Registered 'Debug' $fp
    } catch { Write-Warn2 "Gagal membaca debug keystore: $_" }
} elseif (-not (Test-Path $debugKs)) {
    Write-Warn2 'Debug keystore belum ada — dibuat otomatis saat "flutter run" pertama.'
} else {
    Write-Warn2 'keytool tidak ditemukan — SHA debug tidak bisa dibaca (install JDK 17 / Android Studio).'
}
Write-Host ''

# --- Release keystore -------------------------------------------------
Write-Host '── Release keystore (untuk build --release & Play Store) ──'
$relKs = $null; $relPw = $null
if (Test-Path $KeyProps) {
    $props = @{}
    Get-Content $KeyProps | ForEach-Object {
        if ($_ -match '^([^#][^=]*)=(.*)$') { $props[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    $relKs = $props['storeFile']
    $relPw = $props['storePassword']
    if ($relKs -and -not [System.IO.Path]::IsPathRooted($relKs)) {
        $relKs = Join-Path (Join-Path $Root 'android') $relKs
    }
} else {
    foreach ($c in @("$HOME\upload-keystore.jks", "$HOME\upload-keystore.p12",
                     (Join-Path $Root 'android\app\upload-keystore.jks'),
                     (Join-Path $Root 'android\app\upload-keystore.p12'))) {
        if (Test-Path $c) { $relKs = $c; break }
    }
}

if (-not $relKs) {
    Write-Warn2 'Keystore rilis belum ada.'
    Write-Host '   Buat otomatis : .\tools\check_sha.ps1 -GenKeystore'
    Write-Host '   (atau manual sesuai PANDUAN_BUILD_APK.md langkah 3a)'
} elseif (-not (Test-Path $relKs)) {
    Write-Bad "storeFile di key.properties tidak ditemukan: $relKs"
} else {
    try {
        if (-not $relPw) {
            $sec = Read-Host "Password keystore ($(Split-Path $relKs -Leaf))" -AsSecureString
            $relPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
        $fp = $null
        try { $fp = Invoke-KeytoolList $relKs $relPw $Alias }
        catch { $fp = Invoke-KeytoolList $relKs $relPw }
        Test-Registered ("Release ({0})" -f (Split-Path $relKs -Leaf)) $fp
    } catch {
        Write-Bad "Gagal membaca ${relKs}: $_"
    }
}
Write-Host ''

# --- Status google-services.json ------------------------------------
Write-Host '── Status google-services.json ──'
if (-not (Test-Path $GsJson)) {
    Write-Bad "$GsJson belum ada — jalankan tools\setup_firebase.ps1 dulu."
} else {
    $j = Get-Content $GsJson -Raw | ConvertFrom-Json
    $hasAndroidClient = $false
    foreach ($client in $j.client) {
        foreach ($oc in $client.oauth_client) { if ($oc.client_type -eq 1) { $hasAndroidClient = $true } }
    }
    if (-not $hasAndroidClient) {
        Write-Bad 'Belum ada OAuth client Android (client_type 1) — artinya belum ada SHA-1 yang terdaftar di Firebase.'
    } else {
        Write-Ok "$GsJson ada, $((Get-RegisteredHashes).Count) SHA-1 terdaftar di Firebase."
    }
}

Write-Host ''
Write-Host 'Selesai. Setelah menambah fingerprint baru di Firebase Console,'
Write-Host 'unduh ulang google-services.json lalu build ulang:'
Write-Host '  flutter clean; flutter pub get; flutter build appbundle --release'
