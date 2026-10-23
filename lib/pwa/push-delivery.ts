import "server-only";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { sendSecurePush, type SafePushTarget, type PushResult } from "./push-security";

export type PushDeliveryScope = { notificationId: string | null; claimToken: string | null; testUserId?: string };
export async function deliverScopedPush(
  target: Pick<SafePushTarget,"subscriptionId"|"fingerprint">,
  scope: PushDeliveryScope, payload: string, signal: AbortSignal, ttl=300,
): Promise<PushResult> {
  const client=createPrivilegedClient();
  if (!client||signal.aborted) return {success:false,deactivate:false,error:"PUSH_UNAVAILABLE",deferred:true};
  const fresh=await client.schema("api").rpc("worker_push_target",{
    _notification:scope.notificationId,_subscription:target.subscriptionId,_fingerprint:target.fingerprint,
    _token:scope.claimToken,_test_user_id:scope.testUserId??null,
  }).abortSignal(signal);
  if (fresh.error) return {success:false,deactivate:false,error:"PUSH_RECHECK_FAILED",deferred:true};
  if (fresh.data?.blocked) return {success:false,deactivate:true,error:"UNSAFE_SUBSCRIPTION"};
  if (!fresh.data||signal.aborted) return {success:false,deactivate:false,error:"PUSH_TARGET_CHANGED",deferred:true};
  return sendSecurePush(fresh.data as SafePushTarget,payload,signal,ttl);
}
