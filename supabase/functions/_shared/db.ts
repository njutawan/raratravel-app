/**
 * Akses database & Storage lewat REST Supabase (service_role).
 *
 * Sengaja tanpa pustaka tambahan (tanpa supabase-js) supaya fungsi tetap
 * ringan, cepat dingin-start, dan tidak bergantung pada resolusi paket.
 * service_role melewati RLS — karena itu semua pemanggil WAJIB sudah
 * diverifikasi Firebase-nya sebelum memanggil helper di sini.
 */

import { env } from "./env.ts";

function headers(extra: Record<string, string> = {}): Record<string, string> {
  const { serviceRoleKey } = env();
  return {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    "Content-Type": "application/json",
    ...extra,
  };
}

interface PostgrestError {
  message?: string;
  code?: string;
  details?: string;
  hint?: string;
}

/** Panggil RPC PostgreSQL; error PostgREST diteruskan apa adanya. */
export async function rpc<T = unknown>(
  name: string,
  params: Record<string, unknown> = {},
  init: { method?: "POST" | "GET" } = {},
): Promise<T> {
  const { supabaseUrl } = env();
  const method = init.method ?? "POST";

  const response = method === "GET"
    ? await fetch(
      `${supabaseUrl}/rest/v1/rpc/${name}?${new URLSearchParams(
        Object.entries(params).map(([key, value]) => [key, String(value ?? "")]),
      )}`,
      { method: "GET", headers: headers() },
    )
    : await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify(params),
    });

  const text = await response.text();

  if (!response.ok) {
    let payload: PostgrestError = {};
    try {
      payload = text ? JSON.parse(text) : {};
    } catch {
      payload = { message: text };
    }
    throw Object.assign(new Error(payload.message ?? "Permintaan database gagal"), {
      code: payload.code,
      details: payload.details,
      hint: payload.hint,
      status: response.status,
    });
  }

  if (!text) return null as T;
  return JSON.parse(text) as T;
}

/** Ambil baris dari tabel (dipakai untuk pemeriksaan ringan). */
export async function selectOne<T>(
  table: string,
  filter: Record<string, string>,
  columns = "*",
): Promise<T | null> {
  const { supabaseUrl } = env();
  const query = new URLSearchParams({ select: columns, limit: "1" });
  for (const [key, value] of Object.entries(filter)) {
    query.append(key, `eq.${value}`);
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/${table}?${query}`, {
    headers: headers(),
  });
  if (!response.ok) {
    throw new Error(`Gagal membaca ${table}: ${await response.text()}`);
  }
  const rows = (await response.json()) as T[];
  return rows.length > 0 ? rows[0] : null;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/** URL publik (bucket publik saja). */
export function publicObjectUrl(bucket: string, path: string): string {
  const { supabaseUrl } = env();
  return `${supabaseUrl}/storage/v1/object/public/${bucket}/${encodeURI(path)}`;
}

/** URL sementara untuk mengunduh berkas privat (mis. bukti transfer). */
export async function createSignedUrl(
  bucket: string,
  path: string,
  expiresInSeconds = 600,
): Promise<string> {
  const { supabaseUrl } = env();
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/sign/${bucket}/${encodeURI(path)}`,
    {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ expiresIn: expiresInSeconds }),
    },
  );
  if (!response.ok) {
    throw new Error(`Gagal membuat tautan berkas: ${await response.text()}`);
  }
  const payload = (await response.json()) as { signedURL?: string };
  if (!payload.signedURL) throw new Error("Tautan berkas tidak diterima");
  return `${supabaseUrl}/storage/v1${payload.signedURL}`;
}

/** Tautan unggah sementara (aplikasi mengunggah langsung ke Storage). */
export async function createSignedUploadUrl(
  bucket: string,
  path: string,
): Promise<{ uploadUrl: string; token: string }> {
  const { supabaseUrl } = env();
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/upload/sign/${bucket}/${encodeURI(path)}`,
    { method: "POST", headers: headers(), body: JSON.stringify({}) },
  );
  if (!response.ok) {
    throw new Error(`Gagal membuat tautan unggah: ${await response.text()}`);
  }
  const payload = (await response.json()) as { url?: string; token?: string };
  if (!payload.url || !payload.token) {
    throw new Error("Tautan unggah tidak lengkap");
  }
  const uploadUrl = payload.url.startsWith("http")
    ? payload.url
    : `${supabaseUrl}/storage/v1${payload.url}`;
  return { uploadUrl, token: payload.token };
}

/** Unggah berkas dari server (dipakai impor katalog admin). */
export async function uploadObject(
  bucket: string,
  path: string,
  data: Uint8Array,
  contentType: string,
): Promise<void> {
  const { supabaseUrl } = env();
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/${bucket}/${encodeURI(path)}`,
    {
      method: "POST",
      headers: {
        ...headers(),
        "Content-Type": contentType,
        "x-upsert": "true",
      },
      body: data,
    },
  );
  if (!response.ok) {
    throw new Error(`Gagal mengunggah berkas: ${await response.text()}`);
  }
}

/** Catat berkas yang diunggah (dipakai fungsi admin & aplikasi). */
export async function recordUpload(params: {
  bucket: string;
  path: string;
  kind: string;
  ownerUserId?: string | null;
  bookingId?: string | null;
  uploadedBy?: string | null;
  mimeType?: string | null;
  fileSize?: number | null;
  isPublic?: boolean;
  metadata?: Record<string, unknown>;
}): Promise<unknown> {
  return await rpc("record_media_asset", {
    p_bucket: params.bucket,
    p_path: params.path,
    p_kind: params.kind,
    p_owner_user_id: params.ownerUserId ?? null,
    p_booking_id: params.bookingId ?? null,
    p_uploaded_by: params.uploadedBy ?? null,
    p_mime_type: params.mimeType ?? null,
    p_file_size: params.fileSize ?? null,
    p_is_public: params.isPublic ?? true,
    p_metadata: params.metadata ?? {},
  });
}
