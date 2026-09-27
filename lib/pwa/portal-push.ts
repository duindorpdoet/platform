import "server-only";
import webPush from "web-push";
import { editorialAllowlist } from "@/lib/editorial/server";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
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
export type PortalPushTarget = {
  subscriptionId: string;
  endpoint: string;
  p256dh: string;
  auth: string;
};
export async function deliverPortalPush(
  target: PortalPushTarget,
  kind: string,
  id: string,
) {
  const env = serverEnv();
  if (
    !env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ||
    !env.VAPID_PRIVATE_KEY ||
    !env.VAPID_SUBJECT
  )
    return { success: false, deactivate: false, error: "NOT_CONFIGURED" };
  webPush.setVapidDetails(
    env.VAPID_SUBJECT,
    env.NEXT_PUBLIC_VAPID_PUBLIC_KEY,
    env.VAPID_PRIVATE_KEY,
  );
  try {
    await webPush.sendNotification(
      {
        endpoint: target.endpoint,
        keys: { p256dh: target.p256dh, auth: target.auth },
      },
      JSON.stringify({
        title: "De Poortkamer",
        body: copy[kind] ?? "Er is een update voor jullie poort.",
        url: kind === "incident" ? "/admin" : "/mijn-huis",
        tag: `poortkamer-${id}`,
      }),
      { TTL: 300, timeout: 8000 },
    );
    return { success: true, deactivate: false, error: null };
  } catch (cause) {
    const code =
      typeof cause === "object" && cause && "statusCode" in cause
        ? Number(cause.statusCode)
        : 0;
    return {
      success: false,
      deactivate: code === 404 || code === 410,
      error: code ? `HTTP_${code}` : "DELIVERY_FAILED",
    };
  }
}
export async function deliverPortalPushBatch() {
  const env = serverEnv();
  if (env.WEB_PUSH_SENDING_ENABLED !== "true") return;
  const client = createPrivilegedClient();
  if (!client) return;
  const { data, error } = await client
    .schema("api")
    .rpc("worker_claim_portal_push", { _allowed_emails: env.APP_ENVIRONMENT === "production" ? null : [...editorialAllowlist()] });
  if (error) {
    console.error("portal_push_claim_failed", { code: error.code });
    return;
  }
  for (const notification of (data ?? []) as Array<{
    id: string;
    kind: string;
    targets: PortalPushTarget[];
  }>) {
    const delivered: string[] = [];
    let failed = false;
    for (const target of notification.targets) {
      const result = await deliverPortalPush(
        target,
        notification.kind,
        notification.id,
      );
      await client.schema("api").rpc("push_subscription_delivery_record", {
        _endpoint: target.endpoint,
        _success: result.success,
        _error_code: result.error,
        _deactivate: result.deactivate,
      });
      if (result.success || result.deactivate)
        delivered.push(target.subscriptionId);
      else failed = true;
    }
    await client.schema("api").rpc("worker_record_portal_push", {
      _id: notification.id,
      _delivered: delivered,
      _failed: failed,
    });
  }
}
