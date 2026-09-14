/**
 * Edge Function: admin-import  (langkah 11 rencana migrasi)
 *
 * Perkakas admin:
 *   catalog        → impor/ubah kota, armada, rute, jadwal, paket sewa & wisata
 *   legacy-bookings→ pindahkan riwayat Firestore ke PostgreSQL (langkah 6)
 *   upload-image   → unggah gambar katalog langsung dari server
 *
 * Peran diperiksa di database (`require_staff`) sehingga tidak bisa dilewati
 * dari sisi klien, walau seseorang memodifikasi aplikasinya.
 *
 * Contoh impor katalog:
 *   POST /functions/v1/admin-import
 *   Authorization: Bearer <firebase id token>
 *   {"action":"catalog",
 *    "payload":{"cities":[{"name":"Surabaya"}],
 *               "routes":[{"origin":"Surabaya","destination":"Jakarta",
 *                          "base_price":450000,"departure_times":["06.00","19.00"]}]}}
 *
 * Contoh impor riwayat (kering dulu, baru sungguhan):
 *   {"action":"legacy-bookings","dry_run":true,"bookings":[{...}]}
 */
import { publicObjectUrl, recordUpload, rpc, uploadObject } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface ImportPayload {
  action?: "catalog" | "legacy-bookings" | "upload-image" | "stats";
  payload?: Record<string, unknown>;
  bookings?: Array<Record<string, unknown>>;
  dry_run?: boolean;
  kind?: "route" | "tour" | "rental" | "vehicle";
  path?: string;
  image_base64?: string;
  content_type?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson<ImportPayload>(req);
    const action = body.action ?? "catalog";

    const userId = await rpc<string | null>("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid,
    });
    if (!userId) {
      return errorResponse("unauthorized", "Akun belum tersinkron. Login ulang.", 401, undefined, origin);
    }

    // Gerbang peran: pesan penolakan datang dari database (RA006).
    const role = await rpc<string | null>("staff_role", { p_user_id: userId });
    if (!role) {
      return errorResponse(
        "forbidden",
        "Akun ini tidak punya akses admin",
        403,
        { role: null },
        origin,
      );
    }

    switch (action) {
      case "legacy-bookings": {
        const batch = body.bookings ?? [];
        if (!Array.isArray(batch) || batch.length === 0) {
          return errorResponse("validation_error", "bookings harus berisi minimal satu pesanan", 400, undefined, origin);
        }
        if (batch.length > 500) {
          return errorResponse(
            "validation_error",
            "Maksimal 500 pesanan per permintaan — pecah menjadi beberapa batch",
            400,
            { jumlah: batch.length },
            origin,
          );
        }
        const result = await rpc("import_legacy_bookings", {
          p_batch: batch,
          p_dry_run: body.dry_run === true,
        });
        return json({ ok: true, imported_by: role, ...(result as object) }, { origin });
      }

      case "upload-image": {
        if (!body.path || !body.image_base64) {
          return errorResponse("validation_error", "path & image_base64 wajib diisi", 400, undefined, origin);
        }
        const kind = body.kind ?? "route";
        const bucket = "public-assets";
        const path = `${kind === "tour" ? "tours" : kind === "rental" ? "rentals" : kind === "vehicle" ? "vehicles" : "routes"
          }/${body.path}`.replace(/[^A-Za-z0-9/._-]/g, "_");

        const binary = atob(body.image_base64.replace(/^data:[^;]+;base64,/, ""));
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);

        const contentType = body.content_type ?? "image/jpeg";
        await uploadObject(bucket, path, bytes, contentType);
        await recordUpload({
          bucket,
          path,
          kind,
          uploadedBy: userId,
          mimeType: contentType,
          fileSize: bytes.byteLength,
        });

        return json({
          ok: true,
          bucket,
          path,
          public_url: publicObjectUrl(bucket, path),
          size_bytes: bytes.byteLength,
        }, { status: 201, origin });
      }

      case "stats":
        return json({ ok: true, stats: await rpc("admin_stats", { p_admin_user_id: userId }) }, { origin });

      default: {
        const payload = body.payload;
        if (!payload || typeof payload !== "object") {
          return errorResponse("validation_error", "payload katalog wajib diisi", 400, undefined, origin);
        }
        const result = await rpc("admin_import_catalog", {
          p_admin_user_id: userId,
          p_payload: payload,
        });
        return json({ ok: true, imported_by: role, ...(result as object) }, { origin });
      }
    }
  } catch (error) {
    return handleError(error, origin);
  }
});
