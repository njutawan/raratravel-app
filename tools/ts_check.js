#!/usr/bin/env node
/**
 * Verifikasi statis Edge Function (Deno/TypeScript) tanpa memasang Deno/Supabase CLI.
 *
 * Yang diperiksa:
 *   1. Setiap impor relatif menunjuk berkas yang benar-benar ada.
 *      Deno mewajibkan ekstensi (.ts) dan TIDAK menebak nama berkas seperti Node —
 *      impor tanpa ekstensi hanya ketahuan saat deploy.
 *   2. Setiap nama yang diimpor benar-benar diekspor berkas tujuan
 *      (`import { rpc } from "../_shared/db.ts"` padahal namanya `callRpc`
 *      adalah kesalahan yang paling sering terjadi).
 *   3. Berkas dalam memakai jalur relatif — Deno tidak punya node_modules
 *      kecuali lewat specifier `npm:`.
 *
 * Pemakaian (dari akar repositori):
 *   node tools/ts_check.js            # periksa seluruh supabase/functions
 *   node tools/ts_check.js supabase/functions/_shared
 *
 * Kode keluar 1 bila ada masalah, 0 bila bersih.
 */
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const target = process.argv[2]
  ? path.resolve(process.cwd(), process.argv[2])
  : path.join(ROOT, "supabase", "functions");

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (/\.tsx?$/.test(entry.name)) out.push(full);
  }
  return out;
}

/** Nama-nama yang diekspor sebuah berkas. */
function exportsOf(file) {
  const src = stripComments(fs.readFileSync(file, "utf8"));
  const names = new Set();
  let star = false;

  const polaFungsi = /export\s+(?:async\s+)?(?:function|const|let|var|class|interface|type|enum)\s+([A-Za-z0-9_$]+)/g;
  for (const m of src.matchAll(polaFungsi)) names.add(m[1]);

  // export { a, b as c } [from "..."]
  for (const m of src.matchAll(/export\s*(?:type\s*)?\{([^}]*)\}/g)) {
    for (const bagian of m[1].split(",")) {
      const bersih = bagian.trim().replace(/^type\s+/, "");
      if (!bersih) continue;
      const alias = bersih.split(/\s+as\s+/);
      names.add((alias[1] || alias[0]).trim());
    }
  }

  if (/export\s*\*\s*from/.test(src)) star = true;
  if (/export\s+default/.test(src)) names.add("default");

  return { names, star };
}

function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");
}

/** Daftar impor sebuah berkas: {specifier, names[], line} */
function importsOf(file) {
  const src = fs.readFileSync(file, "utf8");
  const hasil = [];
  const pola = /(?:^|\n)\s*(?:import|export)\s+(?:type\s+)?([\s\S]*?)\s*from\s*["']([^"']+)["']/g;
  for (const m of src.matchAll(pola)) {
    const klausa = m[1].trim();
    const specifier = m[2];
    const names = [];
    const kurung = klausa.match(/\{([^}]*)\}/);
    if (kurung) {
      for (const bagian of kurung[1].split(",")) {
        const bersih = bagian.trim().replace(/^type\s+/, "");
        if (!bersih) continue;
        const alias = bersih.split(/\s+as\s+/);
        names.push(alias[0].trim());
      }
    }
    const line = src.slice(0, m.index).split("\n").length;
    hasil.push({ specifier, names, line });
  }
  return hasil;
}

const masalah = [];
const statistik = { berkas: 0, impor: 0, npm: 0 };
const semua = walk(target);
const sudahPeriksa = new Map();

for (const file of semua) {
  statistik.berkas++;
  for (const impor of importsOf(file)) {
    statistik.impor++;
    const relatif = impor.specifier.startsWith(".");
    const tampil = path.relative(ROOT, file);

    if (!relatif) {
      // Deno: hanya https:, npm:, jsr:, node: yang sah.
      if (/^(npm|jsr|node|https?):/.test(impor.specifier)) {
        statistik.npm++;
        continue;
      }
      masalah.push(`${tampil}:${impor.line} → specifier tanpa skema: "${impor.specifier}" (Deno butuh npm:/jsr:/https:)`);
      continue;
    }

    const tujuan = path.resolve(path.dirname(file), impor.specifier);
    if (!fs.existsSync(tujuan)) {
      masalah.push(`${tampil}:${impor.line} → berkas tidak ditemukan: "${impor.specifier}"`);
      continue;
    }

    if (impor.names.length === 0) continue;
    if (!sudahPeriksa.has(tujuan)) sudahPeriksa.set(tujuan, exportsOf(tujuan));
    const { names, star } = sudahPeriksa.get(tujuan);

    for (const nama of impor.names) {
      if (nama.startsWith("*") || nama === "") continue;
      if (!names.has(nama)) {
        if (star) continue; // re-export (*) tidak dapat dilacak statis
        masalah.push(
          `${tampil}:${impor.line} → "${nama}" tidak diekspor oleh ${path.relative(ROOT, tujuan)}`
        );
      }
    }
  }
}

console.log(`Berkas diperiksa : ${statistik.berkas}`);
console.log(`Impor diperiksa  : ${statistik.impor} (${statistik.npm} dari npm:/jsr:/https:)`);
if (masalah.length) {
  console.log("\nMASALAH:");
  for (const m of masalah) console.log(" -", m);
  console.log(`\nTS GAGAL (${masalah.length} masalah)`);
  process.exit(1);
}
console.log("\nTS OK (impor relatif + nama ekspor cocok)");
