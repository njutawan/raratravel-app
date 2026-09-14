/**
 * Kirim notifikasi FCM (HTTP v1) memakai service account Firebase.
 *
 * Tidak memakai Firebase Admin SDK supaya fungsi tetap ringan. Token akses
 * OAuth2 di-cache di memori instance (berlaku ±1 jam) sehingga pengiriman
 * berikutnya tidak perlu menandatangani JWT lagi.
 */

import { env } from "./env.ts";

export interface FcmMessage {
  title: string;
  body?: string;
  data?: Record<string, string>;
}

export interface FcmSendResult {
  sent: number;
  failed: number;
  invalidTokens: string[];
  providerMessageIds: string[];
  errors: string[];
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id?: string;
  token_uri?: string;
}

interface TokenCache {
  key: string;
  accessToken: string;
  expiresAt: number;
}

let tokenCache: TokenCache | null = null;

function serviceAccount(): ServiceAccount {
  const raw = env().firebaseServiceAccount;
  if (!raw) {
    throw Object.assign(new Error("FIREBASE_SERVICE_ACCOUNT belum diisi"), {
      status: 500,
      code: "not_configured",
    });
  }
  try {
    const parsed = JSON.parse(raw) as ServiceAccount;
    if (!parsed.client_email || !parsed.private_key) {
      throw new Error("field client_email/private_key tidak ada");
    }
    parsed.private_key = parsed.private_key.replace(/\\n/g, "\n");
    return parsed;
  } catch (error) {
    throw Object.assign(
      new Error(`FIREBASE_SERVICE_ACCOUNT tidak bisa dibaca: ${String(error)}`),
      { status: 500, code: "not_configured" },
    );
  }
}

function base64Url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function accessToken(): Promise<string> {
  const account = serviceAccount();
  const now = Date.now();

  if (tokenCache && tokenCache.key === account.client_email && tokenCache.expiresAt > now + 60_000) {
    return tokenCache.accessToken;
  }

  const tokenUri = account.token_uri ?? "https://oauth2.googleapis.com/token";
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64Url(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: Math.floor(now / 1000),
    exp: Math.floor(now / 1000) + 3600,
  }));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(account.private_key).buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const assertion = `${header}.${claims}.${base64Url(new Uint8Array(signature))}`;

  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw Object.assign(
      new Error(`Gagal mengambil token FCM: ${await response.text()}`),
      { status: 502, code: "fcm_auth_failed" },
    );
  }

  const payload = (await response.json()) as { access_token?: string; expires_in?: number };
  if (!payload.access_token) {
    throw Object.assign(new Error("Token FCM kosong"), { status: 502, code: "fcm_auth_failed" });
  }

  tokenCache = {
    key: account.client_email,
    accessToken: payload.access_token,
    expiresAt: now + (payload.expires_in ?? 3600) * 1000,
  };
  return payload.access_token;
}

const INVALID_TOKEN_MARKERS = [
  "UNREGISTERED",
  "registration-token-not-registered",
  "INVALID_ARGUMENT",
  "invalid-argument",
];

/** Kirim satu pesan ke banyak token (paralel, hasil per token dilaporkan). */
export async function sendToDevices(
  tokens: string[],
  message: FcmMessage,
): Promise<FcmSendResult> {
  const result: FcmSendResult = {
    sent: 0,
    failed: 0,
    invalidTokens: [],
    providerMessageIds: [],
    errors: [],
  };

  const unique = [...new Set(tokens.filter((token) => typeof token === "string" && token.length > 10))];
  if (unique.length === 0) return result;

  const { firebaseProjectId } = env();
  const bearer = await accessToken();

  await Promise.all(unique.map(async (token) => {
    const body = {
      message: {
        token,
        notification: { title: message.title, body: message.body ?? "" },
        data: message.data ?? {},
        android: {
          priority: "high",
          notification: { channel_id: "rara_orders", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
      },
    };

    try {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${firebaseProjectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${bearer}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        },
      );

      if (response.ok) {
        const payload = (await response.json()) as { name?: string };
        result.sent += 1;
        if (payload.name) result.providerMessageIds.push(payload.name);
        return;
      }

      const text = await response.text();
      result.failed += 1;
      result.errors.push(text.slice(0, 300));
      if (INVALID_TOKEN_MARKERS.some((marker) => text.includes(marker))) {
        result.invalidTokens.push(token);
      }
    } catch (error) {
      result.failed += 1;
      result.errors.push(String(error).slice(0, 300));
    }
  }));

  return result;
}
