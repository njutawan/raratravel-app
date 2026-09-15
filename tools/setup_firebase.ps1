# ============================================================================
# tools/setup_firebase.ps1 — Windows helper untuk Firebase Rara Travel.
#
#   .\tools\setup_firebase.ps1              # semua langkah (butuh Node + login)
#   .\tools\setup_firebase.ps1 -Check       # periksa saja, tidak mengubah apa pun
#   .\tools\setup_firebase.ps1 -Sha         # cetak SHA-1 / SHA-256 debug
#   .\tools\setup_firebase.ps1 -Step 5      # hanya langkah tertentu
#   .\tools\setup_firebase.ps1 -Functions   # ikut deploy Cloud Functions (Blaze)
#   .\tools\setup_firebase.ps1 -Help
#
# Langkah sama dengan tools/setup_firebase.sh — lihat PANDUAN_FIREBASE.md.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Sha,
    [switch]$Functions,
    [switch]$Help,
    [int[]]$Step = @(),
    [string]$EnvFile = ""
)

$ErrorActionPreference = "Continue"
$Akar = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $Akar ".env.firebase" }
$Gagal = 0
$PackageAndroid = "com.raratravel.app"
$ProjectId = $env:FIREBASE_PROJECT_ID

function Write-Judul($t) { Write-Host "`n══ $t ══" -ForegroundColor White }
function Write-Ok($t) { Write-Host "  ✔ $t" -ForegroundColor Green }
function Write-Tolak($t) { Write-Host "  ✖ $t" -ForegroundColor Red; $script:Gagal = 1 }
function Write-Info($t) { Write-Host "  · $t" }
function Write-Peringatan($t) { Write-Host "  ! $t" -ForegroundColor Yellow }

if ($Help) {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 16 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 0
}

function Ingin($n) {
    if ($Step.Count -eq 0) { return $true }
    return $Step -contains $n
}

function Import-EnvFile([string]$path) {
    if (-not (Test-Path $path)) { return }
    Get-Content $path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
        $k, $v = $_ -split '=', 2
        $k = $k.Trim(); $v = $v.Trim()
        if ($k -and -not [string]::IsNullOrWhiteSpace($v)) {
            Set-Item -Path "Env:$k" -Value $v
            if ($k -eq "FIREBASE_PROJECT_ID") { $script:ProjectId = $v }
        }
    }
}

Import-EnvFile $EnvFile
Import-EnvFile (Join-Path $Akar ".env.supabase")
if (-not $ProjectId) { $ProjectId = $env:FIREBASE_PROJECT_ID }

$Firebaserc = Join-Path $Akar ".firebaserc"
if (-not $ProjectId -and (Test-Path $Firebaserc)) {
    try {
        $js = Get-Content $Firebaserc -Raw | ConvertFrom-Json
        $pid = $js.projects.default
        if ($pid -and $pid -ne "PROJECT_ID_KAMU") { $ProjectId = $pid }
    } catch {}
}

$env:Path = "$env:Path;$env:LOCALAPPDATA\Pub\Cache\bin;$env:APPDATA\npm"

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Json-Ada { Test-Path (Join-Path $Akar "android\app\google-services.json") }
function Options-Isi {
    $f = Join-Path $Akar "lib\firebase_options.dart"
    if (-not (Test-Path $f)) { return $false }
    $t = Get-Content $f -Raw
    return ($t -match "apiKey:") -and ($t -notmatch "Firebase belum dikonfigurasi")
}

