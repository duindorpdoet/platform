import webPush from "web-push";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Target = { endpoint: string; p256dh: string; auth_secret: string };

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const env = serverEnv();
    if (env.APP_ENVIRONMENT !== "staging") throw new ApiError(404, "NOT_FOUND", "Deze test is alleen op staging beschikbaar.");
    if (!env.NEXT_PUBLIC_VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY || !env.VAPID_SUBJECT) {
      throw new ApiError(503, "PUSH_NOT_CONFIGURED", "Pushmeldingen zijn nog niet geconfigureerd.");
    }

    const actor = await getActor();
    const userClient = await createClient();
    if (!actor || !userClient) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in.");

    const access = await userClient.schema("api").rpc("admin_access_snapshot", { _event_slug: env.EVENT_SLUG });
    if (access.error) throw new ApiError(403, "NOT_AUTHORIZED", "Alleen een beheerder kan een testmelding sturen.");

    const privileged = createPrivilegedClient();
    if (!privileged) throw new ApiError(503, "PUSH_NOT_CONFIGURED", "Pushmeldingen zijn nog niet geconfigureerd.");
    const targetResult = await privileged.schema("api").rpc("push_test_targets_for_user", { _user_id: actor.userId });
    if (targetResult.error) throw targetResult.error;
    const targets = (targetResult.data ?? []) as Target[];
    if (targets.length === 0) throw new ApiError(409, "NO_ACTIVE_SUBSCRIPTION", "Zet meldingen eerst aan op dit apparaat.");

    webPush.setVapidDetails(env.VAPID_SUBJECT, env.NEXT_PUBLIC_VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);
    let delivered = 0;
    for (const target of targets) {
      let success = false;
      let deactivate = false;
      let errorCode: string | null = null;
      try {
        await webPush.sendNotification({
          endpoint: target.endpoint,
          keys: { p256dh: target.p256dh, auth: target.auth_secret },
        }, JSON.stringify({
          title: "Testmelding van De Poorten",
          body: "Meldingen voor dit apparaat werken. Open je omgeving voor meer informatie.",
        }));
        success = true;
        delivered += 1;
      } catch (cause) {
        const statusCode = typeof cause === "object" && cause && "statusCode" in cause ? Number(cause.statusCode) : 0;
        deactivate = statusCode === 404 || statusCode === 410;
        errorCode = statusCode ? `HTTP_${statusCode}` : "DELIVERY_FAILED";
      }
      await privileged.schema("api").rpc("push_subscription_delivery_record", {
        _endpoint: target.endpoint,
        _success: success,
        _error_code: errorCode,
        _deactivate: deactivate,
      });
    }

    if (delivered === 0) throw new ApiError(502, "PUSH_DELIVERY_FAILED", "De testmelding kon niet worden afgeleverd.");
    return apiSuccess({ delivered });
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
