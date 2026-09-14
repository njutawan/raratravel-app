/** Helper respons HTTP + pemetaan error PostgreSQL → pesan aplikasi. */

import { env } from "./env.ts";

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    details?: unknown;
  };
}

/** Kode SQLSTATE kustom dari migrasi → kode aplikasi + status HTTP. */
const SQLSTATE_MAP: Record<string, { code: string; status: number }> = {
  RA001: { code: "validation_error", status: 400 },
  RA002: { code: "price_mismatch", status: 409 },
  RA003: { code: "seats_unavailable", status: 409 },
  RA004: { code: "not_found", status: 404 },
  RA005: { code: "promo_invalid", status: 400 },
  RA006: { code: "forbidden", status: 403 },
  RA007: { code: "conflict", status: 409 },
  RA008: { code: "payment_failed", status: 402 },
  RA099: { code: "internal_error", status: 500 },
};

export function corsHeaders(origin?: string | null): Record<string, string> {
  const allowed = env().allowedOrigins;
  const allowOrigin = allowed.includes("*")
    ? "*"
    : (origin && allowed.includes(origin) ? origin : allowed[0] ?? "");

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-webhook-secret, x-callback-token, x-signature",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

export function json(
  body: unknown,
  init: { status?: number; headers?: Record<string, string>; origin?: string | null } = {},
): Response {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...corsHeaders(init.origin),
      ...(init.headers ?? {}),
    },
  });
}

export function errorResponse(
  code: string,
  message: string,
  status = 400,
  details?: unknown,
  origin?: string | null,
): Response {
  const body: ApiErrorBody = { error: { code, message } };
  if (details !== undefined) body.error.details = details;
  return json(body, { status, origin });
}

/** Ubah error apa pun (PostgREST/PostgreSQL/JS) jadi respons rapi. */
export function handleError(error: unknown, origin?: string | null): Response {
  const err = error as {
    message?: string;
    code?: string;
    details?: string;
    status?: number;
  };

  const sqlstate = typeof err?.code === "string" ? err.code : "";
  const mapped = SQLSTATE_MAP[sqlstate];

  // PostgreSQL menaruh kode aplikasi pada DETAIL: {"code":"..."}.
  let appCode = mapped?.code;
  let details: unknown;
  if (err?.details) {
    try {
      details = JSON.parse(err.details);
      if (details && typeof details === "object" && "code" in details) {
        appCode = (details as { code?: string }).code ?? appCode;
      }
    } catch {
      details = err.details;
    }
  }

  const message = err?.message ?? "Terjadi kesalahan di server";
  // PostgREST selalu membalas 400 untuk galat database; kode SQLSTATE kita
  // (RA002 harga berubah, RA003 kursi habis, RA006 tanpa akses, …) menang
  // supaya aplikasi menerima status yang benar (409/404/403).
  const status = mapped?.status ?? err?.status ?? 500;
  const cleanMessage = message.replace(/^[A-Z_]+[0-9]*:\s*/, "");

  console.error("[api-error]", { sqlstate, appCode, message, details });
  return errorResponse(appCode ?? "server_error", cleanMessage, status, details, origin);
}

export async function readJson<T>(req: Request): Promise<T> {
  try {
    const text = await req.text();
    if (!text) return {} as T;
    return JSON.parse(text) as T;
  } catch {
    throw Object.assign(new Error("Body permintaan bukan JSON yang sah"), {
      code: "RA001",
      status: 400,
    });
  }
}

export function optionsResponse(req: Request): Response {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(req.headers.get("origin")),
  });
}
