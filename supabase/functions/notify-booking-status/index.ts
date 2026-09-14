/**
 * Edge Function: notify-booking-status  (langkah 9 rencana migrasi)
 *
 * Mengirim notifikasi FCM ketika status pesanan berubah.
 *
 * Dipanggil dari dua arah:
 *   1. Trigger PostgreSQL (`bookings_enqueue_notification`) saat status berubah
 *      → body {"job_id":"..."} (via pg_net).
 *   2. Cron / Scheduled Function setiap beberapa menit
 *      → body {"drain": true} untuk mengirim job yang masih mengantre
 *        (mis. Edge Function sempat mati atau token perangkat baru masuk).
 *
 * Keamanan: hanya boleh dipanggil dengan header `x-webhook-secret` yang cocok
 * ATAU oleh staf yang login (Firebase token) — supaya tidak ada pihak lain yang
 * bisa memicu pengiriman notifikasi.
 *
 * Setelan yang dibutuhkan (Secrets):
 *   NOTIFY_WEBHOOK_SECRET, FIREBASE_SERVICE_ACCOUNT
 */
import { rpc } from "../_shared/db.ts";
import { sendToDevices } from "../_shared/fcm.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { env } from "../_shared/env.ts";
import { errorResponse, handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface NotifyPayload {
  job_id?: string;
  drain?: boolean;
  limit?: number;
}

interface Job {
  job_id: string;
  user_id: string;
  booking_id?: string | null;
  title: string;
  body?: string | null;
  data?: Record<string, string> | null;
  attempts: number;
  max_attempts: number;
  tokens: string[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    if (!(await isAuthorized(req))) {
      return errorResponse("forbidden", "Pemanggil tidak berwenang", 403, undefined, origin);
    }

    const body = await readJson<NotifyPayload>(req);
    const jobs: Job[] = [];

    if (body.job_id) {
      const job = await rpc<Job | null>("prepare_notification_job", { p_job_id: body.job_id });
      // null = sudah dikirim/dilewati (mis. trigger ganda) → bukan error.
      if (job) jobs.push(job);
    } else {
      const claimed = await rpc<{ jobs: Job[]; count: number }>("claim_notification_jobs", {
        p_limit: body.limit ?? 25,
      });
      jobs.push(...(claimed.jobs ?? []));
    }

    const results = [];
    for (const job of jobs) {
      results.push(await deliver(job));
    }

    return json(
      {
        ok: true,
        processed: results.length,
        sent: results.filter((result) => result.ok).length,
        results,
      },
      { origin },
    );
  } catch (error) {
    return handleError(error, origin);
  }
});

async function deliver(job: Job) {
  const tokens = job.tokens ?? [];

  if (tokens.length === 0) {
    await rpc("complete_notification_job", {
      p_job_id: job.job_id,
      p_ok: false,
      p_error: "Tidak ada perangkat aktif untuk pengguna ini",
      p_provider_message_id: null,
      p_invalid_tokens: [],
    });
    return { job_id: job.job_id, ok: false, reason: "no_device" };
  }

  try {
    const result = await sendToDevices(tokens, {
      title: job.title,
      body: job.body ?? "",
      data: stringifyData(job.data),
    });

    const ok = result.sent > 0;

    await rpc("complete_notification_job", {
      p_job_id: job.job_id,
      p_ok: ok,
      p_error: ok ? null : (result.errors[0] ?? "FCM menolak semua token"),
      p_provider_message_id: result.providerMessageIds[0] ?? null,
      // Token yang sudah tidak terdaftar (app dihapus / token diganti)
      // otomatis dinonaktifkan supaya tidak dicoba terus.
      p_invalid_tokens: result.invalidTokens,
    });

    return {
      job_id: job.job_id,
      ok,
      sent: result.sent,
      failed: result.failed,
      invalid_tokens: result.invalidTokens.length,
    };
  } catch (error) {
    await rpc("complete_notification_job", {
      p_job_id: job.job_id,
      p_ok: false,
      p_error: String(error).slice(0, 400),
      p_provider_message_id: null,
      p_invalid_tokens: [],
    });
    return { job_id: job.job_id, ok: false, reason: "send_error" };
  }
}

/** FCM mensyaratkan data berupa string. */
function stringifyData(data?: Record<string, string> | null): Record<string, string> {
  const output: Record<string, string> = {};
  for (const [key, value] of Object.entries(data ?? {})) {
    output[key] = String(value);
  }
  return output;
}

async function isAuthorized(req: Request): Promise<boolean> {
  const secret = env().notifyWebhookSecret;
  const provided = req.headers.get("x-webhook-secret");
  if (secret && provided && provided === secret) return true;

  // Cadangan: staf yang login boleh memicu pengiriman manual.
  try {
    const firebaseUser = await requireFirebaseUser(req);
    const userId = await rpc<string | null>("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid,
    });
    if (!userId) return false;
    return (await rpc<string | null>("staff_role", { p_user_id: userId })) !== null;
  } catch {
    return false;
  }
}
