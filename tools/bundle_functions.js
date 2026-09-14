#!/usr/bin/env node
/**
 * tools/bundle_functions.js — menggabungkan setiap Edge Function menjadi SATU
 * berkas agar bisa ditempel langsung di Supabase Dashboard tanpa CLI.
 *
 * Latar belakang: di Dashboard, setiap fungsi diunggah tersendiri dan tidak
 * bisa mengimpor `../_shared/*.ts` milik fungsi lain. Skrip ini membundel
 * `supabase/functions/<nama>/index.ts` + seluruh `_shared` yang dipakainya
 * menjadi `supabase/deploy-dashboard/<nama>.ts` (satu berkas, siap tempel).
 *
 * Pakai:
 *   node tools/bundle_functions.js            # semua fungsi
 *   node tools/bundle_functions.js create-booking
 *
 * Butuh esbuild (0.28+), diambil dari node_modules repo, /home/user/.tools,
 * atau PATH. Hasilnya diuji lewat:
 *   E2E_FUNCTIONS_DIR=supabase/deploy-dashboard node tools/e2e/run_e2e.mts
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const REPO = path.resolve(import.meta.dirname, "..");
const SUMBER = path.join(REPO, "supabase", "functions");
const TUJUAN = path.join(REPO, "supabase", "deploy-dashboard");

/** Muat esbuild: dari node_modules repo, /home/user/.tools, lalu PATH. */
async function muatEsbuild() {
  const kandidat = [
    "esbuild",
    path.join(REPO, "node_modules", "esbuild", "lib", "main.js"),
    "/home/user/.tools/node_modules/esbuild/lib/main.js",
  ];
  for (const kandidatNama of kandidat) {
    try {
      const mod = await import(
        kandidatNama.startsWith("/") ? pathToFileURL(kandidatNama).href : kandidatNama
      );
      if (mod.build) return { build: mod.build };
    } catch {
      /* coba kandidat berikutnya */
    }
  }
  // Cadangan terakhir: perintah `esbuild` di PATH (Windows memakai shell).
  return {
    build: async (opsi) => {
      const args = [
        opsi.entryPoints[0],
        "--bundle",
        `--format=${opsi.format}`,
        `--platform=${opsi.platform}`,
        `--target=${opsi.target}`,
        "--legal-comments=none",
        "--charset=utf8",
        `--banner:js=${opsi.banner.js}`,
        `--outfile=${opsi.outfile}`,
      ];
      execFileSync("esbuild", args, {
        stdio: ["ignore", "ignore", "pipe"],
        shell: process.platform === "win32",
      });
    },
  };
}

const daftarFungsi = () =>
  readdirSync(SUMBER, { withFileTypes: true })
    .filter((d) => d.isDirectory() && d.name !== "_shared")
    .map((d) => d.name)
    .filter((nama) => {
      try {
        return statSync(path.join(SUMBER, nama, "index.ts")).isFile();
      } catch {
        return false;
      }
    })
    .sort();

const diminta = process.argv.slice(2).filter((a) => !a.startsWith("-"));
const daftar = diminta.length ? diminta : daftarFungsi();

mkdirSync(TUJUAN, { recursive: true });
const esbuild = await muatEsbuild();
let gagal = 0;

for (const nama of daftar) {
  const masuk = path.join(SUMBER, nama, "index.ts");
  const keluar = path.join(TUJUAN, `${nama}.ts`);
  const banner = [
    `// ===========================================================================`,
    `// ${nama}.ts — berkas SIAP TEMPEL untuk Supabase Dashboard (tanpa CLI).`,
    `//`,
    `// Dihasilkan otomatis dari supabase/functions/${nama}/index.ts + _shared/*.ts`,
    `// oleh tools/bundle_functions.js. JANGAN diedit manual — ubah berkas asli lalu`,
    `// buat ulang:  node tools/bundle_functions.js ${nama}`,
    `//`,
    `// Cara pakai: Dashboard → Edge Functions → Deploy a new function → tempel isi`,
    `// berkas ini, matikan "Verify JWT", lalu Deploy. Rinciannya: MIGRASI_SUPABASE.md §2.5.`,
    `// ===========================================================================`,
  ].join("\n");

  try {
    await esbuild.build({
      entryPoints: [masuk],
      outfile: keluar,
      bundle: true,
      format: "esm",
      platform: "neutral",
      target: "es2022",
      legalComments: "none",
      charset: "utf8",
      banner: { js: banner },
      logLevel: "silent",
    });
    const ukuran = statSync(keluar).size;
    console.log(
      `OK    ${nama.padEnd(22)} → ${path.relative(REPO, keluar)} (${(ukuran / 1024).toFixed(1)} KB)`,
    );
  } catch (error) {
    gagal = 1;
    console.error(
      `GAGAL ${nama}: ${String(error.stderr ?? error.message).trim().split("\n")[0]}`,
    );
  }
}

if (gagal) {
  console.error("\nAda fungsi yang gagal dibundel.");
  process.exit(1);
}
console.log(`\n${daftar.length} berkas siap tempel ada di ${path.relative(REPO, TUJUAN)}/`);
