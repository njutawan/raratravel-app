/**
 * Edge Function: create-booking  (langkah 7 rencana migrasi)
 *
 * Satu-satunya pintu masuk pembuatan pesanan. Yang penting di sini:
 *   * Harga, diskon, dan sisa kursi dihitung ULANG di PostgreSQL
 *     (`public.create_booking`) — total kiriman aplikasi hanya dipakai untuk
 *     mendeteksi harga yang sudah berubah (respons 409 price_mismatch).
 *   * Idempotency key membuat permintaan ulang (jaringan putus, tombol dobel)
 *     menghasilkan pesanan yang sama, bukan pesanan ganda.
 *   * Rem laju sederhana menahan script yang membuat pesanan bertubi-tubi.
 *   * Kursi dikunci dengan SELECT ... FOR UPDATE, jadi dua pemesanan
 *     bersamaan tidak bisa mengambil kursi yang sama.
 *
 * Contoh:
 *   POST /functions/v1/create-booking
 *   Authorization: Bearer <firebase id token>
 *   {
 *     "idempotency_key": "9f2c...",        // UUID dari aplikasi
 *     "route_id": "...",                    // atau origin/destination
 *     "origin": "Surabaya", "destination": "Jakarta",
 *     "travel_date": "2026-09-20", "departure_time": "06.00",
 *     "seats": 2,
 *     "contact_name": "Budi", "contact_phone": "0812...",
 *     "pickup_address": "...", "dropoff_address": "...",
 *     "payment_method": "Transfer Bank", "promo_code": "RARAHEMAT",
 *     "client_total": 850000
 *   }
 */
import { rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface BookingPayload {
  idempotency_key?: string;
  kode?: string;
  route_id?: string;
  origin?: string;
  destination?: string;
  asal?: string;
  tujuan?: string;
  travel_date?: string;
  tanggal?: string;
  departure_time?: string;
  jam?: string;
  seats?: number;
  kursi?: number;
  seat_numbers?: Array<number | string>;
  contact_name?: string;
  nama?: string;
  contact_phone?: string;
  wa?: string;
  contact_email?: string;
  pickup_address?: string;
  jemput?: string;
  dropoff_address?: string;
  antar?: string;
  notes?: string;
  catatan?: string;
  payment_method?: string;
  metodeBayar?: string;
  promo_code?: string;
  promo?: string;
  client_total?: number;
  total?: number;
  service_type?: string;
  source?: string;
}

/** Rem laju: maksimal 8 pesanan per jam per akun. */
const MAX_BOOKINGS_PER_HOUR = 8;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson<BookingPayload>(req);

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

    const rate = await rpc<{ allowed: boolean; count: number; max: number }>("booking_rate_ok", {
      p_user_id: userId,
      p_max: MAX_BOOKINGS_PER_HOUR,
      p_window_minutes: 60,
    });
    if (!rate.allowed) {
      return errorResponse(
        "rate_limited",
        "Terlalu banyak pesanan dalam waktu singkat. Coba lagi sebentar lagi atau hubungi admin.",
        429,
        rate,
        origin,
      );
    }

    const result = await rpc("create_booking", {
      p_user_id: userId,
      p_payload: normalize(body),
    });

    return json({ ok: true, ...(result as object) }, { status: 201, origin });
  } catch (error) {
    return handleError(error, origin);
  }
});

/**
 * Rapikan payload: terima penamaan aplikasi (Indonesia) maupun penamaan baru,
 * buang nilai kosong, dan JANGAN pernah meneruskan field yang bukan wewenang
 * klien (mis. price_per_seat) ke database.
 */
function normalize(body: BookingPayload): Record<string, unknown> {
  const pick = <T>(...values: Array<T | undefined | null>): T | null => {
    for (const value of values) {
      if (value !== undefined && value !== null && `${value}`.trim() !== "") {
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
    source: "app",
  };
}
