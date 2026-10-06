/**
 * Uji aturan keamanan Firestore (firestore.rules) di Firestore Emulator.
 *
 * Dijalankan CI (.github/workflows/backend-check.yml) dengan:
 *   npm install --no-save firebase-tools @firebase/rules-unit-testing firebase
 *   npx firebase emulators:exec --only firestore --project demo-raratravel \
 *     "node tools/firestore/rules_test.mjs"
 *
 * Tujuan: memastikan klaim di LAPORAN_KEAMANAN.md (H-1) benar-benar berlaku —
 * pesanan terikat pada pemiliknya, tidak bisa dititipkan ke akun orang lain,
 * dan kepemilikannya tidak bisa dialihkan — SEBELUM rules dipublikasikan.
 *
 * Aturan yang diuji sama persis dengan yang ada di firestore.rules; kalau
 * salah satu gagal, JANGAN publish rules-nya.
 */
import { readFileSync, writeFileSync } from "node:fs";

import { initializeTestEnvironment } from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  updateDoc,
} from "firebase/firestore";

const PROYEK = process.env.GCLOUD_PROJECT ?? "demo-raratravel";

const testEnv = await initializeTestEnvironment({
  projectId: PROYEK,
  firestore: { rules: readFileSync("firestore.rules", "utf8") },
});

/** Harapan: operasi DITOLAK oleh rules. */
async function ditolak(promise, keterangan) {
  try {
    await promise;
  } catch {
    return; // bagus: ditolak
  }
  throw new Error(`seharusnya DITOLAK, tapi berhasil — ${keterangan}`);
}

/** Harapan: operasi DIIZINKAN oleh rules. */
async function diizinkan(promise, keterangan) {
  try {
    await promise;
  } catch (e) {
    throw new Error(`seharusnya DIIZINKAN, tapi ditolak — ${keterangan}: ${e?.message ?? e}`);
  }
}

const hasil = [];
/** Ringkasan bersih (tanpa derau emulator) → dibaca CI untuk anotasi. */
const laporan = [];
async function uji(nama, fn) {
  await testEnv.clearFirestore();
  try {
    await fn();
    console.log(`  OK    ${nama}`);
    laporan.push(`OK    ${nama}`);
    hasil.push(true);
  } catch (e) {
    const sebab = String(e?.message ?? e).replace(/\s+/g, " ");
    const jejak = String(e?.stack ?? "")
      .split("\n")
      .slice(1, 4)
      .map((b) => b.trim())
      .join(" | ");
    console.log(`  GAGAL ${nama}\n        ${sebab}`);
    laporan.push(`GAGAL ${nama}`);
    laporan.push(`  SEBAB: ${sebab}`);
    if (jejak) laporan.push(`  JEJAK: ${jejak}`);
    hasil.push(false);
  }
}

/** Dokumen pesanan valid milik [uid] dengan kode [kode]. */
function pesanan(uid, kode, tambahan = {}) {
  return {
    userId: uid,
    kode,
    asal: "Jember",
    tujuan: "Surabaya",
    tanggal: "2026-10-20",
    jam: "06.00",
    kursi: 1,
    totalHarga: 450000,
    status: "Menunggu Konfirmasi",
    createdAt: "2026-10-06T00:00:00.000Z",
    ...tambahan,
  };
}

const budi = testEnv.authenticatedContext("budi");
const sari = testEnv.authenticatedContext("sari");
const tamu = testEnv.unauthenticatedContext();

// ---------------------------------------------------------------- profil user
await uji("users: pemilik boleh tulis & baca profilnya", async () => {
  await diizinkan(
    setDoc(doc(budi.firestore(), "users/budi"), { uid: "budi", name: "Budi" }),
    "set profil sendiri",
  );
  await diizinkan(
    getDoc(doc(budi.firestore(), "users/budi")),
    "baca profil sendiri",
  );
});

await uji("users: profil orang lain DITOLAK", async () => {
  // Profil sari dibuat oleh sari sendiri (dokumen users/{uid} hanya boleh
  // disentuh pemiliknya) — lalu dipastikan budi tidak bisa membacanya.
  await setDoc(doc(sari.firestore(), "users/sari"), { uid: "sari", name: "Sari" });
  await diizinkan(getDoc(doc(sari.firestore(), "users/sari")), "baca profil sendiri");
  await ditolak(getDoc(doc(budi.firestore(), "users/sari")), "baca profil orang lain");
  await ditolak(
    setDoc(doc(budi.firestore(), "users/sari"), { uid: "sari", name: "Budi" }),
    "timpa profil orang lain",
  );
});

// ---------------------------------------------------------------- buat pesanan
await uji("bookings: buat pesanan sendiri (kode = id dokumen) DIIZINKAN", async () => {
  await diizinkan(
    setDoc(doc(budi.firestore(), "bookings/RARA-AAA111"), pesanan("budi", "RARA-AAA111")),
    "create pesanan sendiri",
  );
});

