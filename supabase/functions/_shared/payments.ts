/**
 * Pembayaran: verifikasi tanda tangan webhook + pemetaan status provider.
 *
 * Provider yang didukung:
 *   * Midtrans  → header `signature_key` = sha512(order_id + status_code +
 *                 gross_amount + server_key)
 *   * Xendit    → header `x-callback-token` dibandingkan dengan token sandi
 *   * HMAC      → header `x-signature` = HMAC-SHA256(raw body, PAYMENT_HMAC_SECRET)
 *                 (dipakai untuk provider lain / pengujian)
 *
 * Semua pembandingan memakai waktu tetap (timing-safe) agar tidak bisa ditebak
 * sedikit-sedikit dari selisih waktu respons.
 */

import { env } from "./env.ts";

export type PaymentProvider = "midtrans" | "xendit" | "manual" | "internal";

export interface WebhookParseResult {
  provider: PaymentProvider;
  eventId: string;
  eventType: string;
  status: "pending" | "paid" | "failed" | "expired" | "refunded" | "cancelled";
  providerReference: string | null;
  amount: number | null;
  signatureValid: boolean;
  failureReason?: string | null;
  payload: Record<string, unknown>;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha512Hex(message: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(message));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Bandingkan dua string dengan waktu tetap. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function toNumber(value: unknown): number | null {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value.replace(/[^0-9.-]/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function str(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const text = String(value).trim();
  return text === "" ? null : text;
}

// ---------------------------------------------------------------------------
// Midtrans
// ---------------------------------------------------------------------------
export function midtransStatusToPaymentStatus(transactionStatus: string, fraudStatus?: string): WebhookParseResult["status"] {
  switch (transactionStatus) {
    case "capture":
      return fraudStatus === "challenge" ? "pending" : "paid";
    case "settlement":
      return "paid";
    case "pending":
      return "pending";
    case "deny":
    case "cancel":
      return "cancelled";
    case "expire":
      return "expired";
    case "refund":
    case "partial_refund":
      return "refunded";
    default:
      return "pending";
  }
}

async function parseMidtrans(body: Record<string, unknown>): Promise<WebhookParseResult> {
  const serverKey = env().midtransServerKey;
  const orderId = str(body.order_id) ?? "";
  const statusCode = str(body.status_code) ?? "";
  const grossAmount = str(body.gross_amount) ?? "";
  const transactionStatus = str(body.transaction_status) ?? "pending";
  const signatureKey = str(body.signature_key) ?? "";
  const transactionId = str(body.transaction_id) ?? `${orderId}-${transactionStatus}`;

  let signatureValid = false;
  if (serverKey) {
    const expected = await sha512Hex(`${orderId}${statusCode}${grossAmount}${serverKey}`);
    signatureValid = safeEqual(expected, signatureKey);
  }

  return {
    provider: "midtrans",
    eventId: `${transactionId}:${transactionStatus}`,
    eventType: `midtrans.${transactionStatus}`,
    status: midtransStatusToPaymentStatus(transactionStatus, str(body.fraud_status) ?? undefined),
    providerReference: orderId || null,
    amount: toNumber(gross_amount),
    signatureValid,
    failureReason: str(body.status_message),
    payload: body,
  };
}

// ---------------------------------------------------------------------------
// Xendit
// ---------------------------------------------------------------------------
function xenditStatusToPaymentStatus(status: string): WebhookParseResult["status"] {
  switch (status.toUpperCase()) {
    case "PAID":
    case "SETTLED":
      return "paid";
    case "PENDING":
      return "pending";
    case "EXPIRED":
      return "expired";
    case "FAILED":
      return "failed";
    case "REFUNDED":
    case "PARTIAL_REFUNDED":
      return "refunded";
    default:
      return "pending";
  }
}

function parseXendit(body: Record<string, unknown>, headerToken: string | null): WebhookParseResult {
  const token = env().xenditCallbackToken;
  const status = str(body.status) ?? "PENDING";
  const externalId = str(body.external_id) ?? str(body.reference_id) ?? "";

  return {
    provider: "xendit",
    eventId: str(body.id) ?? `${externalId}-${status}`,
    eventType: `xendit.${status.toLowerCase()}`,
    status: xenditStatusToPaymentStatus(status),
    providerReference: externalId || null,
    amount: toNumber(body.paid_amount) ?? toNumber(body.amount),
    signatureValid: Boolean(token) && safeEqual(token as string, headerToken ?? ""),
    failureReason: str(body.failure_reason),
    payload: body,
  };
}

// ---------------------------------------------------------------------------
// HMAC generik
// ---------------------------------------------------------------------------
async function parseHmac(
  body: Record<string, unknown>,
  rawBody: string,
  signature: string | null,
): Promise<WebhookParseResult> {
  const secret = env().paymentHmacSecret;
  let signatureValid = false;
  if (secret && signature) {
    const expected = await hmacHex(secret, rawBody);
    signatureValid = safeEqual(expected, signature.trim().toLowerCase());
  }

  const provider = (str(body.provider) ?? "internal") as PaymentProvider;
  return {
    provider: provider === "manual" ? "manual" : "internal",
    eventId: str(body.event_id) ?? str(body.eventId) ?? "",
    eventType: str(body.event_type) ?? "payment.event",
    status: (str(body.status) ?? "pending") as WebhookParseResult["status"],
    providerReference: str(body.provider_reference) ?? str(body.reference) ?? null,
    amount: toNumber(body.amount),
    signatureValid,
    failureReason: str(body.failure_reason),
    payload: body,
  };
}

/** Baca body webhook apa pun bentuknya → satu struktur seragam. */
export async function parseWebhook(
  providerHint: string,
  req: Request,
): Promise<WebhookParseResult> {
  const rawBody = await req.text();
  let body: Record<string, unknown> = {};
  try {
    body = rawBody ? JSON.parse(rawBody) as Record<string, unknown> : {};
  } catch {
    throw Object.assign(new Error("Body webhook bukan JSON"), { status: 400, code: "RA001" });
  }

  const provider = providerHint.toLowerCase();

  if (provider === "midtrans") return await parseMidtrans(body);
  if (provider === "xendit") {
    return parseXendit(body, req.headers.get("x-callback-token"));
  }
  return await parseHmac(body, rawBody, req.headers.get("x-signature"));
}

// ---------------------------------------------------------------------------
// Midtrans Snap (membuat tautan pembayaran)
// ---------------------------------------------------------------------------
export interface SnapTransaction {
  token?: string;
  redirect_url?: string;
}

export async function createMidtransSnapTransaction(params: {
  orderId: string;
  amount: number;
  itemName: string;
  customerName: string;
  customerPhone?: string | null;
  expiresAt?: string | null;
}): Promise<SnapTransaction> {
  const serverKey = env().midtransServerKey;
  if (!serverKey) {
    throw Object.assign(
      new Error("MIDTRANS_SERVER_KEY belum diisi — pembayaran online belum aktif."),
      { status: 501, code: "not_configured" },
    );
  }

  const base = env().midtransIsProduction
    ? "https://app.midtrans.com/snap/v1/transactions"
    : "https://app.sandbox.midtrans.com/snap/v1/transactions";

  const response = await fetch(base, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${serverKey}:`)}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      transaction_details: { order_id: params.orderId, gross_amount: Math.round(params.amount) },
      item_details: [{
        id: params.orderId,
        name: params.itemName.slice(0, 50),
        price: Math.round(params.amount),
        quantity: 1,
      }],
      customer_details: {
        first_name: params.customerName.slice(0, 50),
        phone: params.customerPhone ?? undefined,
      },
      credit_card: { secure: true },
      expiry: params.expiresAt ? { start_time: undefined, unit: "minutes", duration: 60 } : undefined,
    }),
  });

  if (!response.ok) {
    throw Object.assign(
      new Error(`Midtrans menolak permintaan: ${await response.text()}`),
      { status: 502, code: "payment_failed" },
    );
  }

  return (await response.json()) as SnapTransaction;
}
