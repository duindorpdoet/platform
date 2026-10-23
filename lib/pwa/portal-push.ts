import "server-only";
import { editorialAllowlist } from "@/lib/editorial/server";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { deliverScopedPush, type PushDeliveryScope } from "./push-delivery";
import { createPushBatchBudget, runBoundedPushBatch, type PushBatchBudget, type SafePushTarget } from "./push-security";
const copy: Record<string, string> = {
  next_10:
    "Volgens de planning komt er over ongeveer 10 minuten een groep. Bekijk de actuele stand.",
  next_3:
    "Er wordt binnenkort een groep verwacht. Bekijk de actuele stand van jullie poort.",
  arrived: "Een groep heeft het bezoek aan jullie poort gescand.",
  pause_1: "Jullie getimede pauze eindigt over ongeveer één minuut.",
  urgent: "De Omroeper heeft een belangrijke mededeling. Open De Poortkamer.",
  incident: "Een poort heeft een urgente operationele melding gedaan. Open de cockpit.",
  mention: "Een Poortwachter heeft je vermeld in een besloten gesprek.",
  access: "Je toegang of rol in De Poortkamer is gewijzigd.",
  test: "Meldingen voor dit apparaat werken. Jullie poort is verbonden.",
};

export type PortalPushTarget = SafePushTarget;
export async function deliverPortalPush(target: PortalPushTarget,kind:string,id:string,scope:PushDeliveryScope,signal:AbortSignal) {
  return deliverScopedPush(target,scope,JSON.stringify({
    title:"De Poortkamer",body:copy[kind]??"Er is een update voor jullie poort.",
    url:kind==="incident"?"/admin":"/mijn-huis",tag:`poortkamer-${id}`,
  }),signal);
}
export async function deliverPortalPushBatch(budget:PushBatchBudget=createPushBatchBudget()) {
  const env=serverEnv();
  if (env.WEB_PUSH_SENDING_ENABLED!=="true"||budget.remaining<=0||Date.now()>=budget.deadline) return;
  const client=createPrivilegedClient();if (!client) return;
  const claimed=await client.schema("api").rpc("worker_claim_portal_push",{
    _allowed_emails:env.APP_ENVIRONMENT==="production"?null:[...editorialAllowlist()],
  });
  if (claimed.error) throw new Error("PORTAL_PUSH_CLAIM_FAILED");
  const notifications=(claimed.data??[]) as Array<{id:string;claimToken:string;kind:string;targets:PortalPushTarget[]}>;
  const items=notifications.flatMap(notification=>notification.targets.map(target=>({notification,target})));
  const results=await runBoundedPushBatch(items,({notification,target},signal)=>deliverPortalPush(target,notification.kind,notification.id,
    {notificationId:notification.id,claimToken:notification.claimToken},signal),budget);
  for (const notification of notifications) {
    const delivered:string[]=[];let failed=false;let deferred=false;let attempted=false;
    for (const item of items.filter(item=>item.notification===notification)) {
      const result=results.get(item);
      if (!result||result.deferred) {deferred=true;continue;}
      attempted=true;
      const record=await client.schema("api").rpc("push_subscription_delivery_record",{
        _endpoint:item.target.endpoint,_success:result.success,_error_code:result.error,_deactivate:result.deactivate,
      });
      if (record.error) throw new Error("PORTAL_PUSH_DEVICE_ACK_FAILED");
      if (result.success||result.deactivate) delivered.push(item.target.subscriptionId);else failed=true;
    }
    if (deferred && !attempted) {
      const record=await client.schema("api").rpc("worker_defer_push",{_id:notification.id,_token:notification.claimToken,_attempted:false});
      if (record.error) throw new Error("PORTAL_PUSH_DEFER_FAILED");
      continue;
    }
    const record=await client.schema("api").rpc("worker_record_portal_push",{
      _id:notification.id,_delivered:delivered,_failed:failed||deferred,_token:notification.claimToken,
    });
    if (record.error) throw new Error("PORTAL_PUSH_ACK_FAILED");
  }
}
