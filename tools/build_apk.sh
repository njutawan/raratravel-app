#!/usr/bin/env bash
# build_apk.sh — build APK/AAB Rara Travel sekali perintah.
#
# Pemakaian (dari mana saja):
#   bash tools/build_apk.sh                 # APK release universal (ditandatangani keystore rilis)
#   bash tools/build_apk.sh --split         # APK release per-arsitektur (lebih kecil, utk dibagi)
#   bash tools/build_apk.sh --aab           # App Bundle untuk Play Store
#   bash tools/build_apk.sh --debug         # APK debug untuk testing
#   bash tools/build_apk.sh --obfuscate     # tambah obfuscation (disarankan utk rilis)
#
# Hasil disalin ke folder apk/ di akar repo (sudah di-.gitignore).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="release"
SPLIT=0
AAB=0
OBFUS=0
for a in "$@"; do
  case "$a" in
    --debug) MODE="debug" ;;
    --split) SPLIT=1 ;;
    --aab) AAB=1 ;;
    --obfuscate) OBFUS=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Flag tidak dikenal: $a"; exit 2 ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "❌ Flutter tidak ditemukan. Install dulu: https://docs.flutter.dev/get-started/install"
  echo "   Lalu pastikan 'flutter doctor' hijau (Android toolchain + JDK 17)."
  exit 1
fi

EXTRA=()
if [ "$OBFUS" -eq 1 ]; then
  EXTRA+=(--obfuscate --split-debug-info=build/symbols)
fi

echo "▶ flutter pub get"
flutter pub get

OUT="apk"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M)"

if [ "$AAB" -eq 1 ]; then
  echo "▶ Build AAB release…"
  flutter build appbundle --release "${EXTRA[@]}"
  cp build/app/outputs/bundle/release/app-release.aab "$OUT/raratravel-$STAMP.aab"
  echo "✅ $OUT/raratravel-$STAMP.aab"
elif [ "$MODE" = "debug" ]; then
  echo "▶ Build APK debug…"
  flutter build apk --debug
  cp build/app/outputs/flutter-apk/app-debug.apk "$OUT/raratravel-debug-$STAMP.apk"
  echo "✅ $OUT/raratravel-debug-$STAMP.apk"
elif [ "$SPLIT" -eq 1 ]; then
  echo "▶ Build APK release split-per-ABI…"
  flutter build apk --release --split-per-abi "${EXTRA[@]}"
  for f in build/app/outputs/flutter-apk/app-*-release.apk; do
    n="$(basename "$f" .apk)"; n="${n/app-/}"
    cp "$f" "$OUT/raratravel-$n-$STAMP.apk"
    echo "✅ $OUT/raratravel-$n-$STAMP.apk"
  done
else
  echo "▶ Build APK release universal…"
  flutter build apk --release "${EXTRA[@]}"
  cp build/app/outputs/flutter-apk/app-release.apk "$OUT/raratravel-$STAMP.apk"
  echo "✅ $OUT/raratravel-$STAMP.apk"
fi

echo ""
echo "Selesai. Install ke HP: adb install $OUT/<file>.apk  (atau kirim via WA/GDrive)."
[ "$OBFUS" -eq 1 ] && echo "⚠️  Simpan folder build/symbols/ untuk membaca crash ter-obfuscate."
true
