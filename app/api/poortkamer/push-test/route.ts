import { z } from "zod";
import { runBoundedPushBatch } from "@/lib/pwa/push-security";
import { readBoundedJson } from "@/lib/http/bounded-json";
import { getActor } from "@/lib/auth/session";
import {
  ApiError,
  apiFailure,
  apiSuccess,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { deliverPortalPush } from "@/lib/pwa/portal-push";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const actor = await getActor();
    const client = await createClient();
    const privileged = createPrivilegedClient();
    if (!actor || !client || !privileged)
      throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in.");
    const attempt=await client.schema("api").rpc("push_write_attempt");
    if (attempt.error) throw new ApiError(503,"UNAVAILABLE","Probeer opnieuw.");
    if (!attempt.data?.allowed) throw new ApiError(429,"PUSH_RATE_LIMIT","Probeer het over een minuut opnieuw.");
    const {portalId}=z.object({portalId:z.uuid()}).strict().parse(await readBoundedJson(request));
    const access = await client
      .schema("api")
      .rpc("portal_push_test_authorize", { _portal_id: portalId });
    if (access.error)
      throw new ApiError(
        403,
        "NOT_AUTHORIZED",
        "De test is nu niet beschikbaar.",
      );
    const targets = await privileged
      .schema("api")
      .rpc("push_test_targets_for_user", { _user_id: actor.userId });
    if (targets.error)
      throw new ApiError(503, "UNAVAILABLE", "Probeer opnieuw.");
    const devices=(targets.data??[]) as Array<{subscriptionId:string;fingerprint:string;endpoint:string;p256dh:string;auth_secret:string}>;
    const results=await runBoundedPushBatch(devices,(target,signal)=>deliverPortalPush(
      {...target,auth:target.auth_secret},"test",crypto.randomUUID(),
      {notificationId:null,claimToken:null,testUserId:actor.userId},signal));
    let delivered=0;
    for (const [target,result] of results) {
      if (result.success) delivered++;
      if (result.deferred) continue;
      await privileged.schema("api").rpc("push_subscription_delivery_record",{
        _endpoint:target.endpoint,_success:result.success,_error_code:result.error,_deactivate:result.deactivate,
      });
    }
    if (!delivered)
      throw new ApiError(
        409,
        "NO_DELIVERY",
        "Zet meldingen eerst aan op dit apparaat.",
      );
    return apiSuccess({ delivered });
  } catch (error) {
    return apiFailure(error, correlationId(request));
  }
}
