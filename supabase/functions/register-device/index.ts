/**
 * Edge Function: register-device  (langkah 8 rencana migrasi)
 *
 * Menyimpan token FCM ke `public.user_devices` (satu token = satu baris).
 * Pengganti array `fcmTokens` di Firestore: token basi bisa dinonaktifkan,
 * perangkat yang berganti akun otomatis berpindah pemilik.
 *
 * Contoh:
 *   POST /functions/v1/register-device
 *   Authorization: Bearer <firebase id token>
 *   {"action":"register","fcm_token":"...","platform":"android","app_version":"1.0.0+1"}
 */
import { rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface DevicePayload {
  action?: "register" | "unregister";
  fcm_token?: string;
  platform?: string;
  device_model?: string;
  app_version?: string;
  locale?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = await readJson<DevicePayload>(req);
    const action = body.action ?? "register";

    let userId = await rpc<string | null>("resolve_user_id", {
      p_firebase_uid: firebaseUser.uid,
    });
    if (!userId) {
      const synced = await rpc<{ user: { id: string } }>("auth_user_sync", {
        p_firebase_uid: firebaseUser.uid,
      });
      userId = synced.user.id;
    }

    if (action === "unregister") {
      const result = await rpc<{ deactivated: number }>("unregister_user_device", {
        p_user_id: userId,
        p_fcm_token: body.fcm_token ?? null,
      });
      return json({ ok: true, ...result }, { origin });
    }

    if (!body.fcm_token) {
      return json(
        { error: { code: "validation_error", message: "fcm_token wajib diisi" } },
        { status: 400, origin },
      );
    }

    const device = await rpc("register_user_device", {
      p_user_id: userId,
      p_fcm_token: body.fcm_token,
      p_platform: body.platform ?? "unknown",
      p_device_model: body.device_model ?? null,
      p_app_version: body.app_version ?? null,
      p_locale: body.locale ?? null,
    });

    return json({ ok: true, device }, { origin });
  } catch (error) {
    return handleError(error, origin);
  }
});
