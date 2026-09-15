#!/usr/bin/env bash
# appcheck_debug_token.sh — ambil token debug App Check dari HP tercolok.
#
# Dipakai SAAT PERTAMA KALI menyalakan enforcement App Check: build debug
# memakai AndroidProvider.debug dan mencetak token yang harus didaftarkan di
# Firebase Console agar HP development kamu tidak ikut terblokir.
#
# Syarat:
#   * adb tersedia (Android SDK platform-tools / bawaan Android Studio)
#   * HP tercolok USB + USB debugging aktif
#   * aplikasi debug SEDANG/SEMPAT dijalankan (flutter run --debug)
#
# Pemakaian:
#   bash tools/appcheck_debug_token.sh          # cari token di logcat
#   bash tools/appcheck_debug_token.sh --watch  # pantau logcat langsung
#
# Setelah token terlihat:
#   Firebase Console → App Check → tab "Debug tokens" (atau menu aplikasi →
#   Manage debug tokens) → tempel token → Simpan.
set -euo pipefail

if ! command -v adb >/dev/null 2>&1; then
  echo "❌ adb tidak ditemukan. Install Android SDK platform-tools,"
  echo "   atau pakai adb bawaan Android Studio:"
  echo "   \"\$HOME/Android/Sdk/platform-tools/adb\" (Linux/Mac)"
  echo "   C:\\Users\\KAMU\\AppData\\Local\\Android\\Sdk\\platform-tools\\adb.exe (Windows)"
  exit 1
fi

if ! adb devices | grep -qw 'device'; then
  echo "❌ Tidak ada HP terdeteksi. Colok kabel + aktifkan USB debugging,"
  echo "   lalu izinkan prompt 'Allow USB debugging' di HP."
  exit 1
fi

pola='app.?check|debug.?(secret|token)'

if [ "${1:-}" = "--watch" ]; then
  echo "Memantau logcat — jalankan app (flutter run) lalu buka aplikasinya."
  echo "Token muncul sebagai baris panjang. Tekan Ctrl+C untuk berhenti."
  exec adb logcat | grep -iE --line-buffered "$pola"
fi

echo "Membaca logcat yang sudah ada…"
hasil="$(adb logcat -d | grep -iE "$pola" | tail -20 || true)"
if [ -n "$hasil" ]; then
  echo "✅ Kandidat baris token (salin string panjangnya):"
  echo "$hasil"
else
  echo "⚠️  Belum ada baris App Check di logcat."
  echo "   1) Jalankan app debug dulu :  flutter run"
  echo "   2) Ulangi perintah ini, atau pakai --watch untuk memantau langsung."
fi
