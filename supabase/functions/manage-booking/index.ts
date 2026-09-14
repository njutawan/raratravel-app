/**
 * Edge Function: manage-booking
 *
 * Semua operasi pesanan setelah pesanan dibuat (baca, batalkan, pantau
 * pembayaran) plus tindakan admin (daftar semua pesanan, ubah status,
 * ringkasan). Pengganti stream Firestore `bookings` di aplikasi.
 *
 * Aksi pelanggan:
 *   list             → riwayat pesanan milik pemanggil (pagination)
 *   detail           → satu pesanan (kode)
 *   cancel           → batalkan pesanan, kursi dikembalikan
 *   payment-status   → daftar tagihan + sisa yang harus dibayar
 *
 * Aksi admin/operator (peran diperiksa di database):
 *   admin-list       → semua pesanan (+ filter status/tanggal/pencarian)
 *   admin-set-status → ubah status (konfirmasi, selesai, batal, kedaluwarsa)
 *   admin-stats      → ringkasan dasbor
 *
 * Contoh:
 *   POST /functions/v1/manage-booking
 *   Authorization: Bearer <firebase id token>
 *   {"action":"list","limit":20,"offset":0,"status":"aktif"}
 */
import { rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface ManagePayload {
  action?: string;
  kode?: string;
  status?: string;
  note?: string;
  q?: string;
  date?: string;
  limit?: number;
  offset?: number;
}

const CUSTOMER_ACTIONS = new Set(["list", "detail", "cancel", "payment-status"]);
const STAFF_ACTIONS = new Set(["admin-list", "admin-set-status", "admin-stats"]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = req.method === "POST" ? await readJson<ManagePayload>(req) : fromQuery(req);
    const action = body.action ?? "list";

    const userId = await rpc<string | null>("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid,
    });
    if (!userId) {
      return errorResponse(
        "unauthorized",
        "Akun belum tersinkron. Buka aplikasi lalu login ulang.",
        401,
        undefined,
        origin,
      );
    }

    if (CUSTOMER_ACTIONS.has(action)) {
      switch (action) {
        case "detail": {
          const booking = await rpc("find_booking", { p_user_id: userId, p_kode: body.kode ?? null });
          if (!booking) {
            return errorResponse("not_found", "Pesanan tidak ditemukan", 404, undefined, origin);
          }
          return json({ ok: true, booking }, { origin });
        }
        case "cancel":
          return json({
            ok: true,
            ...(await rpc("cancel_booking", {
              p_user_id: userId,
              p_kode: body.kode ?? null,
              p_reason: body.note ?? null,
            }) as object),
          }, { origin });
        case "payment-status":
          return json({
            ok: true,
            ...(await rpc("payment_status_for_booking", {
              p_user_id: userId,
              p_kode: body.kode ?? null,
            }) as object),
          }, { origin });
        default:
          return json({
            ok: true,
            ...(await rpc("list_my_bookings", {
              p_user_id: userId,
              p_limit: body.limit ?? 20,
              p_offset: body.offset ?? 0,
              p_status: body.status ?? null,
            }) as object),
          }, { origin });
      }
    }

    if (STAFF_ACTIONS.has(action)) {
      switch (action) {
        case "admin-set-status":
          return json({
            ok: true,
            ...(await rpc("admin_set_booking_status", {
              p_admin_user_id: userId,
              p_kode: body.kode ?? null,
              p_status: body.status ?? null,
              p_note: body.note ?? null,
            }) as object),
          }, { origin });
        case "admin-stats":
          return json({
            ok: true,
            stats: await rpc("admin_stats", { p_admin_user_id: userId }),
          }, { origin });
        default:
          return json({
            ok: true,
            ...(await rpc("admin_list_bookings", {
              p_admin_user_id: userId,
              p_status: body.status ?? null,
              p_q: body.q ?? null,
              p_date: body.date ?? null,
              p_limit: body.limit ?? 25,
              p_offset: body.offset ?? 0,
            }) as object),
          }, { origin });
      }
    }

    return errorResponse("validation_error", `Aksi "${action}" tidak dikenal`, 400, undefined, origin);
  } catch (error) {
    return handleError(error, origin);
  }
});

function fromQuery(req: Request): ManagePayload {
  const params = new URL(req.url).searchParams;
  const num = (key: string): number | undefined => {
    const value = Number(params.get(key));
    return Number.isFinite(value) ? value : undefined;
  };
  return {
    action: params.get("action") ?? "list",
    kode: params.get("kode") ?? undefined,
    status: params.get("status") ?? undefined,
    q: params.get("q") ?? undefined,
    date: params.get("date") ?? undefined,
    limit: num("limit"),
    offset: num("offset"),
  };
}
