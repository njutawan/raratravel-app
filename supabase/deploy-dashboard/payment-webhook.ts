// ===========================================================================
// payment-webhook.ts — berkas SIAP TEMPEL untuk Supabase Dashboard (tanpa CLI).
//
// Dihasilkan otomatis dari supabase/functions/payment-webhook/index.ts + _shared/*.ts
// oleh tools/bundle_functions.js. JANGAN diedit manual — ubah berkas asli lalu
// buat ulang:  node tools/bundle_functions.js payment-webhook
//
// Cara pakai: Dashboard → Edge Functions → Deploy a new function → tempel isi
// berkas ini, matikan "Verify JWT", lalu Deploy. Rinciannya: MIGRASI_SUPABASE.md §2.5.
// ===========================================================================

// supabase/functions/_shared/env.ts
function required(name) {
  const value = Deno.env.get(name);
  if (!value || value.trim() === "") {
    throw new Error(
      `Konfigurasi ${name} belum diisi. Set lewat Secrets Edge Function.`
    );
  }
  return value.trim();
}
function optional(name) {
  const value = Deno.env.get(name);
  return value && value.trim() !== "" ? value.trim() : void 0;
}
function serviceRoleKey() {
  const langsung = optional("SUPABASE_SERVICE_ROLE_KEY") ?? optional("SUPABASE_SECRET_KEY");
  if (langsung) return langsung;
  const kamus = optional("SUPABASE_SECRET_KEYS");
  if (kamus) {
    try {
      const data = JSON.parse(kamus);
      const nilai = data.default ?? Object.values(data)[0];
      if (typeof nilai === "string" && nilai.trim()) return nilai.trim();
    } catch {
    }
  }
  throw new Error(
    "Konfigurasi kunci server Supabase belum ada. Isi SUPABASE_SERVICE_ROLE_KEY (kunci lama) atau sediakan SUPABASE_SECRET_KEYS / SUPABASE_SECRET_KEY (kunci model baru `sb_secret_…`)."
  );
}
function env() {
  return {
    supabaseUrl: required("SUPABASE_URL"),
    get serviceRoleKey() {
      return serviceRoleKey();
    },
    firebaseProjectId: required("FIREBASE_PROJECT_ID"),
    firebaseServiceAccount: optional("FIREBASE_SERVICE_ACCOUNT"),
    notifyWebhookSecret: optional("NOTIFY_WEBHOOK_SECRET"),
    midtransServerKey: optional("MIDTRANS_SERVER_KEY"),
    midtransIsProduction: optional("MIDTRANS_IS_PRODUCTION") === "true",
    xenditCallbackToken: optional("XENDIT_CALLBACK_TOKEN"),
    paymentHmacSecret: optional("PAYMENT_HMAC_SECRET"),
    // Aplikasi mobile tidak memakai CORS, tetapi panel admin web mungkin.
    allowedOrigins: (optional("ALLOWED_ORIGINS") ?? "*").split(",").map((origin) => origin.trim()).filter(Boolean)
  };
}

// supabase/functions/_shared/db.ts
function headers(extra = {}) {
  const { serviceRoleKey: serviceRoleKey2 } = env();
  return {
    apikey: serviceRoleKey2,
    Authorization: `Bearer ${serviceRoleKey2}`,
    "Content-Type": "application/json",
    ...extra
  };
}
async function rpc(name, params = {}, init = {}) {
  const { supabaseUrl } = env();
  const method = init.method ?? "POST";
  const response = method === "GET" ? await fetch(
    `${supabaseUrl}/rest/v1/rpc/${name}?${new URLSearchParams(
      Object.entries(params).map(([key, value]) => [key, String(value ?? "")])
    )}`,
    { method: "GET", headers: headers() }
  ) : await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(params)
  });
  const text = await response.text();
  if (!response.ok) {
    let payload = {};
    try {
      payload = text ? JSON.parse(text) : {};
    } catch {
      payload = { message: text };
    }
    throw Object.assign(new Error(payload.message ?? "Permintaan database gagal"), {
      code: payload.code,
      details: payload.details,
      hint: payload.hint,
      status: response.status
    });
  }
  if (!text) return null;
  return JSON.parse(text);
}

