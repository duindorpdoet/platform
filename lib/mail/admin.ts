import "server-only";
import { createHash } from "node:crypto";
import { resendTestRecipients } from "@/supabase/functions/send-email-hook/testing";
import { serverEnv, mailAllowlist } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { ApiError } from "@/lib/http/api";
import { sendMailViaGateway } from "./gateway";
import type { MailSettingsSnapshot, MailVersion } from "./admin-types";

export async function mailAdmin() {
  const env = serverEnv();
  const userClient = await createClient();
  const user = userClient ? await userClient.auth.getUser() : null;
  const id = user?.data.user?.id;
  if (!id || user?.error) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in.");
  const allowed = new Set(env.MAIL_ADMIN_USER_IDS.split(",").map(v => v.trim()).filter(Boolean));
  if (!allowed.has(id)) throw new ApiError(403, "MAIL_SYSTEM_ADMIN_REQUIRED", "Deze koppeling vereist omgevingsbrede mailbeheerrechten.");
  const client = createPrivilegedClient();
  if (!client) throw new ApiError(503, "MAIL_STORE_NOT_CONFIGURED", "De mailconfiguratie is niet beschikbaar.");
  const args = { _environment: env.APP_ENVIRONMENT, _actor: id, _event_slug: env.EVENT_SLUG };
  const snapshot = await client.schema("api").rpc("mail_admin_snapshot", args);
  if (snapshot.error) throw new ApiError(403, "MAIL_ADMIN_REQUIRED", "Het vereiste beheerrecht ontbreekt.");
  if (!snapshot.data) throw new ApiError(503, "MAIL_BOOTSTRAP_REQUIRED", "Initialiseer de centrale mailconfiguratie via de deploymentvoorziening.");
  return { client, args, snapshot: snapshot.data as MailSettingsSnapshot };
}

export function publicMailSettings(snapshot: MailSettingsSnapshot) {
  const env = serverEnv();
  return { ...snapshot, environment: env.APP_ENVIRONMENT,
    webhookUrl: new URL("/api/webhooks/resend", env.APP_URL).href,
    secrets: { apiKey: Boolean(env.RESEND_API_KEY), webhookSecret: Boolean(env.RESEND_WEBHOOK_SECRET), administrationKey: Boolean(env.RESEND_ADMIN_API_KEY) },
    modes: { mail: env.MAIL_MODE, auth: env.AUTH_MAIL_MODE ?? env.MAIL_MODE, newsletterEnabled: env.NEWSLETTER_SENDING_ENABLED === "true", transactionalAllowlist: [...mailAllowlist()], testRecipients: [...new Set([...mailAllowlist(), ...resendTestRecipients])], editorialAllowlist: env.EDITORIAL_ALLOWED_RECIPIENTS.split(",").filter(Boolean) },
  };
}

export async function checkMailConfig(config: MailVersion) {
  const env = serverEnv();
  const checks: Record<string, boolean> = { apiKey: Boolean(env.RESEND_API_KEY), webhookSecret: Boolean(env.RESEND_WEBHOOK_SECRET), domainVerified: false, trackingDisabled: false, gatewayValidated: false };
  let code: string | null = null;
  let credentialHash: string | null = null;
  if (config.provider !== "resend") return { ready: false, configHash: config.config_hash, checks, code: "RESEND_DRAFT_REQUIRED" };
  if (!env.RESEND_ADMIN_API_KEY) code = "RESEND_ADMIN_API_KEY_MISSING";
  else {
    try {
      // Domain administration uses a separate server credential. It is never
      // forwarded to Edge, the browser, or the sending adapter.
      const domainName = config.from_email.split("@")[1];
      let after = "";
      for (let page = 0; page < 10; page++) {
        const response = await fetch(`https://api.resend.com/domains?limit=100${after ? `&after=${encodeURIComponent(after)}` : ""}`, { headers: { Authorization: `Bearer ${env.RESEND_ADMIN_API_KEY}` }, signal: AbortSignal.timeout(5000), cache: "no-store" });
        if (!response.ok) { code = `RESEND_DOMAIN_CHECK_${response.status}`; break; }
        const body = await response.json() as { data?: Array<{ id: string; name: string; status: string; open_tracking?: boolean; click_tracking?: boolean }>; has_more?: boolean };
        const domain = body.data?.find(d => d.name === domainName);
        if (domain) {
          checks.domainVerified = domain.status === "verified";
          checks.trackingDisabled = domain.open_tracking === false && domain.click_tracking === false;
          if (!checks.domainVerified) code = "RESEND_DOMAIN_NOT_VERIFIED";
          else if (!checks.trackingDisabled) code = "RESEND_TRACKING_REQUIRES_REVIEW";
          break;
        }
        if (!body.has_more || !body.data?.length) break;
        after = body.data.at(-1)!.id;
      }
      if (!checks.domainVerified && !code) code = "RESEND_DOMAIN_NOT_FOUND";
    } catch { code = "RESEND_DOMAIN_CHECK_UNAVAILABLE"; }
  }
  try {
    const probe = await sendMailViaGateway({ to: [...mailAllowlist()][0] ?? env.ORGANIZATION_SUPPORT_EMAIL, subject: "Configuratiecontrole", text: "Validatie zonder verzending", html: "<p>Validatie zonder verzending</p>", sandbox: true, checkConfigId: config.id });
    checks.gatewayValidated = probe.validated === true && probe.provider === "resend" && /^[a-f0-9]{64}$/.test(probe.credentialHash ?? "");
    credentialHash = probe.credentialHash ?? null;
  } catch (cause) { code ??= cause instanceof ApiError ? cause.code : "MAIL_GATEWAY_VALIDATION_FAILED"; }
  return { ready: Object.values(checks).every(Boolean), checks, configHash: config.config_hash, code, credentialHash, webhookKeyHash: env.RESEND_WEBHOOK_SECRET ? createHash("sha256").update(env.RESEND_WEBHOOK_SECRET).digest("hex") : null };
}
