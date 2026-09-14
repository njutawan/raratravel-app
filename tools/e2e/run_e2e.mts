/**
 * Uji end-to-end Edge Function: kode TypeScript benar-benar DIJALANKAN.
 *
 * Kenapa perlu: `supabase functions deploy` baru bisa dilakukan setelah Deno
 * tersedia, padahal kesalahan seperti nama argumen RPC yang salah, format
 * kunci publik Firebase, atau bentuk balasan yang tidak cocok hanya terlihat
 * saat fungsi berjalan. Harness ini menjalankan fungsi yang sama di Node 22
 * (dukungan TypeScript bawaan) di atas:
 *
 *   * PostgreSQL 16 sungguhan  → tools/e2e/pg_bridge.py (tiruan PostgREST+Storage)
 *   * kunci RS256 buatan sendiri → token Firebase ditandatangani seperti asli
 *   * FCM, OAuth2 Google, dan Snap Midtrans ditiru
 *
 * Pemakaian (dari akar repositori):
 *   /tmp/venv/bin/python -c "import pgserver"     # pastikan terpasang
 *   node tools/e2e/run_e2e.mts
 *
 * Kode keluar 1 bila ada skenario yang gagal.
 */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer } from "node:net";
import { createPublicKey, createSign, generateKeyPairSync, type KeyObject } from "node:crypto";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const REPO = path.resolve(import.meta.dirname, "..", "..");
const FUNCTIONS = path.join(REPO, "supabase", "functions");
const PYTHON = existsSync("/tmp/venv/bin/python") ? "/tmp/venv/bin/python" : "python3";
const PROJECT = "raratravel-uji";
const KID = "uji-kid";

// ---------------------------------------------------------------------------
// Kunci RS256 + kunci publik dalam bentuk JWK
// ---------------------------------------------------------------------------
let privateKey: KeyObject;
let publicJwk: { kty: string; n: string; e: string };

function buatKunci(): void {
  const pasangan = generateKeyPairSync("rsa", { modulusLength: 2048 });
  privateKey = pasangan.privateKey;
  const jwk = createPublicKey(pasangan.privateKey).export({ format: "jwk" }) as { kty: string; n: string; e: string };
  publicJwk = { kty: jwk.kty, n: jwk.n, e: jwk.e };
}

function pem(key: KeyObject): string {
  return key.export({ type: "pkcs8", format: "pem" }).toString();
}

/** Firebase ID token seperti aslinya (RS256, kid dari JWKS). */
function tokenFirebase(uid: string, opsi: { kedaluwarsa?: boolean; aud?: string; phone?: string } = {}): string {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", kid: KID, typ: "JWT" };
  const payload = {
    iss: `https://securetoken.google.com/${PROJECT}`,
    aud: opsi.aud ?? PROJECT,
    sub: uid,
    user_id: uid,
    iat: now - 30,
    exp: opsi.kedaluwarsa ? now - 10 : now + 3600,
    auth_time: now - 60,
    phone_number: opsi.phone,
    firebase: { sign_in_provider: "phone", identities: {} },
  };
  const b64 = (nilai: unknown) => Buffer.from(JSON.stringify(nilai)).toString("base64url");
  const badan = `${b64(header)}.${b64(payload)}`;
  const tanda = createSign("RSA-SHA256").update(badan).sign(privateKey, "base64url");
  return `${badan}.${tanda}`;
}

// ---------------------------------------------------------------------------
// Tiruan layanan luar (Google, FCM, Midtrans)
// ---------------------------------------------------------------------------
function balasanJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "cache-control": "max-age=3600" },
  });
}

function pasangShimFetch(): void {
  const asli = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;

    if (url.includes("service_accounts/v1/jwk") || url.includes("metadata/x509")) {
      return balasanJson({ keys: [{ ...publicJwk, alg: "RS256", use: "sig", kid: KID }] });
    }
    if (url.startsWith("https://oauth2.googleapis.com/token")) {
      return balasanJson({ access_token: "uji-access-token", expires_in: 3600, token_type: "Bearer" });
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      const body = JSON.parse(String(init?.body ?? "{}")) as { message?: { token?: string } };
      const tujuan = body.message?.token ?? "";
      if (tujuan.startsWith("mati")) {
        // Token basi (app di-uninstall) → FCM membalas 404 UNREGISTERED.
        return balasanJson(
          {
            error: {
              status: "NOT_FOUND",
              message: "Requested entity was not found.",
              details: [{ errorCode: "UNREGISTERED" }],
            },
          },
          404,
        );
      }
      return balasanJson({ name: `projects/${PROJECT}/messages/1` });
    }
    if (url.includes("midtrans.com")) {
      return balasanJson({
        token: "snap-uji",
        redirect_url: "https://app.sandbox.midtrans.com/snap/v2/vtweb/snap-uji",
      });
    }
    return asli(input as RequestInfo, init);
  }) as typeof fetch;
}