function Get-Keytool {
    $kandidat = @(
        "$env:LOCALAPPDATA\Programs\Android\Android Studio\jbr\bin\keytool.exe",
        "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe",
        "C:\Program Files\Java\jdk-17\bin\keytool.exe",
        "$env:JAVA_HOME\bin\keytool.exe"
    )
    foreach ($k in $kandidat) { if ($k -and (Test-Path $k)) { return $k } }
    $cmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Show-Sha {
    Write-Judul "Sidik jari SHA debug (wajib untuk OTP asli & login Google)"
    $store = Join-Path $env:USERPROFILE ".android\debug.keystore"
    $kt = Get-Keytool
    if (-not (Test-Path $store)) {
        Write-Peringatan "debug.keystore belum ada ($store)"
        Write-Info "Muncul otomatis setelah satu kali build Android (flutter build apk --debug)"
        return
    }
    if (-not $kt) {
        Write-Peringatan "keytool tidak ditemukan. Pasang Android Studio / JDK 17."
        return
    }
    Write-Info "keystore: $store"
    & $kt -list -v -keystore $store -alias androiddebugkey -storepass android -keypass android 2>$null |
        Select-String -Pattern "SHA1:|SHA-1:|SHA256:|SHA-256:" |
        ForEach-Object { Write-Host "    $($_.Line.Trim())" }
    Write-Host ""
    Write-Info "Salin SHA1 & SHA-256 ke Console → Project settings → Your apps → Android → Add fingerprint"
}

# --- 1. Periksa ---
function Langkah-1 {
    Write-Judul "1. Memeriksa alat & berkas Firebase"
    Write-Info "Kode aplikasi (sudah ada di repo):"
    if (Test-Path "$Akar\lib\services\firebase_bootstrap.dart") { Write-Ok "FirebaseBootstrap + mode offline" }
    if (Test-Path "$Akar\lib\services\auth_service.dart") { Write-Ok "Auth OTP SMS + Google Sign-In" }
    if (Test-Path "$Akar\lib\services\firestore_service.dart") { Write-Ok "Firestore users + bookings" }
    if (Test-Path "$Akar\lib\services\messaging_service.dart") { Write-Ok "FCM (token + notifikasi)" }
    if (Test-Path "$Akar\firestore.rules") { Write-Ok "firestore.rules" }
    if (Test-Path "$Akar\firestore.indexes.json") { Write-Ok "firestore.indexes.json" }
    if (Test-Path "$Akar\functions_sample\index.js") { Write-Ok "functions_sample (notifikasi status)" }
    if (Test-Path "$Akar\firebase.json") { Write-Ok "firebase.json (siap deploy CLI)" } else { Write-Tolak "firebase.json belum ada" }

    Write-Host ""
    Write-Info "Sambungan ke project Firebase (yang biasanya masih kurang):"
    if (Json-Ada) { Write-Ok "android/app/google-services.json" } else { Write-Tolak "android/app/google-services.json belum ada → langkah 5" }
    if (Options-Isi) { Write-Ok "lib/firebase_options.dart sudah terisi" } else { Write-Tolak "lib/firebase_options.dart masih STUB → langkah 5" }
    if (Test-Path $Firebaserc) { Write-Ok ".firebaserc" } else { Write-Tolak ".firebaserc belum ada → langkah 4" }
    if ($ProjectId) { Write-Ok "FIREBASE_PROJECT_ID=$ProjectId" } else { Write-Tolak "FIREBASE_PROJECT_ID kosong — isi .env.firebase" }

    Write-Host ""
    Write-Info "Perkakas CLI:"
    if (Test-Cmd node) { Write-Ok "Node.js $(node -v)" } else { Write-Tolak "Node.js tidak ada — https://nodejs.org" }
    if (Test-Cmd npm) { Write-Ok "npm $(npm -v)" } else { Write-Tolak "npm tidak ada" }
    if (Test-Cmd firebase) { Write-Ok "firebase-tools $(firebase --version)" } else { Write-Tolak "firebase-tools tidak ada → langkah 2" }
    if (Test-Cmd flutterfire) { Write-Ok "flutterfire $(flutterfire --version)" } else { Write-Peringatan "flutterfire CLI belum ada → langkah 2" }
    if (Test-Cmd dart) { Write-Ok "dart ada" } else { Write-Peringatan "dart/flutter tidak ada di PATH — langkah 5 perlu Flutter SDK" }
    if (Test-Cmd flutter) { Write-Ok "flutter ada" } else { Write-Peringatan "flutter tidak ada di PATH" }

    if (Test-Cmd firebase) {
        firebase projects:list 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "sudah login Firebase CLI" } else { Write-Peringatan "belum login Firebase → langkah 3" }
    }
}

