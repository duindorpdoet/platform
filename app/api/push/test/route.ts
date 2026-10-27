import { deliverScopedPush } from "@/lib/pwa/push-delivery";
import { z } from "zod";
import { runBoundedPushBatch } from "@/lib/pwa/push-security";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { accountClient } from "@/lib/account/server";
import { readBoundedJson } from "@/lib/http/bounded-json";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Target = { subscriptionId: string; fingerprint: string; endpoint: string; p256dh: string; auth_secret: string };

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const env = serverEnv();
    if (!env.NEXT_PUBLIC_VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY || !env.VAPID_SUBJECT) {
      throw new ApiError(503, "PUSH_NOT_CONFIGURED", "Pushmeldingen zijn nog niet geconfigureerd.");
    }

    const input=z.object({endpointHash:z.string().regex(/^[a-f0-9]{64}$/)}).strict().parse(await readBoundedJson(request));
    const {client:userClient,user}=await accountClient();
    const attempt=await userClient.schema("api").rpc("push_write_attempt");
    if(attempt.error||attempt.data?.allowed===false)throw new ApiError(429,"PUSH_RATE_LIMIT","Wacht even voordat je opnieuw een testmelding aanvraagt.");
    const proof=await userClient.schema("api").rpc("account_push_device",{_event_slug:env.EVENT_SLUG,_endpoint_hash:input.endpointHash});
    if(proof.error||!proof.data?.registered)throw new ApiError(403,"DEVICE_NOT_REGISTERED","Schrijf dit apparaat eerst in met dit account.");

    const privileged = createPrivilegedClient();
    if (!privileged) throw new ApiError(503, "PUSH_NOT_CONFIGURED", "Pushmeldingen zijn nog niet geconfigureerd.");
    const targetResult = await privileged.schema("api").rpc("push_test_targets_for_user", { _user_id: user.id });
    if (targetResult.error) throw targetResult.error;
    const targets = ((targetResult.data ?? []) as Target[]).filter(target=>target.subscriptionId===proof.data.subscriptionId);
    if (targets.length === 0) throw new ApiError(409, "NO_ACTIVE_SUBSCRIPTION", "Zet meldingen eerst aan op dit apparaat.");

    const results=await runBoundedPushBatch(targets,(target,signal)=>deliverScopedPush(target,
      {notificationId:null,claimToken:null,testUserId:user.id},JSON.stringify({
        title:"Testmelding van De Poorten",body:"Meldingen voor dit apparaat werken. Open je omgeving voor meer informatie.",
      }),signal));
    let delivered=0;
    for (const [target,result] of results) {
      if (result.success) delivered++;
      if (result.deferred) continue;
      const stored=await privileged.schema("api").rpc("push_subscription_delivery_record",{
        _endpoint:target.endpoint,_success:result.success,_error_code:result.error,_deactivate:result.deactivate,
      });
      if(stored.error)throw new ApiError(503,"PUSH_RESULT_NOT_STORED","De pushuitkomst kon niet worden vastgelegd. Controleer je apparaat voordat je opnieuw test.");
    }

    if (delivered === 0) throw new ApiError(502, "PUSH_DELIVERY_FAILED", "De testmelding kon niet worden afgeleverd.");
    return apiSuccess({ accepted: delivered });
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