// supabase/functions/_shared/payments.ts
async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
async function sha512Hex(message) {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(message));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
function toNumber(value) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value.replace(/[^0-9.-]/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}
function str(value) {
  if (value === null || value === void 0) return null;
  const text = String(value).trim();
  return text === "" ? null : text;
}
function midtransStatusToPaymentStatus(transactionStatus, fraudStatus) {
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
async function parseMidtrans(body) {
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
    status: midtransStatusToPaymentStatus(transactionStatus, str(body.fraud_status) ?? void 0),
    providerReference: orderId || null,
    amount: toNumber(grossAmount),
    signatureValid,
    failureReason: str(body.status_message),
    payload: body
  };
}
function xenditStatusToPaymentStatus(status) {
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
function parseXendit(body, headerToken) {
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
    signatureValid: Boolean(token) && safeEqual(token, headerToken ?? ""),
    failureReason: str(body.failure_reason),
    payload: body
  };
}
async function parseHmac(body, rawBody, signature) {
  const secret = env().paymentHmacSecret;
  let signatureValid = false;
  if (secret && signature) {
    const expected = await hmacHex(secret, rawBody);
    signatureValid = safeEqual(expected, signature.trim().toLowerCase());
  }
  const provider = str(body.provider) ?? "internal";
  return {
    provider: provider === "manual" ? "manual" : "internal",
    eventId: str(body.event_id) ?? str(body.eventId) ?? "",
    eventType: str(body.event_type) ?? "payment.event",
    status: str(body.status) ?? "pending",
    providerReference: str(body.provider_reference) ?? str(body.reference) ?? null,
    amount: toNumber(body.amount),
    signatureValid,
    failureReason: str(body.failure_reason),
    payload: body
  };
}
async function parseWebhook(providerHint, req) {
  const rawBody = await req.text();
  let body = {};
  try {
    body = rawBody ? JSON.parse(rawBody) : {};
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

// supabase/functions/_shared/http.ts
var SQLSTATE_MAP = {
  RA001: { code: "validation_error", status: 400 },
  RA002: { code: "price_mismatch", status: 409 },
  RA003: { code: "seats_unavailable", status: 409 },
  RA004: { code: "not_found", status: 404 },
  RA005: { code: "promo_invalid", status: 400 },
  RA006: { code: "forbidden", status: 403 },
  RA007: { code: "conflict", status: 409 },
  RA008: { code: "payment_failed", status: 402 },
  RA099: { code: "internal_error", status: 500 }
};
function corsHeaders(origin) {
  const allowed = env().allowedOrigins;
  const allowOrigin = allowed.includes("*") ? "*" : origin && allowed.includes(origin) ? origin : allowed[0] ?? "";
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret, x-callback-token, x-signature",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  };
}
function json(body, init = {}) {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...corsHeaders(init.origin),
      ...init.headers ?? {}
    }
  });
}
function errorResponse(code, message, status = 400, details, origin) {
  const body = { error: { code, message } };
  if (details !== void 0) body.error.details = details;
  return json(body, { status, origin });
}
function handleError(error, origin) {
  const err = error;
  const sqlstate = typeof err?.code === "string" ? err.code : "";
  const mapped = SQLSTATE_MAP[sqlstate];
  let appCode = mapped?.code;
  let details;
  if (err?.details) {
    try {
      details = JSON.parse(err.details);
      if (details && typeof details === "object" && "code" in details) {
        appCode = details.code ?? appCode;
      }
    } catch {
      details = err.details;
    }
  }
  const message = err?.message ?? "Terjadi kesalahan di server";
  const status = mapped?.status ?? err?.status ?? 500;
  const cleanMessage = message.replace(/^[A-Z_]+[0-9]*:\s*/, "");
  console.error("[api-error]", { sqlstate, appCode, message, details });
  return errorResponse(appCode ?? "server_error", cleanMessage, status, details, origin);
}
function optionsResponse(req) {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(req.headers.get("origin"))
  });
}

// supabase/functions/payment-webhook/index.ts
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  try {
    if (req.method !== "POST") {
      return errorResponse("validation_error", "Gunakan metode POST", 405);
    }
    const url = new URL(req.url);
    let provider = (url.searchParams.get("provider") ?? "").toLowerCase();
    if (!provider) {
      const clone = req.clone();
      const peek = await clone.text();
      if (peek.includes("signature_key") || peek.includes("transaction_status")) {
        provider = "midtrans";
      } else if (peek.includes("callback") || peek.includes("external_id")) {
        provider = "xendit";
      } else {
        provider = "hmac";
      }
      return await process(new Request(req.url, { method: "POST", headers: req.headers, body: peek }), provider, req);
    }
    return await process(req, provider, req);
  } catch (error) {
    return handleError(error);
  }
});
async function process(req, provider, original) {
  const parsed = await parseWebhook(provider, req);
  const secret = env().notifyWebhookSecret;
  const provided = original.headers.get("x-webhook-secret");
  const trustedCaller = Boolean(secret) && provided === secret;
  const signatureValid = parsed.signatureValid || trustedCaller;
  if (!signatureValid) {
    console.warn("[payment-webhook] tanda tangan tidak sah", {
      provider: parsed.provider,
      eventId: parsed.eventId
    });
    return json({
      ok: false,
      provider: parsed.provider,
      reason: "invalid_signature",
      event_id: parsed.eventId
    });
  }
  if (!parsed.eventId) {
    return errorResponse("validation_error", "event_id tidak ditemukan pada payload webhook", 400);
  }
  const result = await rpc("apply_payment_event", {
    p_provider: parsed.provider,
    p_event_id: parsed.eventId,
    p_event_type: parsed.eventType,
    p_status: parsed.status,
    p_provider_reference: parsed.providerReference,
    p_amount: parsed.amount,
    p_payload: parsed.payload,
    p_signature_valid: signatureValid,
    p_failure_reason: parsed.failureReason ?? null
  });
  return json({ ok: true, provider: parsed.provider, ...result });
}
