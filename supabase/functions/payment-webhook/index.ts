/**
 * Edge Function: payment-webhook  (langkah 10 rencana migrasi)
 *
 * Menerima callback dari penyedia pembayaran, memverifikasi tanda tangan, lalu
 * menyerahkan ke `public.apply_payment_event` yang idempoten terhadap
 * (provider, event_id) — callback yang dikirim ulang provider tidak akan
 * membuat pembayaran dihitung dua kali.
 *
 * URL callback di dashboard provider:
 *   Midtrans : https://<project>.supabase.co/functions/v1/payment-webhook?provider=midtrans
 *   Xendit   : https://<project>.supabase.co/functions/v1/payment-webhook?provider=xendit
 *   Lainnya  : ...?provider=hmac   (header x-signature = HMAC-SHA256 body)
 *
 * Catatan pengujian lokal: kirim ulang callback yang sama dua kali — yang kedua
 * harus mengembalikan {"duplicate": true} tanpa mengubah data.
 */
import { rpc } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { parseWebhook } from "../_shared/payments.ts";
import { errorResponse, handleError, json, optionsResponse } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);

  try {
    if (req.method !== "POST") {
      return errorResponse("validation_error", "Gunakan metode POST", 405);
    }

    const url = new URL(req.url);
    let provider = (url.searchParams.get("provider") ?? "").toLowerCase();

    if (!provider) {
      // Deteksi sederhana bila URL provider tidak memakai parameter.
      const clone = req.clone();
      const peek = await clone.text();
      if (peek.includes("signature_key") || peek.includes("transaction_status")) {
        provider = "midtrans";
      } else if (peek.includes("callback") || peek.includes("external_id")) {
        provider = "xendit";
      } else {
        provider = "hmac";
      }
      return await process(new Request(req.url, { method: "POST", headers: req.headers, body: peek }), provider, req);
    }

    return await process(req, provider, req);
  } catch (error) {
    return handleError(error);
  }
});

async function process(req: Request, provider: string, original: Request): Promise<Response> {
  const parsed = await parseWebhook(provider, req);

  // Jalur istimewa untuk pemeliharaan: pemanggil dengan x-webhook-secret yang
  // benar dianggap sah (mis. mengirim ulang callback yang gagal diproses).
  const secret = env().notifyWebhookSecret;
  const provided = original.headers.get("x-webhook-secret");
  const trustedCaller = Boolean(secret) && provided === secret;
  const signatureValid = parsed.signatureValid || trustedCaller;

  if (!signatureValid) {
    console.warn("[payment-webhook] tanda tangan tidak sah", {
      provider: parsed.provider,
      eventId: parsed.eventId,
    });
    return errorResponse(
      "invalid_signature",
      "Tanda tangan webhook tidak sah",
      401,
      { provider: parsed.provider, event_id: parsed.eventId },
    );
  }

  if (!parsed.eventId) {
    return errorResponse("validation_error", "event_id tidak ditemukan pada payload webhook", 400);
  }

  const result = await rpc<Record<string, unknown>>("apply_payment_event", {
    p_provider: parsed.provider,
    p_event_id: parsed.eventId,
    p_event_type: parsed.eventType,
    p_status: parsed.status,
    p_provider_reference: parsed.providerReference,
    p_amount: parsed.amount,
    p_payload: parsed.payload,
    p_signature_valid: signatureValid,
    p_failure_reason: parsed.failureReason ?? null,
  });

  // Selalu 200 untuk pembayaran yang tidak dikenal supaya provider tidak
  // mengulang selamanya; masalahnya sudah tercatat di payment_events.
  return json({ ok: true, provider: parsed.provider, ...result });
}
