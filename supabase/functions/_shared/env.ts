/**
 * Konfigurasi Edge Function Rara Travel.
 *
 * Semua nilai diambil dari Secrets Supabase (Dashboard → Edge Functions →
 * Manage secrets) sehingga TIDAK ada kredensial di dalam repositori.
 *
 * Wajib: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, FIREBASE_PROJECT_ID
 * Opsional (sesuai fitur yang dipakai):
 *   FIREBASE_SERVICE_ACCOUNT   → notifikasi FCM (JSON service account)
 *   NOTIFY_WEBHOOK_SECRET      → panggilan antar fungsi/cron
 *   MIDTRANS_SERVER_KEY        → pembayaran Midtrans
 *   XENDIT_CALLBACK_TOKEN      → pembayaran Xendit
 *   PAYMENT_HMAC_SECRET        → fallback tanda tangan HMAC untuk provider lain
 */

export interface Env {
  supabaseUrl: string;
  serviceRoleKey: string;
  firebaseProjectId: string;
  firebaseServiceAccount?: string;
  notifyWebhookSecret?: string;
  midtransServerKey?: string;
  midtransIsProduction: boolean;
  xenditCallbackToken?: string;
  paymentHmacSecret?: string;
  allowedOrigins: string[];
}

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value || value.trim() === "") {
    throw new Error(
      `Konfigurasi ${name} belum diisi. Set lewat Secrets Edge Function.`,
    );
  }
  return value.trim();
}

function optional(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value && value.trim() !== "" ? value.trim() : undefined;
}

export function env(): Env {
  return {
    supabaseUrl: required("SUPABASE_URL"),
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
    firebaseProjectId: required("FIREBASE_PROJECT_ID"),
    firebaseServiceAccount: optional("FIREBASE_SERVICE_ACCOUNT"),
    notifyWebhookSecret: optional("NOTIFY_WEBHOOK_SECRET"),
    midtransServerKey: optional("MIDTRANS_SERVER_KEY"),
    midtransIsProduction: optional("MIDTRANS_IS_PRODUCTION") === "true",
    xenditCallbackToken: optional("XENDIT_CALLBACK_TOKEN"),
    paymentHmacSecret: optional("PAYMENT_HMAC_SECRET"),
    // Aplikasi mobile tidak memakai CORS, tetapi panel admin web mungkin.
    allowedOrigins: (optional("ALLOWED_ORIGINS") ?? "*")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  };
}
