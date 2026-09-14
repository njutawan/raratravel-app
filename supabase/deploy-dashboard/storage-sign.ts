// ===========================================================================
// storage-sign.ts — berkas SIAP TEMPEL untuk Supabase Dashboard (tanpa CLI).
//
// Dihasilkan otomatis dari supabase/functions/storage-sign/index.ts + _shared/*.ts
// oleh tools/bundle_functions.js. JANGAN diedit manual — ubah berkas asli lalu
// buat ulang:  node tools/bundle_functions.js storage-sign
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
function publicObjectUrl(bucket, path) {
  const { supabaseUrl } = env();
  return `${supabaseUrl}/storage/v1/object/public/${bucket}/${encodeURI(path)}`;
}
async function createSignedUrl(bucket, path, expiresInSeconds = 600) {
  const { supabaseUrl } = env();
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/sign/${bucket}/${encodeURI(path)}`,
    {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ expiresIn: expiresInSeconds })
    }
  );
  if (!response.ok) {
    throw new Error(`Gagal membuat tautan berkas: ${await response.text()}`);
  }
  const payload = await response.json();
  if (!payload.signedURL) throw new Error("Tautan berkas tidak diterima");
  return `${supabaseUrl}/storage/v1${payload.signedURL}`;
}
async function createSignedUploadUrl(bucket, path) {
  const { supabaseUrl } = env();
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/upload/sign/${bucket}/${encodeURI(path)}`,
    { method: "POST", headers: headers(), body: JSON.stringify({}) }
  );
  if (!response.ok) {
    throw new Error(`Gagal membuat tautan unggah: ${await response.text()}`);
  }
  const payload = await response.json();
  if (!payload.url || !payload.token) {
    throw new Error("Tautan unggah tidak lengkap");
  }
  const uploadUrl = payload.url.startsWith("http") ? payload.url : `${supabaseUrl}/storage/v1${payload.url}`;
  return { uploadUrl, token: payload.token };
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

// supabase/functions/storage-sign/index.ts
var RULES = {
  route: { bucket: "public-assets", prefix: "routes", public: true, staff: true },
  tour: { bucket: "public-assets", prefix: "tours", public: true, staff: true },
  rental: { bucket: "public-assets", prefix: "rentals", public: true, staff: true },
  vehicle: { bucket: "public-assets", prefix: "vehicles", public: true, staff: true },
  avatar: { bucket: "avatars", prefix: "users", public: true },
  payment_proof: { bucket: "payment-proofs", prefix: "bookings", public: false },
  other: { bucket: "public-assets", prefix: "misc", public: true }
};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");
  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson(req);
    const action = body.action ?? "upload-url";
    const kind = body.kind ?? "other";
    const rule = RULES[kind] ?? RULES.other;
    let userId = await rpc("resolve_user_id", { p_firebase_uid: firebaseUser.uid });
    if (!userId) {
      const synced = await rpc("auth_user_sync", {
        p_firebase_uid: firebaseUser.uid
      });
      userId = synced.user.id;
    }
    if (rule.staff) {
      const role = await rpc("staff_role", { p_user_id: userId });
      if (!role) {
        return errorResponse(
          "forbidden",
          "Unggahan gambar katalog hanya untuk staf",
          403,
          { kind },
          origin
        );
      }
    }
    if (action === "public-url") {
      const path2 = body.path ?? "";
      if (!path2) return errorResponse("validation_error", "path wajib diisi", 400, void 0, origin);
      return json({ ok: true, public_url: publicObjectUrl(rule.bucket, sanitize(path2)) }, { origin });
    }
    let bookingId = null;
    if (kind === "payment_proof") {
      if (!body.kode && action !== "download-url") {
        return errorResponse("validation_error", "kode pesanan wajib diisi untuk bukti transfer", 400, void 0, origin);
      }
      if (body.kode) {
        const booking = await rpc("find_booking", {
          p_user_id: userId,
          p_kode: body.kode
        });
        if (!booking) {
          return errorResponse("not_found", "Pesanan tidak ditemukan", 404, void 0, origin);
        }
        bookingId = booking.id;
      }
    }
    const path = sanitize(body.path ?? defaultPath(kind, userId, body));
    if (action === "download-url") {
      const asset = await rpc("media_asset_for_user", {
        p_path: path,
        p_user_id: userId
      });
      if (!asset) {
        return errorResponse("not_found", "Berkas tidak terdaftar", 404, void 0, origin);
      }
      if (asset.allowed === false) {
        return errorResponse("forbidden", "Tidak berhak mengunduh berkas ini", 403, void 0, origin);
      }
      const bucket = asset?.bucket ?? rule.bucket;
      const signedUrl = await createSignedUrl(bucket, path, clampExpiry(body.expires_in));
      return json({ ok: true, bucket, path, expires_in: clampExpiry(body.expires_in), download_url: signedUrl }, { origin });
    }
    const { uploadUrl, token } = await createSignedUploadUrl(rule.bucket, path);
    await rpc("record_media_asset", {
      p_bucket: rule.bucket,
      p_path: path,
      p_kind: kind,
      p_owner_user_id: kind === "avatar" || kind === "payment_proof" ? userId : null,
      p_booking_id: bookingId,
      p_uploaded_by: userId,
      p_mime_type: body.content_type ?? null,
      p_file_size: null,
      p_is_public: rule.public,
      p_metadata: { requested_by: userId }
    });
    return json({
      ok: true,
      bucket: rule.bucket,
      path,
      upload_url: uploadUrl,
      token,
      public_url: rule.public ? publicObjectUrl(rule.bucket, path) : null,
      max_size_bytes: kind === "avatar" ? 2097152 : 5242880
    }, { status: 201, origin });
  } catch (error) {
    return handleError(error, origin);
  }
});
function clampExpiry(value) {
  if (!value || !Number.isFinite(value)) return 600;
  return Math.min(Math.max(Math.trunc(value), 60), 86400);
}
function sanitize(path) {
  const clean = path.replace(/\\/g, "/").split("/").filter((part) => part !== "" && part !== "." && part !== "..").join("/").replace(/[^A-Za-z0-9/._-]/g, "_");
  if (!clean) {
    throw Object.assign(new Error("Path berkas tidak sah"), { status: 400, code: "RA001" });
  }
  return clean;
}
function defaultPath(kind, userId, body) {
  const rule = RULES[kind] ?? RULES.other;
  const stamp = Date.now();
  const safeName = (body.filename ?? `${kind}-${stamp}.jpg`).replace(/[^A-Za-z0-9._-]/g, "_");
  if (kind === "payment_proof") {
    return `${rule.prefix}/${body.kode}/${stamp}-${safeName}`;
  }
  if (kind === "avatar") {
    return `${rule.prefix}/${userId}/avatar-${stamp}-${safeName}`;
  }
  return `${rule.prefix}/${stamp}-${safeName}`;
}
