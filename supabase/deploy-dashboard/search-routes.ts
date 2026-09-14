// ===========================================================================
// search-routes.ts — berkas SIAP TEMPEL untuk Supabase Dashboard (tanpa CLI).
//
// Dihasilkan otomatis dari supabase/functions/search-routes/index.ts + _shared/*.ts
// oleh tools/bundle_functions.js. JANGAN diedit manual — ubah berkas asli lalu
// buat ulang:  node tools/bundle_functions.js search-routes
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

// supabase/functions/search-routes/index.ts
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");
  try {
    const payload = req.method === "GET" ? fromQuery(new URL(req.url).searchParams) : await readJson(req);
    switch (payload.action ?? "search") {
      case "cities":
        return json(
          { ok: true, items: await rpc("catalog_cities", { p_q: payload.q ?? null }) },
          { origin }
        );
      case "detail": {
        const key = payload.key ?? payload.slug ?? payload.route_id ?? null;
        if (!key) {
          return json(
            { error: { code: "validation_error", message: "key/slug/route_id wajib diisi" } },
            { status: 400, origin }
          );
        }
        const detail = await rpc("get_route_detail", {
          p_key: key,
          p_date: payload.date ?? null
        });
        if (!detail) {
          return json(
            { error: { code: "not_found", message: "Rute tidak ditemukan" } },
            { status: 404, origin }
          );
        }
        return json({ ok: true, route: detail }, { origin });
      }
      case "rentals":
        return json({
          ok: true,
          ...await rpc("list_rental_packages", {
            p_city: payload.city ?? payload.origin ?? null,
            p_q: payload.q ?? null,
            p_limit: payload.limit ?? 20,
            p_offset: payload.offset ?? 0
          })
        }, { origin });
      case "tours":
        return json({
          ok: true,
          ...await rpc("list_tour_packages", {
            p_q: payload.q ?? null,
            p_limit: payload.limit ?? 20,
            p_offset: payload.offset ?? 0
          })
        }, { origin });
      case "vehicles":
        return json(
          { ok: true, items: await rpc("list_vehicles", {}) },
          { origin }
        );
      default:
        return json({
          ok: true,
          ...await rpc("search_routes", {
            p_origin: payload.origin ?? null,
            p_destination: payload.destination ?? null,
            p_date: payload.date ?? null,
            p_passengers: payload.passengers ?? 1,
            p_q: payload.q ?? null,
            p_sort: payload.sort ?? "popular",
            p_limit: payload.limit ?? 10,
            p_offset: payload.offset ?? 0
          })
        }, { origin });
    }
  } catch (error) {
    return handleError(error, origin);
  }
});
function fromQuery(params) {
  const num = (key) => {
    const raw = params.get(key);
    if (raw === null || raw === "") return null;
    const value = Number(raw);
    return Number.isFinite(value) ? value : null;
  };
  return {
    action: params.get("action") ?? "search",
    origin: params.get("origin"),
    destination: params.get("destination"),
    date: params.get("date"),
    passengers: num("passengers"),
    q: params.get("q"),
    sort: params.get("sort"),
    limit: num("limit"),
    offset: num("offset"),
    key: params.get("key"),
    slug: params.get("slug"),
    route_id: params.get("route_id"),
    city: params.get("city")
  };
}
