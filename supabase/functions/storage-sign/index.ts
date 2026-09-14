/**
 * Edge Function: storage-sign  (langkah 11 rencana migrasi)
 *
 * Supabase Storage dipakai untuk foto rute/paket wisata, foto profil, dan bukti
 * transfer. Karena login memakai Firebase (bukan Supabase Auth), izin tulis
 * diberikan lewat tautan bertanda tangan yang dibuat fungsi ini setelah
 * Firebase ID token diverifikasi — bukan lewat policy `auth.uid()`.
 *
 * Aksi:
 *   upload-url    → tautan unggah sementara untuk aplikasi
 *   download-url  → tautan unduh sementara (bukti transfer hanya untuk pemilik)
 *   public-url    → URL permanen untuk berkas publik (gambar katalog)
 *
 * Contoh:
 *   POST /functions/v1/storage-sign
 *   Authorization: Bearer <firebase id token>
 *   {"action":"upload-url","kind":"payment_proof","kode":"RARA-9X2K7Q",
 *    "filename":"bukti.jpg","content_type":"image/jpeg"}
 */
import { createSignedUploadUrl, createSignedUrl, publicObjectUrl, rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface StoragePayload {
  action?: "upload-url" | "download-url" | "public-url";
  kind?: "route" | "tour" | "rental" | "vehicle" | "avatar" | "payment_proof" | "other";
  bucket?: string;
  path?: string;
  filename?: string;
  kode?: string;
  content_type?: string;
  expires_in?: number;
}

/** Bucket & awalan folder per jenis berkas. */
const RULES: Record<string, { bucket: string; prefix: string; public: boolean }> = {
  route: { bucket: "public-assets", prefix: "routes", public: true },
  tour: { bucket: "public-assets", prefix: "tours", public: true },
  rental: { bucket: "public-assets", prefix: "rentals", public: true },
  vehicle: { bucket: "public-assets", prefix: "vehicles", public: true },
  avatar: { bucket: "avatars", prefix: "users", public: true },
  payment_proof: { bucket: "payment-proofs", prefix: "bookings", public: false },
  other: { bucket: "public-assets", prefix: "misc", public: true },
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson<StoragePayload>(req);
    const action = body.action ?? "upload-url";
    const kind = body.kind ?? "other";
    const rule = RULES[kind] ?? RULES.other;

    let userId = await rpc<string | null>("resolve_user_id", { p_firebase_uid: firebaseUser.uid });
    if (!userId) {
      const synced = await rpc<{ user: { id: string } }>("auth_user_sync", {
        p_firebase_uid: firebaseUser.uid,
      });
      userId = synced.user.id;
    }

    if (action === "public-url") {
      const path = body.path ?? "";
      if (!path) return errorResponse("validation_error", "path wajib diisi", 400, undefined, origin);
      return json({ ok: true, public_url: publicObjectUrl(rule.bucket, sanitize(path)) }, { origin });
    }

    // Bukti transfer harus terkait pesanan milik pemanggil.
    let bookingId: string | null = null;
    if (kind === "payment_proof") {
      if (!body.kode) {
        return errorResponse("validation_error", "kode pesanan wajib diisi untuk bukti transfer", 400, undefined, origin);
      }
      const booking = await rpc<{ id: string } | null>("find_booking", {
        p_user_id: userId,
        p_kode: body.kode,
      });
      if (!booking) {
        return errorResponse("not_found", "Pesanan tidak ditemukan", 404, undefined, origin);
      }
      bookingId = booking.id;
    }

    const path = sanitize(body.path ?? defaultPath(kind, userId, body));

    if (action === "download-url") {
      const asset = await rpc<{ allowed?: boolean; bucket?: string } | null>("media_asset_for_user", {
        p_path: path,
        p_user_id: userId,
      });
      if (asset && asset.allowed === false) {
        return errorResponse("forbidden", "Tidak berhak mengunduh berkas ini", 403, undefined, origin);
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
      p_metadata: { requested_by: userId },
    });

    return json({
      ok: true,
      bucket: rule.bucket,
      path,
      upload_url: uploadUrl,
      token,
      public_url: rule.public ? publicObjectUrl(rule.bucket, path) : null,
      max_size_bytes: kind === "avatar" ? 2_097_152 : 5_242_880,
    }, { status: 201, origin });
  } catch (error) {
    return handleError(error, origin);
  }
});

function clampExpiry(value?: number): number {
  if (!value || !Number.isFinite(value)) return 600;
  return Math.min(Math.max(Math.trunc(value), 60), 86_400);
}

/** Cegah path keluar folder (`../`) atau berisi karakter aneh. */
function sanitize(path: string): string {
  const clean = path
    .replace(/\\/g, "/")
    .split("/")
    .filter((part) => part !== "" && part !== "." && part !== "..")
    .join("/")
    .replace(/[^A-Za-z0-9/._-]/g, "_");
  if (!clean) {
    throw Object.assign(new Error("Path berkas tidak sah"), { status: 400, code: "RA001" });
  }
  return clean;
}

function defaultPath(
  kind: string,
  userId: string,
  body: StoragePayload,
): string {
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
