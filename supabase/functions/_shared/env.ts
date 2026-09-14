/**
 * Konfigurasi Edge Function Rara Travel.
 *
 * Semua nilai diambil dari Secrets Supabase (Dashboard → Edge Functions →
 * Manage secrets) sehingga TIDAK ada kredensial di dalam repositori.
 *
 * Wajib: SUPABASE_URL, kunci server (SUPABASE_SERVICE_ROLE_KEY atau
 *        SUPABASE_SECRET_KEYS/SUPABASE_SECRET_KEY), FIREBASE_PROJECT_ID
 * Catatan: SUPABASE_URL & kunci server sudah disediakan otomatis oleh platform
 * Supabase untuk setiap Edge Function — jadi biasanya tidak perlu di-set manual.
 * Opsional (sesuai fitur yang dipakai):
 *   FIREBASE_SERVICE_ACCOUNT   → notifikasi FCM (JSON service account)
 *   NOTIFY_WEBHOOK_SECRET      → panggilan antar fungsi/cron
 *   MIDTRANS_SERVER_KEY        → pembayaran Midtrans
 *   XENDIT_CALLBACK_TOKEN      → pembayaran Xendit
 *   PAYMENT_HMAC_SECRET        → fallback tanda tangan HMAC untuk provider lain
 */

export interface Env {
  supabaseUrl: string;
  /**
   * Kunci server: service_role (lama) atau secret key `sb_secret_…` (baru).
   * Diambil malas (lazy) saat dibaca — pembuatan balasan galat/CORS tidak
   * boleh ikut gagal hanya karena kunci belum diisi, supaya pesannya jelas.
   */
  readonly serviceRoleKey: string;
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

/**
 * Kunci server Supabase. Supabase menyediakan dua generasi kunci:
 *   * lama: `service_role` (JWT, diawali `eyJ…`) → SUPABASE_SERVICE_ROLE_KEY
 *   * baru: secret key (`sb_secret_…`) — hanya ada di proyek yang memakai
 *     kunci model baru. Platform menyuntikkannya sebagai kamus JSON
 *     `SUPABASE_SECRET_KEYS` = {"default":"sb_secret_…"} (lihat dokumentasi
 *     Supabase: Edge Functions → Environment Variables).
 * Keduanya diterima agar fungsi jalan di proyek lama maupun baru.
 */
/** Kunci server; dibaca saat dipakai (lihat catatan pada interface Env). */
function serviceRoleKey(): string {
  const langsung = optional("SUPABASE_SERVICE_ROLE_KEY") ?? optional("SUPABASE_SECRET_KEY");
  if (langsung) return langsung;

  const kamus = optional("SUPABASE_SECRET_KEYS");
  if (kamus) {
    try {
      const data = JSON.parse(kamus) as Record<string, unknown>;
      const nilai = data.default ?? Object.values(data)[0];
      if (typeof nilai === "string" && nilai.trim()) return nilai.trim();
    } catch {
      /* jatuh ke pesan galat di bawah supaya penyebabnya jelas */
    }
  }

  throw new Error(
    "Konfigurasi kunci server Supabase belum ada. Isi SUPABASE_SERVICE_ROLE_KEY " +
      "(kunci lama) atau sediakan SUPABASE_SECRET_KEYS / SUPABASE_SECRET_KEY " +
      "(kunci model baru `sb_secret_…`).",
  );
}

export function env(): Env {
  return {
    supabaseUrl: required("SUPABASE_URL"),
    get serviceRoleKey(): string {
      return serviceRoleKey();
    },
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
