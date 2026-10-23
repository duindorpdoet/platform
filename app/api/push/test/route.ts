import { deliverScopedPush } from "@/lib/pwa/push-delivery";
import { runBoundedPushBatch } from "@/lib/pwa/push-security";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Target = { subscriptionId: string; fingerprint: string; endpoint: string; p256dh: string; auth_secret: string };

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

    const results=await runBoundedPushBatch(targets,(target,signal)=>deliverScopedPush(target,
      {notificationId:null,claimToken:null,testUserId:actor.userId},JSON.stringify({
        title:"Testmelding van De Poorten",body:"Meldingen voor dit apparaat werken. Open je omgeving voor meer informatie.",
      }),signal));
    let delivered=0;
    for (const [target,result] of results) {
      if (result.success) delivered++;
      if (result.deferred) continue;
      await privileged.schema("api").rpc("push_subscription_delivery_record",{
        _endpoint:target.endpoint,_success:result.success,_error_code:result.error,_deactivate:result.deactivate,
      });
    }

    if (delivered === 0) throw new ApiError(502, "PUSH_DELIVERY_FAILED", "De testmelding kon niet worden afgeleverd.");
    return apiSuccess({ delivered });
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
