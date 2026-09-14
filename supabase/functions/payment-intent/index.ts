/**
 * Edge Function: payment-intent  (langkah 10 rencana migrasi)
 *
 * Membuat "tagihan" untuk sebuah pesanan:
 *   * provider midtrans → membuat tautan pembayaran Snap (QRIS/VA/dll.)
 *   * provider manual   → mencatat transfer manual (dicocokkan admin)
 *
 * Juga menyediakan penandaan transfer manual sebagai diterima (khusus staf),
 * yang tetap melalui `apply_payment_event` sehingga idempoten dan tercatat.
 *
 * Contoh pelanggan:
 *   POST /functions/v1/payment-intent
 *   Authorization: Bearer <firebase id token>
 *   {"action":"create","kode":"RARA-9X2K7Q","provider":"midtrans","method":"qris"}
 *
 * Contoh staf (transfer manual sudah masuk):
 *   {"action":"manual-confirm","kode":"RARA-9X2K7Q","amount":300000,"method":"Transfer Bank"}
 */
import { rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import {
  createMidtransSnapTransaction,
  type PaymentProvider,
} from "../_shared/payments.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface PaymentPayload {
  action?: "create" | "manual-confirm" | "status";
  kode?: string;
  provider?: PaymentProvider;
  method?: string;
  amount?: number;
  reference?: string;
}

interface PaymentRecord {
  id: string;
  provider_reference: string | null;
  amount: number;
  status: string;
  checkout_url: string | null;
}

interface CreatePaymentResult {
  payment: PaymentRecord;
  booking: { kode: string; total: number; status: string; payment_status: string };
  remaining_amount: number;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson<PaymentPayload>(req);
    const action = body.action ?? "create";

    const userId = await rpc<string | null>("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid,
    });
    if (!userId) {
      return errorResponse("unauthorized", "Akun belum tersinkron. Login ulang.", 401, undefined, origin);
    }

    if (action === "status") {
      return json({
        ok: true,
        ...(await rpc("payment_status_for_booking", {
          p_user_id: userId,
          p_kode: body.kode ?? null,
        }) as object),
      }, { origin });
    }

    if (action === "manual-confirm") {
      const role = await rpc<string | null>("staff_role", { p_user_id: userId });
      if (!role) {
        return errorResponse(
          "forbidden",
          "Hanya staf yang boleh menandai transfer manual sudah diterima",
          403,
          undefined,
          origin,
        );
      }

      // Pesanan bisa milik pelanggan lain → pakai jalur staf.
      const created = await rpc<CreatePaymentResult>("admin_create_payment", {
        p_admin_user_id: userId,
        p_kode: body.kode ?? null,
        p_provider: "manual",
        p_method: body.method ?? "Transfer Bank",
        p_amount: body.amount ?? null,
        p_provider_reference: body.reference ?? null,
        p_checkout_url: null,
        p_expires_at: null,
        p_raw_response: { confirmed_by: role },
      });

      // event_id unik per tagihan+nominal → klik ganda staf tidak dobel catat.
      const eventId = `manual:${created.payment.id}:${created.payment.amount}`;
      const applied = await rpc("apply_payment_event", {
        p_provider: "manual",
        p_event_id: eventId,
        p_event_type: "manual.transfer_received",
        p_status: "paid",
        p_provider_reference: created.payment.provider_reference,
        p_amount: created.payment.amount,
        p_payload: { confirmed_by: role, confirmed_at: new Date().toISOString() },
        p_signature_valid: true,   // staf terverifikasi = pengganti tanda tangan provider
        p_failure_reason: null,
      });

      return json({ ok: true, confirmed_by: role, ...(applied as object) }, { origin });
    }

    // ---------------------------------------------------------------- create
    const provider: PaymentProvider = body.provider ?? "manual";
    let created = await rpc<CreatePaymentResult>("create_payment", {
      p_user_id: userId,
      p_kode: body.kode ?? null,
      p_provider: provider,
      p_method: body.method ?? null,
      p_amount: body.amount ?? null,
      p_provider_reference: null,
      p_checkout_url: null,
      p_expires_at: null,
      p_raw_response: {},
    });

    let checkoutUrl = created.payment.checkout_url;
    let providerReference = created.payment.provider_reference;

    if (provider === "midtrans") {
      const snap = await createMidtransSnapTransaction({
        orderId: created.payment.provider_reference ?? created.booking.kode,
        amount: created.payment.amount,
        itemName: `Travel ${created.booking.kode}`,
        customerName: "",
      });

      // Simpan tautan pembayaran ke baris tagihan yang sama (upsert).
      created = await rpc<CreatePaymentResult>("create_payment", {
        p_user_id: userId,
        p_kode: body.kode ?? null,
        p_provider: provider,
        p_method: body.method ?? null,
        p_amount: created.payment.amount,
        p_provider_reference: created.payment.provider_reference,
        p_checkout_url: snap.redirect_url ?? null,
        p_expires_at: null,
        p_raw_response: snap as unknown as Record<string, unknown>,
      });
      checkoutUrl = snap.redirect_url ?? created.payment.checkout_url;
      providerReference = created.payment.provider_reference;
    }

    return json({
      ok: true,
      payment: created.payment,
      booking: created.booking,
      remaining_amount: created.remaining_amount,
      checkout_url: checkoutUrl,
      provider_reference: providerReference,
      instructions: instructionsFor(provider, created),
    }, { status: 201, origin });
  } catch (error) {
    return handleError(error, origin);
  }
});

function instructionsFor(
  provider: PaymentProvider,
  created: CreatePaymentResult,
): Record<string, unknown> | null {
  if (provider === "midtrans") return null;
  return {
    provider: provider,
    amount: created.payment.amount,
    reference: created.payment.provider_reference,
    note: "Selesaikan transfer lalu kirim bukti ke admin via WhatsApp. Pesanan otomatis terkonfirmasi setelah dana diverifikasi.",
  };
}
