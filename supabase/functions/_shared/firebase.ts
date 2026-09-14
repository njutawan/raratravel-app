/**
 * Verifikasi Firebase ID token tanpa Firebase Admin SDK.
 *
 * Firebase Auth tetap menjadi identitas pengguna aplikasi (sesuai rencana
 * migrasi). Edge Function memeriksa tanda tangan RS256 memakai sertifikat
 * publik Google, lalu memastikan issuer/audience memang proyek Firebase
 * aplikasi ini.
 */

import { env } from "./env.ts";

export interface FirebaseUser {
  uid: string;
  phone?: string;
  email?: string;
  name?: string;
  picture?: string;
  provider?: string;
}

interface JwtPayload {
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
  sub?: string;
  phone_number?: string;
  email?: string;
  name?: string;
  picture?: string;
  firebase?: { sign_in_provider?: string };
}

/**
 * Kunci publik Google dalam bentuk JWK (bukan sertifikat x509).
 *
 * Penting: `crypto.subtle.importKey("spki", …)` TIDAK bisa membaca sertifikat
 * x509 (struktur DER-nya berbeda) — kesalahan itu membuat SELURUH endpoint
 * yang butuh login gagal dengan 500. Endpoint JWK di bawah mengembalikan
 * modulus/eksponen (n, e) yang langsung dapat diimpor WebCrypto.
 */
const JWK_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

interface GoogleJwk {
  kid: string;
  kty: string;
  n: string;
  e: string;
  alg?: string;
  use?: string;
}

let keyCache: {
  fetchedAt: number;
  ttlMs: number;
  keys: Record<string, GoogleJwk>;
} | null = null;

function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const withPadding = padded + "=".repeat((4 - (padded.length % 4)) % 4);
  const binary = atob(withPadding);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function publicKeys(): Promise<Record<string, GoogleJwk>> {
  const now = Date.now();
  if (keyCache && now - keyCache.fetchedAt < keyCache.ttlMs) {
    return keyCache.keys;
  }

  const response = await fetch(JWK_URL);
  if (!response.ok) {
    throw Object.assign(new Error("Tidak bisa mengambil kunci publik Firebase"), {
      status: 503,
      code: "service_unavailable",
    });
  }

  const cacheControl = response.headers.get("cache-control") ?? "";
  const maxAge = Number(cacheControl.match(/max-age=(\d+)/)?.[1] ?? 3600);
  const body = (await response.json()) as { keys?: GoogleJwk[] };
  const keys: Record<string, GoogleJwk> = {};
  for (const key of body.keys ?? []) {
    if (key?.kid && key.kty === "RSA" && key.n && key.e) keys[key.kid] = key;
  }

  keyCache = { fetchedAt: now, ttlMs: Math.max(maxAge - 60, 60) * 1000, keys };
  return keys;
}

/** Lempar error bergaya API bila token tidak sah/kedaluwarsa. */
export async function verifyFirebaseToken(idToken: string): Promise<FirebaseUser> {
  const { firebaseProjectId } = env();

  const parts = idToken.split(".");
  if (parts.length !== 3) {
    throw Object.assign(new Error("Token login tidak berbentuk JWT"), {
      status: 401,
      code: "unauthorized",
    });
  }

  const [headerPart, payloadPart, signaturePart] = parts;

  // Token yang rusak (base64 tidak sah, JSON tidak lengkap) harus dijawab 401,
  // bukan 500 — jangan sampai kegagalan decode terlihat seperti kesalahan server.
  let header: { alg?: string; kid?: string };
  let payload: JwtPayload;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(headerPart))) as {
      alg?: string;
      kid?: string;
    };
    payload = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadPart))) as JwtPayload;
  } catch {
    throw Object.assign(new Error("Token login tidak dapat dibaca"), {
      status: 401,
      code: "unauthorized",
    });
  }

  if (header.alg !== "RS256" || !header.kid) {
    throw Object.assign(new Error("Algoritma token tidak didukung"), {
      status: 401,
      code: "unauthorized",
    });
  }

  const keys = await publicKeys();
  const jwk = keys[header.kid];
  if (!jwk) {
    // Kunci berputar: paksa ambil ulang pada permintaan berikutnya.
    keyCache = null;
    throw Object.assign(new Error("Kunci token tidak dikenal"), {
      status: 401,
      code: "unauthorized",
    });
  }

  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );

  let signature: Uint8Array;
  try {
    signature = base64UrlToBytes(signaturePart);
  } catch {
    throw Object.assign(new Error("Tanda tangan token tidak dapat dibaca"), {
      status: 401,
      code: "unauthorized",
    });
  }

  const valid = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    signature.buffer as ArrayBuffer,
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!valid) {
    throw Object.assign(new Error("Tanda tangan token tidak sah"), {
      status: 401,
      code: "unauthorized",
    });
  }

  const now = Math.floor(Date.now() / 1000);
  if (payload.aud !== firebaseProjectId) {
    throw Object.assign(new Error("Token bukan untuk proyek Firebase ini"), {
      status: 401,
      code: "unauthorized",
    });
  }
  if (payload.iss !== `https://securetoken.google.com/${firebaseProjectId}`) {
    throw Object.assign(new Error("Penerbit token tidak dikenal"), {
      status: 401,
      code: "unauthorized",
    });
  }
  if (!payload.exp || payload.exp < now) {
    throw Object.assign(new Error("Sesi login sudah kedaluwarsa"), {
      status: 401,
      code: "session_expired",
    });
  }
  if (!payload.iat || payload.iat > now + 300) {
    throw Object.assign(new Error("Waktu token tidak wajar"), {
      status: 401,
      code: "unauthorized",
    });
  }
  if (!payload.sub || payload.sub.length < 5) {
    throw Object.assign(new Error("Token tanpa identitas pengguna"), {
      status: 401,
      code: "unauthorized",
    });
  }

  return {
    uid: payload.sub,
    phone: payload.phone_number,
    email: payload.email,
    name: payload.name,
    picture: payload.picture,
    provider: payload.firebase?.sign_in_provider,
  };
}

/** Ambil pengguna dari header Authorization; lempar 401 bila tidak ada. */
export async function requireFirebaseUser(req: Request): Promise<FirebaseUser> {
  const header = req.headers.get("authorization") ?? req.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw Object.assign(new Error("Permintaan ini membutuhkan login"), {
      status: 401,
      code: "unauthorized",
    });
  }
  return await verifyFirebaseToken(match[1].trim());
}

/** Opsional: dipakai endpoint publik yang tetap ingin tahu siapa pemanggilnya. */
export async function optionalFirebaseUser(req: Request): Promise<FirebaseUser | null> {
  try {
    return await requireFirebaseUser(req);
  } catch {
    return null;
  }
}