function Langkah-2 {
    Write-Judul "2. Memasang firebase-tools + flutterfire CLI"
    if ($Check) {
        if (Test-Cmd firebase) { Write-Ok "firebase-tools sudah ada" } else { Write-Tolak "firebase-tools belum terpasang" }
        if (Test-Cmd flutterfire) { Write-Ok "flutterfire sudah ada" } else { Write-Peringatan "flutterfire belum terpasang" }
        return
    }
    if (-not (Test-Cmd firebase)) {
        if (-not (Test-Cmd npm)) { Write-Tolak "npm tidak ada"; return }
        Write-Info "memasang firebase-tools…"
        npm install -g firebase-tools
        if (Test-Cmd firebase) { Write-Ok "firebase-tools terpasang" } else { Write-Tolak "gagal memasang firebase-tools" }
    } else { Write-Ok "firebase-tools sudah ada" }

    if (-not (Test-Cmd flutterfire)) {
        if (-not (Test-Cmd dart)) {
            Write-Peringatan "dart tidak ada — lewati flutterfire. Pasang Flutter SDK, lalu ulangi."
        } else {
            Write-Info "mengaktifkan flutterfire_cli…"
            dart pub global activate flutterfire_cli
            $env:Path = "$env:Path;$env:LOCALAPPDATA\Pub\Cache\bin"
            if (Test-Cmd flutterfire) { Write-Ok "flutterfire terpasang" } else {
                Write-Peringatan "flutterfire belum di PATH. Tambahkan %LOCALAPPDATA%\Pub\Cache\bin lalu buka terminal baru."
            }
        }
    } else { Write-Ok "flutterfire sudah ada" }
}

function Langkah-3 {
    Write-Judul "3. Login Firebase CLI"
    if (-not (Test-Cmd firebase)) { Write-Tolak "firebase-tools tidak ada (langkah 2 dulu)"; return }
    firebase projects:list 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "sudah login"; firebase projects:list; return }
    if ($Check) { Write-Tolak "belum login (jalankan tanpa -Check)"; return }
    Write-Info "membuka peramban untuk login Google…"
    firebase login
    if ($LASTEXITCODE -eq 0) { Write-Ok "login berhasil" } else { Write-Tolak "login gagal. Coba: firebase login --no-localhost" }
}

function Langkah-4 {
    Write-Judul "4. Menyambungkan ke project Firebase"
    if ($ProjectId) {
        Write-Ok "project id: $ProjectId"
        if ($Check) { return }
        @{ projects = @{ default = $ProjectId } } | ConvertTo-Json | Set-Content -Path $Firebaserc -Encoding utf8
        Write-Ok "ditulis ke .firebaserc"
        return
    }
    Write-Tolak "FIREBASE_PROJECT_ID belum diisi — buat project di https://console.firebase.google.com"
    Write-Info "Nama disarankan: rara-travel  →  catat Project ID"
    Write-Info "Lalu: copy .env.firebase.example .env.firebase  dan isi FIREBASE_PROJECT_ID="
}

function Langkah-5 {
    Write-Judul "5. Menjalankan flutterfire configure"
    if ((Json-Ada) -and (Options-Isi)) { Write-Ok "google-services.json & firebase_options.dart sudah ada — dilewati"; return }
    if ($Check) {
        if (-not (Json-Ada)) { Write-Tolak "google-services.json belum ada" }
        if (-not (Options-Isi)) { Write-Tolak "firebase_options.dart masih stub" }
        return
    }
    if (-not $ProjectId) { Write-Tolak "FIREBASE_PROJECT_ID kosong (langkah 4 dulu)"; return }
    if (-not (Test-Cmd flutterfire)) {
        Write-Tolak "flutterfire tidak ada. Pasang Flutter SDK, lalu langkah 2."
        Write-Info "Manual: flutterfire configure --project=$ProjectId --platforms=android --android-package-name=$PackageAndroid --yes"
        return
    }
    Push-Location $Akar
    flutterfire configure --project=$ProjectId --platforms=android --android-package-name=$PackageAndroid --yes
    Pop-Location
    if (Json-Ada) { Write-Ok "android/app/google-services.json" } else { Write-Tolak "json masih belum ada" }
    if (Options-Isi) { Write-Ok "lib/firebase_options.dart terisi" } else { Write-Tolak "firebase_options.dart masih stub" }
}