// ---------------------------------------------------------------------------
// Shim Deno (hanya Deno.serve + Deno.env.get yang dipakai)
// ---------------------------------------------------------------------------
type Handler = (req: Request) => Promise<Response> | Response;

function pasangShimDeno(rawat: (h: Handler) => void): void {
  (globalThis as Record<string, unknown>).Deno = {
    env: { get: (nama: string) => process.env[nama] },
    serve: (h: Handler) => rawat(h),
  };
}

// ---------------------------------------------------------------------------
// Menyalakan tiruan Supabase
// ---------------------------------------------------------------------------
let bridge: ChildProcessWithoutNullStreams | null = null;
let basis = "";

async function portBebas(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const alamat = server.address();
      const port = typeof alamat === "object" && alamat ? alamat.port : 0;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

async function nyalakanBridge(): Promise<void> {
  const port = await portBebas();
  bridge = spawn(PYTHON, [path.join(REPO, "tools", "e2e", "pg_bridge.py"), String(port)], {
    cwd: REPO,
    stdio: ["ignore", "pipe", "pipe"],
  }) as ChildProcessWithoutNullStreams;

  let keluaran = "";
  bridge.stderr.on("data", (buf) => process.stderr.write(`[bridge] ${buf}`));
  bridge.stdout.on("data", (buf) => {
    keluaran += buf.toString();
  });

  const batas = Date.now() + 120_000;
  while (Date.now() < batas) {
    if (keluaran.includes("READY")) {
      basis = `http://127.0.0.1:${port}`;
      return;
    }
    if (bridge.exitCode !== null) throw new Error(`bridge berhenti: ${keluaran}`);
    await delay(200);
  }
  throw new Error(`bridge tidak siap dalam 120 detik: ${keluaran}`);
}

async function sql(perintah: string): Promise<unknown> {
  const res = await globalThis.fetch(`${basis}/_test/sql`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sql: perintah }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`SQL gagal: ${JSON.stringify(data)}`);
  return data;
}

// ---------------------------------------------------------------------------
// Memuat & memanggil Edge Function
// ---------------------------------------------------------------------------
const cache = new Map<string, Handler>();
let versi = 0;

async function muatFungsi(nama: string): Promise<Handler> {
  const tersimpan = cache.get(nama);
  if (tersimpan) return tersimpan;

  let handler: Handler | null = null;
  pasangShimDeno((h) => {
    handler = h;
  });
  const berkas = path.join(FUNCTIONS, nama, "index.ts");
  await import(`${pathToFileURL(berkas).href}?v=${versi++}`);
  if (!handler) throw new Error(`Deno.serve tidak dipanggil oleh ${nama}`);
  cache.set(nama, handler);
  return handler;
}

interface Opsi {
  method?: string;
  query?: Record<string, string | number>;
  body?: unknown;
  token?: string | null;
  headers?: Record<string, string>;
}

async function panggil(
  nama: string,
  opsi: Opsi = {},
): Promise<{ status: number; json: any }> {
  const handler = await muatFungsi(nama);
  const url = new URL(`${basis}/functions/v1/${nama}`);
  for (const [k, v] of Object.entries(opsi.query ?? {})) url.searchParams.set(k, String(v));

  const headers = new Headers({ "Content-Type": "application/json", apikey: "uji-anon" });
  if (opsi.token) headers.set("Authorization", `Bearer ${opsi.token}`);
  for (const [k, v] of Object.entries(opsi.headers ?? {})) headers.set(k, v);

  const method = opsi.method ?? (opsi.body === undefined ? "GET" : "POST");
  const req = new Request(url, {
    method,
    headers,
    body: opsi.body === undefined || method === "GET" ? undefined : JSON.stringify(opsi.body),
  });

  const res = await handler(req);
  const teks = await res.text();
  let json: any = null;
  try {
    json = teks ? JSON.parse(teks) : null;
  } catch {
    json = teks;
  }
  return { status: res.status, json };
}

