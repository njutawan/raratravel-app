#!/usr/bin/env bash
# check_firestore_rules.sh — uji firestore.rules di Firestore Emulator (LOKAL).
#
# Sama persis dengan job "Aturan Firestore (emulator)" di CI. Jalankan ini
# sebelum mem-publish rules ke Firebase Console, atau setelah mengubah
# firestore.rules.
#
# Kebutuhan: Node.js 20+, Java 17+ (emulator Firestore jalan di JVM —
# biasanya sudah ada bersama Android Studio), dan koneksi internet (unduhan
# emulator ±60 MB, sekali saja).
#
# Pemakaian:
#   bash tools/check_firestore_rules.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
fail() { printf '❌ %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { fail "Node.js tidak ditemukan."; exit 1; }
if ! command -v java >/dev/null 2>&1; then
  fail "Java tidak ditemukan — emulator Firestore membutuhkannya."
  echo "   Android Studio menyertakan Java: set JAVA_HOME ke"
  echo "   .../Android Studio/jbr lalu jalankan ulang skrip ini."
  exit 1
fi

[ -f firestore.rules ] || { fail "firestore.rules tidak ada di $ROOT."; exit 1; }

echo "══════════════════════════════════════════════════════════"
echo " Rara Travel — Uji aturan Firestore di emulator"
echo "══════════════════════════════════════════════════════════"
echo ""

if [ ! -d node_modules/firebase-tools ] || [ ! -d node_modules/@firebase/rules-unit-testing ]; then
  echo "Memasang firebase-tools + SDK uji (sekali saja)…"
  npm install --no-save firebase-tools@15 firebase@12 @firebase/rules-unit-testing@5
fi

echo "Menjalankan emulator (unduhan pertama bisa beberapa menit)…"
echo ""
if npx firebase emulators:exec --only firestore --project demo-raratravel \
     "node tools/firestore/rules_test.mjs"; then
  echo ""
  ok "firestore.rules sesuai harapan — aman dipublikasikan ke Firebase Console."
  echo "   Langkah publish: lihat RILIS_PRODUKSI.md poin 1."
  [ -f rules-result.txt ] && echo "   Ringkasan: rules-result.txt"
else
  echo ""
  fail "Ada pengujian yang gagal — JANGAN publish rules ini."
  echo "   Perbaiki firestore.rules lalu jalankan skrip ini lagi."
  exit 1
fi