function Langkah-6 {
    Write-Judul "6. Deploy Firestore rules + indexes"
    if ($Check) {
        Write-Info "akan men-deploy firestore.rules + firestore.indexes.json ke project $($ProjectId)"
        Write-Info "Syarat: database Firestore sudah dibuat (production, asia-southeast2)"
        return
    }
    if (-not (Test-Cmd firebase) -or -not $ProjectId) { Write-Tolak "firebase-tools / project id belum siap"; return }
    Write-Info "deploy rules & indexes ke $ProjectId…"
    Push-Location $Akar
    firebase deploy --only firestore:rules,firestore:indexes --project=$ProjectId
    $ok = $LASTEXITCODE
    Pop-Location
    if ($ok -eq 0) { Write-Ok "rules + indexes terpasang di server" } else {
        Write-Tolak "deploy gagal. Biasanya karena database belum dibuat."
        Write-Info "Console → Build → Firestore Database → Create database → Production → asia-southeast2"
    }
}

function Langkah-7 {
    Show-Sha
    Write-Judul "7. Checklist yang wajib di Firebase Console"
    Write-Info "CLI tidak bisa mengaktifkan ini — klik satu-satu (±15 menit):"
    Write-Host ""
    Write-Info "A. Authentication → Sign-in method → Phone Enable, Google Enable"
    Write-Info "B. Authentication → Settings → Phone numbers for testing  (+62 812 0000 0001 / 123456)"
    Write-Info "C. Build → Firestore Database → Create · Production · asia-southeast2"
    Write-Info "D. Project settings → Android app → Add fingerprint (SHA-1 + SHA-256)"
    Write-Info "E. App Check → Play Integrity + enforcement Firestore/Auth (sebelum rilis)"
    Write-Info "F. (Opsional, Blaze) Cloud Functions — pakai -Functions"
    Write-Host ""
    Write-Info "Uji: flutter pub get && flutter run"
}

function Langkah-Functions {
    Write-Judul "Cloud Functions (opsional, butuh paket Blaze)"
    if ($Check) { Write-Info "Sumber: functions_sample/"; return }
    if (-not (Test-Cmd firebase) -or -not $ProjectId) { Write-Tolak "firebase-tools / project id belum siap"; return }
    Push-Location (Join-Path $Akar "functions_sample")
    npm install
    Pop-Location
    Push-Location $Akar
    firebase deploy --only functions --project=$ProjectId
    $ok = $LASTEXITCODE
    Pop-Location
    if ($ok -eq 0) { Write-Ok "functions terpasang" } else { Write-Tolak "deploy functions gagal — naikkan ke Blaze dulu" }
}

# --- jalankan ---
Write-Judul "Penyiapan Firebase Rara Travel"
if ($Check) { Write-Host "Mode periksa: tidak ada yang diubah." -ForegroundColor Yellow }
if ($Sha) { Show-Sha; exit 0 }

if (Ingin 1) { Langkah-1 }
if (Ingin 2) { Langkah-2 }
if (Ingin 3) { Langkah-3 }
if (Ingin 4) { Langkah-4 }
if (Ingin 5) { Langkah-5 }
if (Ingin 6) { Langkah-6 }
if (Ingin 7) { Langkah-7 }
if ($Functions) { Langkah-Functions }

Write-Host ""
if ($Gagal -eq 0) {
    Write-Host "SELESAI — berkas proyek siap." -ForegroundColor Green
    Write-Host "Sisa di Console (langkah 7): Auth Phone + Google, nomor uji, SHA, App Check."
} else {
    Write-Host "ADA YANG PERLU DIPERBAIKI — lihat tanda ✖ di atas." -ForegroundColor Red
    Write-Host "Panduan: PANDUAN_FIREBASE.md"
}
exit $Gagal
