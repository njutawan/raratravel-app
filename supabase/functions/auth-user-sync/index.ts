/**
 * Edge Function: auth-user-sync  (langkah 4 rencana migrasi)
 *
 * Jembatan Firebase Auth → Supabase:
 *   1. Verifikasi Firebase ID token (Authorization: Bearer <idToken>).
 *   2. Buat/perbarui baris `public.users` dengan kunci `firebase_uid`.
 *   3. Daftarkan token FCM perangkat bila dikirim.
 *   4. Kembalikan profil lengkap + peran (role) untuk aplikasi.
 *
 * Aplikasi memanggil ini sekali setiap selesai login.
 *
 * Contoh:
 *   POST /functions/v1/auth-user-sync
 *   Authorization: Bearer <firebase id token>
 *   {"action":"sync","full_name":"Budi","fcm_token":"...","platform":"android"}
 */
import { rpc } from "../_shared/db.ts";
import { requireFirebaseUser } from "../_shared/firebase.ts";
import { handleError, json, optionsResponse, readJson } from "../_shared/http.ts";

interface SyncPayload {
  action?: "sync" | "profile" | "unregister-device";
  full_name?: string;
  phone?: string;
  fcm_token?: string;
  platform?: string;
  device_model?: string;
  app_version?: string;
  locale?: string;
}

interface SyncResult {
  user: {
    id: string;
    firebase_uid: string;
    full_name: string;
    phone: string;
    email: string;
    photo_url?: string | null;
    role: string;
    is_active: boolean;
    created_at: string;
    last_login_at?: string | null;
  };
  is_new: boolean;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return optionsResponse(req);
  const origin = req.headers.get("origin");

  try {
    const firebaseUser = await requireFirebaseUser(req);
    const body = req.method === "POST" ? await readJson<SyncPayload>(req) : {};
    const action = body.action ?? "sync";

    if (action === "unregister-device") {
      const result = await rpc<{ deactivated: number }>("unregister_user_device", {
        p_user_id: await userId(firebaseUser.uid),
        p_fcm_token: body.fcm_token ?? null,
      });
      return json({ ok: true, ...result }, { origin });
    }

    const result = await rpc<SyncResult>("auth_user_sync", {
      p_firebase_uid: firebaseUser.uid,
      p_full_name: body.full_name ?? firebaseUser.name ?? null,
      p_phone: body.phone ?? firebaseUser.phone ?? null,
      p_email: firebaseUser.email ?? null,
      p_photo_url: firebaseUser.picture ?? null,
      p_platform: null,
      p_app_version: body.app_version ?? null,
    });

    let device: unknown = null;
    if (body.fcm_token) {
      device = await rpc("register_user_device", {
        p_user_id: result.user.id,
        p_fcm_token: body.fcm_token,
        p_platform: body.platform ?? "unknown",
        p_device_model: body.device_model ?? null,
        p_app_version: body.app_version ?? null,
        p_locale: body.locale ?? null,
      });
    }

    return json(
      {
        ok: true,
        user: result.user,
        is_new: result.is_new,
        device,
        // Aplikasi memakai ini untuk memutuskan tampilan admin/operator.
        is_staff: ["operator", "finance", "admin", "super_admin"].includes(result.user.role),
      },
      { origin },
    );
  } catch (error) {
    return handleError(error, origin);
  }
});

/** Firebase UID → users.id (dibuat lebih dulu bila belum ada). */
async function userId(firebaseUid: string): Promise<string> {
  const existing = await rpc<string | null>("resolve_user_id", { p_firebase_uid: firebaseUid });
  if (existing) return existing;
  const created = await rpc<SyncResult>("auth_user_sync", { p_firebase_uid: firebaseUid });
  return created.user.id;
}
