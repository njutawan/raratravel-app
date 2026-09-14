// ===========================================================================
// create-booking.ts — berkas SIAP TEMPEL untuk Supabase Dashboard (tanpa CLI).
//
// Dihasilkan otomatis dari supabase/functions/create-booking/index.ts + _shared/*.ts
// oleh tools/bundle_functions.js. JANGAN diedit manual — ubah berkas asli lalu
// buat ulang:  node tools/bundle_functions.js create-booking
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
function env() {
  return {
    supabaseUrl: required("SUPABASE_URL"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
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
  const { serviceRoleKey } = env();
  return {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
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

// supabase/functions/_shared/firebase.ts
var JWK_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
var keyCache = null;
function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const withPadding = padded + "=".repeat((4 - padded.length % 4) % 4);
  const binary = atob(withPadding);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
async function publicKeys() {
  const now = Date.now();
  if (keyCache && now - keyCache.fetchedAt < keyCache.ttlMs) {
    return keyCache.keys;
  }
  const response = await fetch(JWK_URL);
  if (!response.ok) {
    throw Object.assign(new Error("Tidak bisa mengambil kunci publik Firebase"), {
      status: 503,
      code: "service_unavailable"
    });
  }
  const cacheControl = response.headers.get("cache-control") ?? "";
  const maxAge = Number(cacheControl.match(/max-age=(\d+)/)?.[1] ?? 3600);
  const body = await response.json();
  const keys = {};
  for (const key of body.keys ?? []) {
    if (key?.kid && key.kty === "RSA" && key.n && key.e) keys[key.kid] = key;
  }
  keyCache = { fetchedAt: now, ttlMs: Math.max(maxAge - 60, 60) * 1e3, keys };
  return keys;
}
async function verifyFirebaseToken(idToken) {
  const { firebaseProjectId } = env();
  const parts = idToken.split(".");
  if (parts.length !== 3) {
    throw Object.assign(new Error("Token login tidak berbentuk JWT"), {
      status: 401,
      code: "unauthorized"
    });
  }
  const [headerPart, payloadPart, signaturePart] = parts;
  let header;
  let payload;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(headerPart)));
    payload = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadPart)));
  } catch {
    throw Object.assign(new Error("Token login tidak dapat dibaca"), {
      status: 401,
      code: "unauthorized"
    });
  }
  if (header.alg !== "RS256" || !header.kid) {
    throw Object.assign(new Error("Algoritma token tidak didukung"), {
      status: 401,
      code: "unauthorized"
    });
  }
  const keys = await publicKeys();
  const jwk = keys[header.kid];
  if (!jwk) {
    keyCache = null;
    throw Object.assign(new Error("Kunci token tidak dikenal"), {
      status: 401,
      code: "unauthorized"
    });
  }
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  let signature;
  try {
    signature = base64UrlToBytes(signaturePart);
  } catch {
    throw Object.assign(new Error("Tanda tangan token tidak dapat dibaca"), {
      status: 401,
      code: "unauthorized"
    });
  }
  const valid = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    signature.buffer,
    new TextEncoder().encode(`${headerPart}.${payloadPart}`)
  );
  if (!valid) {
    throw Object.assign(new Error("Tanda tangan token tidak sah"), {
      status: 401,
      code: "unauthorized"
    });
  }
  const now = Math.floor(Date.now() / 1e3);
  if (payload.aud !== firebaseProjectId) {
    throw Object.assign(new Error("Token bukan untuk proyek Firebase ini"), {
      status: 401,
      code: "unauthorized"
    });
  }
  if (payload.iss !== `https://securetoken.google.com/${firebaseProjectId}`) {
    throw Object.assign(new Error("Penerbit token tidak dikenal"), {
      status: 401,
      code: "unauthorized"
    });
  }
  if (!payload.exp || payload.exp < now) {
    throw Object.assign(new Error("Sesi login sudah kedaluwarsa"), {
      status: 401,
      code: "session_expired"
    });
  }
  if (!payload.iat || payload.iat > now + 300) {
    throw Object.assign(new Error("Waktu token tidak wajar"), {
      status: 401,
      code: "unauthorized"
    });
  }
  if (!payload.sub || payload.sub.length < 5) {
    throw Object.assign(new Error("Token tanpa identitas pengguna"), {
      status: 401,
      code: "unauthorized"
    });
  }
  return {
    uid: payload.sub,
    phone: payload.phone_number,
    email: payload.email,
    name: payload.name,
    picture: payload.picture,
    provider: payload.firebase?.sign_in_provider
  };
}
async function requireFirebaseUser(req) {
  const header = req.headers.get("authorization") ?? req.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw Object.assign(new Error("Permintaan ini membutuhkan login"), {
      status: 401,
      code: "unauthorized"
    });
  }
  return await verifyFirebaseToken(match[1].trim());
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
async function readJson(req) {
  try {
    const text = await req.text();
    if (!text) return {};
    return JSON.parse(text);
  } catch {
    throw Object.assign(new Error("Body permintaan bukan JSON yang sah"), {
      code: "RA001",
      status: 400
    });
  }
}
function optionsResponse(req) {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(req.headers.get("origin"))
  });
}

// supabase/functions/create-booking/index.ts
var MAX_BOOKINGS_PER_HOUR = 8;
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");
  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson(req);
    const userId = await rpc("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid
    });
    if (!userId) {
      return errorResponse(
        "unauthorized",
        "Akun belum tersinkron. Buka aplikasi lalu login ulang.",
        401,
        void 0,
        origin
      );
    }
    const rate = await rpc("booking_rate_ok", {
      p_user_id: userId,
      p_max: MAX_BOOKINGS_PER_HOUR,
      p_window_minutes: 60
    });
    if (!rate.allowed) {
      return errorResponse(
        "rate_limited",
        "Terlalu banyak pesanan dalam waktu singkat. Coba lagi sebentar lagi atau hubungi admin.",
        429,
        rate,
        origin
      );
    }
    const result = await rpc("create_booking", {
      p_user_id: userId,
      p_payload: normalize(body)
    });
    return json({ ok: true, ...result }, { status: 201, origin });
  } catch (error) {
    return handleError(error, origin);
  }
});
function normalize(body) {
  const pick = (...values) => {
    for (const value of values) {
      if (value !== void 0 && value !== null && `${value}`.trim() !== "") {
        return value;
      }
    }
    return null;
  };
  return {
    idempotency_key: pick(body.idempotency_key),
    kode: pick(body.kode),
    route_id: pick(body.route_id),
    origin: pick(body.origin, body.asal),
    destination: pick(body.destination, body.tujuan),
    travel_date: pick(body.travel_date, body.tanggal),
    departure_time: pick(body.departure_time, body.jam),
    seats: pick(body.seats, body.kursi),
    seat_numbers: Array.isArray(body.seat_numbers) ? body.seat_numbers : null,
    contact_name: pick(body.contact_name, body.nama),
    contact_phone: pick(body.contact_phone, body.wa),
    contact_email: pick(body.contact_email),
    pickup_address: pick(body.pickup_address, body.jemput),
    dropoff_address: pick(body.dropoff_address, body.antar),
    notes: pick(body.notes, body.catatan),
    payment_method: pick(body.payment_method, body.metodeBayar),
    promo_code: pick(body.promo_code, body.promo),
    // Dipakai hanya untuk mendeteksi perubahan harga di server.
    client_total: pick(body.client_total, body.total),
    service_type: pick(body.service_type) ?? "travel",
    source: "app"
  };
}