await uji("bookings: titip pesanan ke akun orang lain DITOLAK (H-1)", async () => {
  await ditolak(
    setDoc(doc(sari.firestore(), "bookings/RARA-PALSU1"), pesanan("budi", "RARA-PALSU1")),
    "userId bukan milik pengirim",
  );
});

await uji("bookings: kode berbeda dari id dokumen DITOLAK", async () => {
  await ditolak(
    setDoc(doc(budi.firestore(), "bookings/RARA-BBB222"), pesanan("budi", "RARA-LAIN99")),
    "kode ≠ id dokumen",
  );
});

await uji("bookings: tanpa login DITOLAK", async () => {
  await ditolak(
    setDoc(doc(tamu.firestore(), "bookings/RARA-TAMU01"), pesanan("budi", "RARA-TAMU01")),
    "create tanpa auth",
  );
});

// ---------------------------------------------------------------- baca & hapus
await uji("bookings: baca pesanan sendiri DIIZINKAN, pesanan orang lain DITOLAK", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-CCC333"), pesanan("budi", "RARA-CCC333"));
  await diizinkan(getDoc(doc(budi.firestore(), "bookings/RARA-CCC333")), "baca sendiri");
  await ditolak(getDoc(doc(sari.firestore(), "bookings/RARA-CCC333")), "baca milik orang lain");
});

await uji("bookings: hapus pesanan orang lain DITOLAK, milik sendiri DIIZINKAN", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-DDD444"), pesanan("budi", "RARA-DDD444"));
  await ditolak(deleteDoc(doc(sari.firestore(), "bookings/RARA-DDD444")), "hapus milik orang lain");
  await diizinkan(deleteDoc(doc(budi.firestore(), "bookings/RARA-DDD444")), "hapus milik sendiri");
});

// ---------------------------------------------------------------- ubah pesanan
await uji("bookings: pemilik boleh mengubah status", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-EEE555"), pesanan("budi", "RARA-EEE555"));
  await diizinkan(
    updateDoc(doc(budi.firestore(), "bookings/RARA-EEE555"), { status: "Dibatalkan" }),
    "ubah status sendiri",
  );
});

await uji("bookings: mengubah userId (alih kepemilikan) DITOLAK", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-FFF666"), pesanan("budi", "RARA-FFF666"));
  await ditolak(
    updateDoc(doc(budi.firestore(), "bookings/RARA-FFF666"), { userId: "sari" }),
    "alihkan kepemilikan",
  );
});

await uji("bookings: mengubah kode DITOLAK", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-GGG777"), pesanan("budi", "RARA-GGG777"));
  await ditolak(
    updateDoc(doc(budi.firestore(), "bookings/RARA-GGG777"), { kode: "RARA-BARU99" }),
    "ubah kode",
  );
});

await uji("bookings: mengubah pesanan orang lain DITOLAK", async () => {
  await setDoc(doc(budi.firestore(), "bookings/RARA-HHH888"), pesanan("budi", "RARA-HHH888"));
  await ditolak(
    updateDoc(doc(sari.firestore(), "bookings/RARA-HHH888"), { status: "Selesai" }),
    "ubah milik orang lain",
  );
});

// ---------------------------------------------------------------- rate limit
await uji("rateLimits: klien tidak boleh baca/tulis (hanya server)", async () => {
  await ditolak(getDoc(doc(budi.firestore(), "rateLimits/+62812")), "baca hitungan");
  await ditolak(
    setDoc(doc(budi.firestore(), "rateLimits/+62812"), { count: 0 }),
    "reset hitungan",
  );
  await ditolak(
    setDoc(doc(tamu.firestore(), "rateLimits/+62813"), { count: 0 }),
    "tulis tanpa login",
  );
});

// ---------------------------------------------------------------- ringkasan
const lulus = hasil.filter(Boolean).length;
console.log(`\n${lulus}/${hasil.length} pengujian rules lulus`);
laporan.push("", `${lulus}/${hasil.length} pengujian rules lulus`);
if (lulus !== hasil.length) {
  console.log("❌ firestore.rules TIDAK aman untuk dipublikasikan.");
  laporan.push("❌ firestore.rules TIDAK aman untuk dipublikasikan.");
} else {
  console.log("✅ firestore.rules sesuai harapan — aman dipublikasikan ke Firebase Console.");
  laporan.push("✅ firestore.rules sesuai harapan — aman dipublikasikan ke Firebase Console.");
}
writeFileSync("rules-result.txt", laporan.join("\n") + "\n");
await testEnv.cleanup();
if (lulus !== hasil.length) process.exit(1);