// ---------------------------------------------------------------------------
// Kerangka uji
// ---------------------------------------------------------------------------
const catatan: { nama: string; ok: boolean; pesan?: string }[] = [];

function tegas(kondisi: boolean, pesan: string, detail?: unknown): void {
  if (!kondisi) {
    throw new Error(`${pesan}${detail === undefined ? "" : ` → ${JSON.stringify(detail).slice(0, 400)}`}`);
  }
}

async function uji(nama: string, fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
    catatan.push({ nama, ok: true });
    console.log(`  OK   ${nama}`);
  } catch (err) {
    const pesan = err instanceof Error ? err.message : String(err);
    catatan.push({ nama, ok: false, pesan });
    console.log(`  GAGAL ${nama}\n        ${pesan}`);
  }
}

// ---------------------------------------------------------------------------
// Skenario
// ---------------------------------------------------------------------------
interface HasilPanggil {
  status: number;
  json: any;
}

async function buatPesanan(
  token: string,
  opsi: { seats?: number; hari?: number; promo?: string; clientTotal?: number; jam?: string } = {},
): Promise<HasilPanggil> {
  const tanggal = new Date(Date.now() + (opsi.hari ?? 3) * 86400_000).toISOString().slice(0, 10);
  return await panggil("create-booking", {
    token,
    body: {
      idempotency_key: `uji-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
      origin: "Surabaya",
      destination: "Jakarta",
      travel_date: tanggal,
      departure_time: opsi.jam ?? "06:00",
      seats: opsi.seats ?? 1,
      contact_name: "Pelanggan Uji",
      contact_phone: "081200000002",
      pickup_address: "Jl. Uji 1",
      dropoff_address: "Jl. Uji 2",
      payment_method: "Transfer Bank",
      ...(opsi.promo ? { promo_code: opsi.promo } : {}),
      ...(opsi.clientTotal !== undefined ? { client_total: opsi.clientTotal } : {}),
    },
  });
}

async function jalankanSkenario(): Promise<void> {
  const tokenStaf = tokenFirebase("uid-uji-staf", { phone: "+6281200000001" });
  const tokenPelanggan = tokenFirebase("uid-uji-pelanggan", { phone: "+6281200000002" });
  const tokenLain = tokenFirebase("uid-uji-bukan-staf", { phone: "+6281200000009" });

  await sql(`
    insert into public.users (firebase_uid, full_name, phone, role)
    values ('uid-uji-staf', 'Staf Uji', '+6281200000001', 'admin')
    on conflict (firebase_uid) do update set role = 'admin';
  `);

  let kode = ""; // pesanan utama (dibatalkan di akhir)
  let kodeBayar = ""; // pesanan untuk uji pembayaran manual
  let kodeMidtrans = ""; // pesanan untuk uji webhook Midtrans

  // ---- katalog publik -----------------------------------------------------
  await uji("search-routes: pencarian publik + pagination", async () => {
    const hasil = await panggil("search-routes", {
      query: { action: "search", origin: "Surabaya", destination: "Jakarta", passengers: 2, limit: 5 },
    });
    tegas(hasil.status === 200, "status harus 200", hasil);
    tegas(Number(hasil.json.total) >= 1, "total harus >= 1", hasil.json);
    const item = hasil.json.items?.[0];
    tegas(Boolean(item?.slug), "item harus punya slug", item);
    tegas(Array.isArray(item?.schedules) && item.schedules.length >= 1, "schedules harus terisi", item);
    tegas(typeof item.schedules[0].price === "number", "harga jadwal harus angka", item.schedules[0]);
  });

  await uji("search-routes: detail, kota, sewa, wisata", async () => {
    const cari = await panggil("search-routes", {
      query: { action: "search", origin: "Surabaya", destination: "Jakarta" },
    });
    const slug = cari.json.items[0].slug;
    const detail = await panggil("search-routes", { query: { action: "detail", key: slug } });
    tegas(detail.status === 200, "detail harus 200", detail);
    tegas(detail.json.route?.slug === slug, "slug harus sama", detail.json);

    const kota = await panggil("search-routes", { query: { action: "cities" } });
    tegas(kota.status === 200 && kota.json.items.length >= 10, "kota harus >= 10", kota.json);

    const sewa = await panggil("search-routes", { query: { action: "rentals" } });
    tegas(sewa.status === 200 && sewa.json.items.length >= 1, "paket sewa harus ada", sewa.json);

    const wisata = await panggil("search-routes", { query: { action: "tours" } });
    tegas(wisata.status === 200 && wisata.json.items.length >= 1, "paket wisata harus ada", wisata.json);
  });

  // ---- login & perangkat --------------------------------------------------
  await uji("auth-user-sync: token wajib & token rusak", async () => {
    const tanpaToken = await panggil("auth-user-sync", { body: { action: "sync" } });
    tegas(tanpaToken.status === 401, "tanpa token harus 401", tanpaToken);
    const tokenRusak = await panggil("auth-user-sync", { body: { action: "sync" }, token: "bukan.jwt.sah" });
    tegas(tokenRusak.status === 401, "token rusak harus 401 (bukan 500)", tokenRusak);
    const kedaluwarsa = await panggil("auth-user-sync", {
      body: { action: "sync" },
      token: tokenFirebase("uid-uji-kedaluwarsa", { kedaluwarsa: true }),
    });
    tegas(kedaluwarsa.status === 401, "token kedaluwarsa harus 401", kedaluwarsa);
    const audSalah = await panggil("auth-user-sync", {
      body: { action: "sync" },
      token: tokenFirebase("uid-uji-aud", { aud: "proyek-lain" }),
    });
    tegas(audSalah.status === 401, "audience lain harus 401", audSalah);
  });

  await uji("auth-user-sync: buat pengguna + perangkat (idempoten)", async () => {
    const pertama = await panggil("auth-user-sync", {
      token: tokenPelanggan,
      body: {
        action: "sync",
        full_name: "Pelanggan Uji",
        fcm_token: "fcm-hidup-1",
        platform: "android",
        app_version: "1.0.0+1",
      },
    });
    tegas(pertama.status === 200, "status 200", pertama);
    tegas(Boolean(pertama.json.user?.id), "harus mengembalikan user", pertama.json);
    tegas(pertama.json.is_new === true, "panggilan pertama = pengguna baru", pertama.json);
    tegas(pertama.json.is_staff === false, "pelanggan bukan staf", pertama.json);

    const kedua = await panggil("auth-user-sync", {
      token: tokenPelanggan,
      body: { action: "sync", fcm_token: "fcm-hidup-1", platform: "android" },
    });
    tegas(kedua.status === 200, "status 200", kedua);
    tegas(kedua.json.is_new === false, "panggilan kedua bukan pengguna baru", kedua.json);
    tegas(kedua.json.user.id === pertama.json.user.id, "user_id harus sama", kedua.json);

    const perangkat = await sql(
      "select count(*)::int as n from public.user_devices where fcm_token = 'fcm-hidup-1' and is_active",
    );
    tegas((perangkat as any)[0].n === 1, "perangkat tersimpan di user_devices", perangkat);
  });

  await uji("register-device: idempoten", async () => {
    const daftar = await panggil("register-device", {
      token: tokenPelanggan,
      body: { action: "register", fcm_token: "fcm-hidup-2", platform: "android" },
    });
    tegas(daftar.status === 200, "status 200", daftar);
    const ulang = await panggil("register-device", {
      token: tokenPelanggan,
      body: { action: "register", fcm_token: "fcm-hidup-2", platform: "android" },
    });
    tegas(ulang.status === 200, "pendaftaran ulang tetap 200", ulang);
    const baris = await sql("select count(*)::int as n from public.user_devices where fcm_token = 'fcm-hidup-2'");
    tegas((baris as any)[0].n === 1, "tidak boleh ada baris ganda", baris);
  });

  // ---- pemesanan ----------------------------------------------------------
  await uji("create-booking: harga & kursi dihitung server + idempotensi", async () => {
    const pertama = await buatPesanan(tokenPelanggan, { seats: 2, promo: "RARAHEMAT" });
    tegas([200, 201].includes(pertama.status), "harus 200/201", pertama);
    tegas(Boolean(pertama.json.booking?.kode), "kode pesanan harus ada", pertama.json);
    tegas(pertama.json.booking.status === "pending", "status awal pending", pertama.json.booking);
    tegas(pertama.json.booking.payment_status === "unpaid", "belum dibayar", pertama.json.booking);
    tegas(typeof pertama.json.pricing?.remaining_seats === "number", "sisa kursi harus ada", pertama.json);
    tegas(Number(pertama.json.booking.discount) === 50000, "plafon promo 50.000", pertama.json.booking);
    kode = pertama.json.booking.kode;

    // Permintaan ulang dengan kunci yang sama → pesanan yang sama, bukan baru.
    const payloadUlang = {
      action: undefined,
      idempotency_key: undefined as unknown as string,
    };
    const detail = await sql(`select idempotency_key from public.bookings where kode = '${kode}'`);
    payloadUlang.idempotency_key = (detail as any)[0].idempotency_key;

    const ulang = await buatUlang(payloadUlang.idempotency_key, tokenPelanggan);
    tegas(ulang.status === 200 || ulang.status === 201, "ulangan harus 200/201", ulang);
    tegas(ulang.json.idempotent === true, "harus ditandai idempotent", ulang.json);
    tegas(ulang.json.booking.kode === kode, "kode harus sama", ulang.json.booking);
  });

  await uji("create-booking: harga klien keliru ditolak (409 price_mismatch)", async () => {
    const hasil = await buatPesanan(tokenPelanggan, { clientTotal: 1000 });
    tegas(hasil.status === 409, "harus 409", hasil);
    tegas(hasil.json.error?.code === "price_mismatch", "kode price_mismatch", hasil.json);
    tegas(Number(hasil.json.error?.details?.expected_total) > 1000, "expected_total harus wajar", hasil.json);
  });

  await uji("create-booking: kursi melebihi kapasitas ditolak", async () => {
    const hasil = await buatPesanan(tokenPelanggan, { seats: 99 });
    tegas([400, 409].includes(hasil.status), "harus 400/409", hasil);
    tegas(
      ["validation_error", "seats_unavailable"].includes(hasil.json.error?.code),
      "kode harus validation_error/seats_unavailable",
      hasil.json,
    );
  });

  await uji("manage-booking: riwayat, detail, status bayar", async () => {
    const daftar = await panggil("manage-booking", { token: tokenPelanggan, body: { action: "list", limit: 10 } });
    tegas(daftar.status === 200, "status 200", daftar);
    tegas(daftar.json.total >= 1, "total >= 1", daftar.json);
    tegas(daftar.json.items.some((item: any) => item.kode === kode), "pesanan baru harus ada", daftar.json.items);

    const detail = await panggil("manage-booking", { token: tokenPelanggan, body: { action: "detail", kode } });
    tegas(detail.status === 200 && detail.json.booking.kode === kode, "detail harus cocok", detail.json);

    const bayar = await panggil("manage-booking", {
      token: tokenPelanggan,
      body: { action: "payment-status", kode },
    });
    tegas(bayar.status === 200, "status 200", bayar);
    tegas(Number(bayar.json.remaining_amount) > 0, "harus ada sisa tagihan", bayar.json);
  });

  await uji("manage-booking: admin hanya untuk staf (403)", async () => {
    const pelanggan = await panggil("manage-booking", { token: tokenPelanggan, body: { action: "admin-list" } });
    tegas(pelanggan.status === 403, "pelanggan harus 403", pelanggan);
    tegas(pelanggan.json.error?.code === "forbidden", "kode forbidden", pelanggan.json);

    const staf = await panggil("manage-booking", { token: tokenStaf, body: { action: "admin-list", limit: 5 } });
    tegas(staf.status === 200, "staf harus 200", staf);
    tegas(staf.json.total >= 1, "staf harus melihat pesanan", staf.json);
  });

  await uji("storage-sign: unggah bukti transfer + batas peran", async () => {
    const tautan = await panggil("storage-sign", {
      token: tokenPelanggan,
      body: { action: "upload-url", kind: "payment_proof", kode, filename: "bukti.jpg", content_type: "image/jpeg" },
    });
    tegas([200, 201].includes(tautan.status), "status 200/201", tautan);
    tegas(Boolean(tautan.json.upload_url), "harus ada upload_url", tautan.json);
    tegas(tautan.json.bucket === "payment-proofs", "bucket bukti transfer", tautan.json);

    const unggah = await globalThis.fetch(tautan.json.upload_url, {
      method: "PUT",
      headers: { "Content-Type": "image/jpeg" },
      body: new Uint8Array([1, 2, 3, 4]),
    });
    tegas(unggah.ok, "unggah ke tautan bertanda tangan harus berhasil", unggah.status);

    const unduh = await panggil("storage-sign", {
      token: tokenPelanggan,
      body: { action: "download-url", kind: "payment_proof", path: tautan.json.path },
    });
    tegas(unduh.status === 200 && Boolean(unduh.json.download_url), "tautan unduh harus ada", unduh.json);

    const gambarKatalog = await panggil("storage-sign", {
      token: tokenPelanggan,
      body: { action: "upload-url", kind: "route", filename: "rute.jpg" },
    });
    tegas(gambarKatalog.status === 403, "gambar katalog hanya untuk staf", gambarKatalog);
  });

  // ---- pembayaran ---------------------------------------------------------
  await uji("payment-intent: staf memverifikasi transfer manual", async () => {
    const pesanan = await buatPesanan(tokenPelanggan, { seats: 1 });
    tegas([200, 201].includes(pesanan.status), "pesanan dibuat", pesanan);
    kodeBayar = pesanan.json.booking.kode;

    const status = await panggil("manage-booking", {
      token: tokenPelanggan,
      body: { action: "payment-status", kode: kodeBayar },
    });
    const sisa = Number(status.json.remaining_amount);
    tegas(sisa > 0, "harus ada sisa tagihan", status.json);

    const pelangganCoba = await panggil("payment-intent", {
      token: tokenPelanggan,
      body: { action: "manual-confirm", kode: kodeBayar, amount: sisa },
    });
    tegas(pelangganCoba.status === 403, "pelanggan tidak boleh menandai lunas", pelangganCoba);

    const staf = await panggil("payment-intent", {
      token: tokenStaf,
      body: { action: "manual-confirm", kode: kodeBayar, amount: sisa, reference: "BCA-UJI-1", method: "Transfer Bank" },
    });
    tegas(staf.status === 200, "status 200", staf);
    tegas(staf.json.booking?.payment_status === "paid", "harus lunas", staf.json);

    const ulang = await panggil("payment-intent", {
      token: tokenStaf,
      body: { action: "manual-confirm", kode: kodeBayar, amount: sisa, reference: "BCA-UJI-1", method: "Transfer Bank" },
    });
    tegas(ulang.status === 200, "klik ganda staf tetap 200", ulang);
    tegas(ulang.json.already_settled === true, "klik ganda ditandai sudah tercatat", ulang.json);
  });

  await uji("payment-intent + payment-webhook: Midtrans (Snap ditiru)", async () => {
    const pesanan = await buatPesanan(tokenPelanggan, { seats: 1 });
    tegas([200, 201].includes(pesanan.status), "pesanan dibuat", pesanan);
    kodeMidtrans = pesanan.json.booking.kode;

    const tagihan = await panggil("payment-intent", {
      token: tokenPelanggan,
      body: { action: "create", kode: kodeMidtrans, provider: "midtrans" },
    });
    tegas([200, 201].includes(tagihan.status), "tagihan harus dibuat", tagihan);
    tegas(Boolean(tagihan.json.checkout_url), "harus menerima tautan bayar", tagihan.json);

    const baris = await sql(
      `select p.provider_reference, p.amount::text as amount from public.payments p
         join public.bookings b on b.id = p.booking_id
        where b.kode = '${kodeMidtrans}' and p.provider = 'midtrans'
        order by p.created_at desc limit 1`,
    );
    const reference = (baris as any)[0].provider_reference as string;
    const gross = Number((baris as any)[0].amount).toFixed(2);
    tegas(Boolean(reference), "referensi tagihan harus ada", baris);

    const { createHash } = await import("node:crypto");
    const tanda = createHash("sha512").update(`${reference}200${gross}midtrans-uji`).digest("hex");
    const notifikasi = {
      transaction_id: "tx-uji-1",
      order_id: reference,
      status_code: "200",
      gross_amount: gross,
      transaction_status: "settlement",
      signature_key: tanda,
    };

    const masuk = await panggil("payment-webhook", { query: { provider: "midtrans" }, body: notifikasi });
    tegas(masuk.status === 200, "webhook selalu 200", masuk);
    tegas(masuk.json.ok === true, "notifikasi sah harus diproses", masuk.json);
    tegas(masuk.json.booking?.payment_status === "paid", "pesanan harus lunas", masuk.json);

    const duplikat = await panggil("payment-webhook", { query: { provider: "midtrans" }, body: notifikasi });
    tegas(duplikat.json.duplicate === true, "callback ulang harus duplicate", duplikat.json);

    const palsu = await panggil("payment-webhook", {
      query: { provider: "midtrans" },
      body: { ...notifikasi, transaction_id: "tx-uji-2", signature_key: "palsu" },
    });
    tegas(palsu.status === 200, "tetap 200 agar provider tidak mengulang", palsu);
    tegas(palsu.json.ok !== true, "tanda tangan palsu tidak boleh diterima", palsu);
  });

  // ---- notifikasi ---------------------------------------------------------
  await uji("notify-booking-status: rahasia webhook + token basi", async () => {
    const tanpaRahasia = await panggil("notify-booking-status", { body: { drain: true } });
    tegas(tanpaRahasia.status === 401 || tanpaRahasia.status === 403, "tanpa rahasia harus ditolak", tanpaRahasia);

    const tokenMati = "mati-token-abcdefghij";
    const daftar = await panggil("register-device", {
      token: tokenPelanggan,
      body: { action: "register", fcm_token: tokenMati, platform: "android" },
    });
    tegas(daftar.status === 200, "token basi harus terdaftar dulu", daftar);

    const ubah = await panggil("manage-booking", {
      token: tokenStaf,
      body: { action: "admin-set-status", kode, status: "confirmed" },
    });
    tegas(ubah.status === 200, "ubah status oleh staf harus 200", ubah);
    tegas(ubah.json.booking?.status === "confirmed", "status harus confirmed", ubah.json);

    const kirim = await panggil("notify-booking-status", {
      headers: { "x-webhook-secret": "rahasia-notify-uji" },
      body: { drain: true, limit: 10 },
    });
    tegas(kirim.status === 200, "status 200", kirim);
    tegas((kirim.json.sent ?? 0) >= 1, "minimal satu notifikasi terkirim", kirim.json);

    const nonaktif = await sql(
      "select is_active from public.user_devices where fcm_token = 'mati-token-abcdefghij'",
    );
    tegas((nonaktif as any)[0]?.is_active === false, "token mati harus dinonaktifkan", nonaktif);
  });

  await uji("admin-import: statistik + batas peran + impor kering", async () => {
    const tolak = await panggil("admin-import", { token: tokenPelanggan, body: { action: "stats" } });
    tegas(tolak.status === 403, "pelanggan harus 403", tolak);

    const staf = await panggil("admin-import", { token: tokenStaf, body: { action: "stats" } });
    tegas(staf.status === 200, "staf harus 200", staf);

    const impor = await panggil("admin-import", {
      token: tokenStaf,
      body: {
        action: "legacy-bookings",
        dry_run: true,
        bookings: [
          {
            kode: "RARA-LAMA-1",
            asal: "Surabaya",
            tujuan: "Jakarta",
            tanggal: "2026-08-01",
            jam: "06:00",
            nama: "Pelanggan Lama",
            wa: "081200000003",
            kursi: 1,
            totalHarga: 450000,
            status: "Dikonfirmasi",
            createdAt: "2026-07-25T08:00:00Z",
          },
        ],
      },
    });
    tegas(impor.status === 200, "status 200", impor);
    tegas(impor.json.dry_run === true, "harus laporan kering", impor.json);
    const tersimpan = await sql("select count(*)::int as n from public.bookings where kode = 'RARA-LAMA-1'");
    tegas((tersimpan as any)[0].n === 0, "dry run tidak boleh menulis", tersimpan);
  });

  await uji("Pesanan: pembatalan mengembalikan kursi + idempoten", async () => {
    const sebelum = await sql(
      `select coalesce(sum(booked_seats), 0)::int as n from public.route_schedules
        where route_id = (select id from public.routes where slug = 'surabaya-jakarta')`,
    );
    const batal = await panggil("manage-booking", { token: tokenPelanggan, body: { action: "cancel", kode } });
    tegas(batal.status === 200, "pembatalan harus 200", batal);
    tegas(batal.json.booking?.status === "cancelled", "status harus cancelled", batal.json);
    const sesudah = await sql(
      `select coalesce(sum(booked_seats), 0)::int as n from public.route_schedules
        where route_id = (select id from public.routes where slug = 'surabaya-jakarta')`,
    );
    tegas((sesudah as any)[0].n < (sebelum as any)[0].n, "kursi harus kembali", { sebelum, sesudah });

    const ulang = await panggil("manage-booking", { token: tokenPelanggan, body: { action: "cancel", kode } });
    tegas(ulang.status === 200, "pembatalan kedua tetap 200", ulang);
    tegas(ulang.json.booking?.status === "cancelled", "tetap cancelled", ulang.json);
  });

  await uji("Data pribadi: pesanan milik orang lain tidak terlihat", async () => {
    await panggil("auth-user-sync", { token: tokenLain, body: { action: "sync", full_name: "Bukan Staf" } });
    const daftar = await panggil("manage-booking", { token: tokenLain, body: { action: "list" } });
    tegas(daftar.status === 200, "status 200", daftar);
    tegas(daftar.json.total === 0, "tidak boleh melihat pesanan orang lain", daftar.json);
    const detail = await panggil("manage-booking", { token: tokenLain, body: { action: "detail", kode } });
    tegas(detail.status === 404, "detail pesanan orang lain harus 404", detail);
  });
}

/** Panggilan ulang create-booking dengan kunci idempotensi yang sama. */
async function buatUlang(idempotencyKey: string, token: string): Promise<HasilPanggil> {
  const asli = await sql(
    `select origin_city_name as asal from (select 1) x where false`, // tidak dipakai, lihat catatan
  ).catch(() => null);
  void asli;
  return await panggil("create-booking", {
    token,
    body: {
      idempotency_key: idempotencyKey,
      origin: "Surabaya",
      destination: "Jakarta",
      travel_date: new Date(Date.now() + 3 * 86400_000).toISOString().slice(0, 10),
      departure_time: "06:00",
      seats: 2,
      contact_name: "Pelanggan Uji",
      contact_phone: "081200000002",
      payment_method: "Transfer Bank",
      promo_code: "RARAHEMAT",
    },
  });
}

// ---------------------------------------------------------------------------
async function main(): Promise<void> {
  buatKunci();
  pasangShimFetch();
  await nyalakanBridge();

  process.env.SUPABASE_URL = basis;
  process.env.SUPABASE_SERVICE_ROLE_KEY = "uji-service-role-key";
  process.env.FIREBASE_PROJECT_ID = PROJECT;
  process.env.FIREBASE_SERVICE_ACCOUNT = JSON.stringify({
    type: "service_account",
    project_id: PROJECT,
    client_email: `fcm-uji@${PROJECT}.iam.gserviceaccount.com`,
    private_key: pem(privateKey),
    token_uri: "https://oauth2.googleapis.com/token",
  });
  process.env.NOTIFY_WEBHOOK_SECRET = "rahasia-notify-uji";
  process.env.PAYMENT_HMAC_SECRET = "rahasia-hmac-uji";
  process.env.MIDTRANS_SERVER_KEY = "midtrans-uji";
  process.env.MIDTRANS_IS_PRODUCTION = "false";
  process.env.ALLOWED_ORIGINS = "*";

  console.log(`Tiruan Supabase: ${basis}\n`);
  try {
    await jalankanSkenario();
  } finally {
    bridge?.kill("SIGTERM");
  }

  const gagal = catatan.filter((c) => !c.ok);
  console.log(
    `\n${catatan.length - gagal.length}/${catatan.length} skenario lulus` + (gagal.length ? " — GAGAL" : " — SEMUA OK"),
  );
  if (gagal.length) {
    for (const item of gagal) console.log(` - ${item.nama}: ${item.pesan}`);
    process.exitCode = 1;
  }
}

await main();
