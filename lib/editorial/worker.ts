import "server-only";
import webPush from "web-push";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { editorialAllowlist } from "./server";
import { safeNewsDeepLink } from "./security";
type PushJob = {
  id: string;
  claimToken: string;
  url: string;
  versionId: string;
  targets: {
    subscriptionId: string;
    endpoint: string;
    p256dh: string;
    auth: string;
  }[];
};
export async function editorialTick() {
  const client = createPrivilegedClient();
  if (!client) return;
  const env = serverEnv();
  const { error } = await client.schema("api").rpc("worker_editorial_tick", {
    _mail_enabled: env.NEWSLETTER_SENDING_ENABLED === "true",
  });
  if (error) throw new Error("EDITORIAL_TICK_FAILED");
  if (
    env.WEB_PUSH_SENDING_ENABLED !== "true" ||
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
  webPush.setVapidDetails(
    env.VAPID_SUBJECT,
    env.NEXT_PUBLIC_VAPID_PUBLIC_KEY,
    env.VAPID_PRIVATE_KEY,
  );
  for (const job of (claimed.data ?? []) as PushJob[]) {
    for (const target of job.targets) {
      let status = "sent_to_pushservice";
      let error: string | null = null;
      try {
        await webPush.sendNotification(
          {
            endpoint: target.endpoint,
            keys: { p256dh: target.p256dh, auth: target.auth },
          },
          JSON.stringify({
            title: "De Duindorpse Poorten",
            body: "Er staat een nieuw bericht voor je klaar.",
            url: safeNewsDeepLink(
              `${job.url}?push=${job.id}&device=${target.subscriptionId}`,
            ),
            tag: `news-${job.versionId}`,
          }),
          { TTL: 3600, timeout: 8000 },
        );
      } catch (cause) {
        const code =
          typeof cause === "object" && cause && "statusCode" in cause
            ? Number(cause.statusCode)
            : 0;
        status = code === 404 || code === 410 ? "invalid" : "failed";
        error = code ? `HTTP_${code}` : "ACCEPTANCE_UNCERTAIN";
      }
      const recorded = await client
        .schema("api")
        .rpc("worker_record_editorial_push", {
          _id: job.id,
          _token: job.claimToken,
          _subscription: target.subscriptionId,
          _status: status,
          _error: error,
        });
      if (recorded.error) throw new Error("EDITORIAL_PUSH_ACK_FAILED");
    }
    const finished = await client
      .schema("api")
      .rpc("worker_finish_editorial_push", {
        _id: job.id,
        _token: job.claimToken,
      });
    if (finished.error) throw new Error("EDITORIAL_PUSH_FINISH_FAILED");
  }
}
