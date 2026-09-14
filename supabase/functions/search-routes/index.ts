/**
 * Edge Function: search-routes  (langkah 5 rencana migrasi)
 *
 * API katalog publik dengan pagination. Menggantikan data statis
 * (lib/data/dummy_data.dart) sehingga admin bisa mengubah rute/harga/jadwal
 * tanpa merilis ulang aplikasi.
 *
 * Aksi:
 *   search   → cari rute (pagination, filter kursi, urutan harga)
 *   detail   → detail satu rute + jadwalnya
 *   cities   → daftar kota untuk dropdown
 *   rentals  → paket sewa mobil
 *   tours    → paket wisata
 *   vehicles → daftar armada
 *
 * Semua aksi boleh dipanggil tanpa login (harga & jadwal memang publik).
 *
 * Contoh:
 *   POST /functions/v1/search-routes
 *   {"action":"search","origin":"Surabaya","destination":"Jakarta",
 *    "date":"2026-09-20","passengers":2,"sort":"price_asc","limit":10,"offset":0}
 */
import { rpc } from "../_shared/db.ts";
import { handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface SearchPayload {
  action?: "search" | "detail" | "cities" | "rentals" | "tours" | "vehicles";
  origin?: string | null;
  destination?: string | null;
  date?: string | null;
  passengers?: number | null;
  q?: string | null;
  sort?: string | null;
  limit?: number | null;
  offset?: number | null;
  key?: string | null;
  slug?: string | null;
  route_id?: string | null;
  city?: string | null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    // Katalog publik: boleh GET (query string) maupun POST (JSON).
    const payload: SearchPayload = req.method === "GET"
      ? fromQuery(new URL(req.url).searchParams)
      : await readJson<SearchPayload>(req);

    switch (payload.action ?? "search") {
      case "cities":
        return json(
          { ok: true, items: await rpc("catalog_cities", { p_q: payload.q ?? null }) },
          { origin },
        );

      case "detail": {
        const key = payload.key ?? payload.slug ?? payload.route_id ?? null;
        if (!key) {
          return json(
            { error: { code: "validation_error", message: "key/slug/route_id wajib diisi" } },
            { status: 400, origin },
          );
        }
        const detail = await rpc("get_route_detail", {
          p_key: key,
          p_date: payload.date ?? null,
        });
        if (!detail) {
          return json(
            { error: { code: "not_found", message: "Rute tidak ditemukan" } },
            { status: 404, origin },
          );
        }
        return json({ ok: true, route: detail }, { origin });
      }

      case "rentals":
        return json({
          ok: true,
          ...(await rpc("list_rental_packages", {
            p_city: payload.city ?? payload.origin ?? null,
            p_q: payload.q ?? null,
            p_limit: payload.limit ?? 20,
            p_offset: payload.offset ?? 0,
          }) as object),
        }, { origin });

      case "tours":
        return json({
          ok: true,
          ...(await rpc("list_tour_packages", {
            p_q: payload.q ?? null,
            p_limit: payload.limit ?? 20,
            p_offset: payload.offset ?? 0,
          }) as object),
        }, { origin });

      case "vehicles":
        return json(
          { ok: true, items: await rpc("list_vehicles", {}) },
          { origin },
        );

      default:
        return json({
          ok: true,
          ...(await rpc("search_routes", {
            p_origin: payload.origin ?? null,
            p_destination: payload.destination ?? null,
            p_date: payload.date ?? null,
            p_passengers: payload.passengers ?? 1,
            p_q: payload.q ?? null,
            p_sort: payload.sort ?? "popular",
            p_limit: payload.limit ?? 10,
            p_offset: payload.offset ?? 0,
          }) as object),
        }, { origin });
    }
  } catch (error) {
    return handleError(error, origin);
  }
});

function fromQuery(params: URLSearchParams): SearchPayload {
  const num = (key: string): number | null => {
    const raw = params.get(key);
    if (raw === null || raw === "") return null;
    const value = Number(raw);
    return Number.isFinite(value) ? value : null;
  };
  return {
    action: (params.get("action") ?? "search") as SearchPayload["action"],
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
    city: params.get("city"),
  };
}
