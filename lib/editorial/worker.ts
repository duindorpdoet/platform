import "server-only";
import { deliverScopedPush } from "@/lib/pwa/push-delivery";
import { createPushBatchBudget, runBoundedPushBatch, type PushBatchBudget, type SafePushTarget } from "@/lib/pwa/push-security";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { editorialAllowlist } from "./server";
import { safeNewsDeepLink } from "./security";
type PushJob = {
  id: string;
  claimToken: string;
  url: string;
  versionId: string;
  targets: SafePushTarget[];
};
export async function editorialTick(budget:PushBatchBudget=createPushBatchBudget()) {
  const client = createPrivilegedClient();
  if (!client) return;
  const env = serverEnv();
  const { error } = await client.schema("api").rpc("worker_editorial_tick", {
    _mail_enabled: env.NEWSLETTER_SENDING_ENABLED === "true",
  });
  if (error) throw new Error("EDITORIAL_TICK_FAILED");
  if (
    env.WEB_PUSH_SENDING_ENABLED !== "true" || budget.remaining<=0 || Date.now()>=budget.deadline ||
    !env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ||
    !env.VAPID_PRIVATE_KEY ||
    !env.VAPID_SUBJECT
  )
    return;
  const claimed = await client
    .schema("api")
    .rpc("worker_claim_editorial_push", {
      _allowed_emails:
        env.APP_ENVIRONMENT === "production" ? null : [...editorialAllowlist()],
    });
  if (claimed.error) throw new Error("EDITORIAL_PUSH_CLAIM_FAILED");
  const jobs=(claimed.data??[]) as PushJob[];
  const items=jobs.flatMap(job=>job.targets.map(target=>({job,target})));
  const results=await runBoundedPushBatch(items,({job,target},signal)=>deliverScopedPush(target,
    {notificationId:job.id,claimToken:job.claimToken},JSON.stringify({
      title:"De Duindorpse Poorten",body:"Er staat een nieuw bericht voor je klaar.",
      url:safeNewsDeepLink(`${job.url}?push=${job.id}&device=${target.subscriptionId}`),tag:`news-${job.versionId}`,
    }),signal,3600),budget);
  for (const job of jobs) {
    let deferred=false;let attempted=false;
    for (const item of items.filter(item=>item.job===job)) {
      const result=results.get(item);
      if (!result||result.deferred) {deferred=true;continue;}
      attempted=true;
      const recorded=await client.schema("api").rpc("worker_record_editorial_push",{
        _id:job.id,_token:job.claimToken,_subscription:item.target.subscriptionId,
        _status:result.success?"sent_to_pushservice":result.deactivate?"invalid":"failed",_error:result.error,
      });
      if (recorded.error) throw new Error("EDITORIAL_PUSH_ACK_FAILED");
    }
    const finished=deferred
      ?await client.schema("api").rpc("worker_defer_push",{_id:job.id,_token:job.claimToken,_attempted:attempted})
      :await client.schema("api").rpc("worker_finish_editorial_push",{_id:job.id,_token:job.claimToken});
    if (finished.error) throw new Error("EDITORIAL_PUSH_FINISH_FAILED");
  }
}
