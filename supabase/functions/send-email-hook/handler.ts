import { simulatedTestRecipient } from "./testing.ts";
import { deliveriesForPayload, type HookPayload } from "./payload.ts";
import { renderAuthMail } from "./auth-template.ts";
import { recipientAllowed } from "./policy.ts";
import { transactionalMessageForPayload } from "./transactional.ts";
import { sendResend, type ResendMessage, type SendResult } from "./resend.ts";
import { mailFingerprint, type Rpc } from "./store.ts";

export type MailConfig = { id: string; provider: "resend" | "sendgrid"; version: number; from_email: string; from_name: string; reply_to: string };
type Envelope = { id: string; provider: "resend" | "sendgrid"; claim_token: string; payload: ResendMessage | null; payload_hash: string; status: string; dispatch: boolean; busy?: boolean; provider_id?: string; error_code?: string };
type Dependencies = { env: (name: string) => string | undefined; rpc: Rpc; verify: (body: string, headers: Headers) => unknown; fetcher?: typeof fetch };
function result(status: number, code?: string, headers?: Record<string, string>) {
  return Response.json(code ? { error: { http_code: status, message: code } } : {}, { status, headers });
}
async function legacySend(message: ResendMessage, apiKey: string, signal: AbortSignal, fetcher: typeof fetch): Promise<SendResult> {
  if (!apiKey) return { status: "failed", code: "LEGACY_KEY_MISSING" };
  try {
    const response = await fetcher("https://api.sendgrid.com/v3/mail/send", {
      method: "POST", signal,
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ personalizations: [{ to: message.to.map(email => ({ email })), custom_args: Object.fromEntries(message.tags.map(t => [t.name, t.value])) }],
        from: { email: message.from.match(/<([^>]+)>$/)?.[1], name: message.from.split(" <")[0] },
        reply_to: { email: message.reply_to }, subject: message.subject, headers: message.headers,
        content: [{ type: "text/plain", value: message.text }, { type: "text/html", value: message.html }],
        tracking_settings: { click_tracking: { enable: false, enable_text: false }, open_tracking: { enable: false } },
      }),
    });
    const id = response.headers.get("x-message-id");
    if (response.status === 202) return id ? { status: "accepted", providerId: id } : { status: "unknown", code: "LEGACY_ACCEPTANCE_UNCERTAIN" };
    return { status: response.status >= 500 ? "unknown" : "failed", code: `LEGACY_HTTP_${response.status}` };
  } catch { return { status: "unknown", code: "LEGACY_NETWORK_UNCERTAIN" }; }
}

export async function handleMail(request: Request, deps: Dependencies): Promise<Response> {
  const { env, rpc } = deps;
  // Supabase HTTP hooks have a 5s total invocation budget, including retries.
  // One bounded provider call, concurrent email-change deliveries, no inner retry.
  const signal = AbortSignal.timeout(3900);
  if (request.method !== "POST") return result(405, "METHOD_NOT_ALLOWED");
  if (!env("SEND_EMAIL_HOOK_SECRET")) return result(503, "HOOK_SECRET_MISSING");
  let verified: unknown;
  try {
    const reader = request.body?.getReader();
    const chunks: Uint8Array[] = []; let count = 0;
    while (reader) {
      const part = await reader.read(); if (part.done) break;
      count += part.value.byteLength;
      if (count > 128000) { await reader.cancel(); return result(413, "BODY_TOO_LARGE"); }
      chunks.push(part.value);
    }
    const bytes = new Uint8Array(count); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    verified = deps.verify(new TextDecoder("utf-8", { fatal: true }).decode(bytes), request.headers);
  } catch { return result(401, "INVALID_SIGNATURE"); }
  const allowlist = new Set((env("MAIL_ALLOWED_RECIPIENTS") ?? "").split(",").map(v => v.trim().toLowerCase()).filter(Boolean));
  const environment = env("APP_ENVIRONMENT");
  if (!environment || !["development", "test", "staging", "production"].includes(environment)) return result(503, "ENVIRONMENT_MISSING");
  const transactional = transactionalMessageForPayload(verified);
  const payload = verified as HookPayload;
  if (!transactional && (!payload?.user || !payload?.email_data)) return result(422, "INVALID_PAYLOAD");
  const mailMode = env("MAIL_MODE") ?? "disabled";
  const mode = transactional ? mailMode : env("AUTH_MAIL_MODE") ?? mailMode;
  const probe = transactional?.providerProbe === true || payload?.email_data?.email_action_type === "staging_provider_probe";
  const deliveries = transactional ? [{ email: transactional.to, token: "", template: "auth_otp" as const }] : deliveriesForPayload(payload).deliveries;
  if (!deliveries.length) return result(422, "UNSUPPORTED_OR_INVALID_AUTH_ACTION");
  if (deliveries.some(d => !recipientAllowed(mode, d.email.trim().toLowerCase(), allowlist) && !(transactional?.messageType === "mail_provider_test" && transactional.outboxId && simulatedTestRecipient(d.email)))) return result(403, "RECIPIENT_NOT_ALLOWED");
  if (transactional?.editorial) {
    const editorialAllowed = new Set((env("EDITORIAL_ALLOWED_RECIPIENTS") ?? "").split(",").map(v => v.trim().toLowerCase()));
    if (env("NEWSLETTER_SENDING_ENABLED") !== "true" || (environment !== "production" && !editorialAllowed.has(transactional.to))) return result(403, "EDITORIAL_RECIPIENT_NOT_ALLOWED");
  }
  try {
    if (!env("MAIL_IDENTITY_SECRET") || env("MAIL_IDENTITY_SECRET")!.length < 32) return result(503, "MAIL_IDENTITY_SECRET_MISSING");
    // No equivalent to SendGrid sandbox exists: validation never sends mail.
    if (probe || mode === "sandbox") {
      const authSiteUrl = env("AUTH_SITE_URL");
      try { if (!authSiteUrl || new URL(authSiteUrl).protocol !== "https:") return result(503, "AUTH_SITE_URL_INVALID"); }
      catch { return result(503, "AUTH_SITE_URL_INVALID"); }
      if (!probe && !transactional) return result(503, "AUTH_SANDBOX_CANNOT_ACCEPT_DELIVERY");
      const config = await rpc<MailConfig | null>("worker_mail_config", { _environment: environment, ...(probe && transactional?.checkConfigId ? { _config_id: transactional.checkConfigId } : {}) });
      if (!config || !env(config.provider === "resend" ? "RESEND_API_KEY" : "SENDGRID_API_KEY")) return result(503, "PROVIDER_NOT_CONFIGURED");
      return result(200, undefined, { "x-mail-status": "validated", "x-mail-provider": config.provider, "x-mail-credential-hash": await mailFingerprint(env("MAIL_IDENTITY_SECRET")!, env(config.provider === "resend" ? "RESEND_API_KEY" : "SENDGRID_API_KEY")!) });
    }
    if (!transactional && !env("AUTH_SITE_URL")) return result(503, "AUTH_SITE_URL_MISSING");
    const tasks = deliveries.map(async (delivery, index) => {
      const recipient = delivery.email.trim().toLowerCase();
      // Supabase creates a new transport webhook-id inside its retry loop.
      // metadata.uuid is created once before that loop. Older payloads use
      // verified token material and Auth sent-at fields as the fallback.
      // Only a keyed digest persists; never an OTP, token hash or request IP.
      const key = transactional
        ? transactional.outboxId ? `mail/${transactional.outboxId}/1` : transactional.testKey ? `test/${transactional.testKey}` : ""
        : `auth/${await mailFingerprint(env("MAIL_IDENTITY_SECRET")!, JSON.stringify([payload.metadata?.uuid, payload.user.confirmation_sent_at, payload.user.recovery_sent_at, payload.user.email_change_sent_at, payload.user.reauthentication_sent_at, payload.user.updated_at, payload.user.id, payload.email_data.email_action_type, payload.email_data.token_hash, payload.email_data.token_hash_new, recipient, delivery.token, index]))}`;
      if (!key) return result(422, "DURABLE_IDENTITY_REQUIRED");
      const config = await rpc<MailConfig | null>("worker_mail_config", { _environment: environment, _key: key, ...(transactional?.messageType === "mail_provider_test" && transactional.testConfigId ? { _config_id: transactional.testConfigId } : {}) });
      if (!config) return result(503, "MAIL_CONFIG_MISSING");
      const apiKey = env(config.provider === "resend" ? "RESEND_API_KEY" : "SENDGRID_API_KEY") ?? (config.provider === "sendgrid" ? env("SENDGRID_API") : "");
      if (!apiKey) return result(503, "PROVIDER_KEY_MISSING");
      const rendered = transactional ?? renderAuthMail({ template: delivery.template, token: delivery.token, siteUrl: env("AUTH_SITE_URL")!, supportEmail: config.reply_to });
      const channel = transactional ? transactional.messageType === "mail_provider_test" || transactional.testKey ? "test" : transactional.editorial ? "nachtpost" : "transactional" : "auth";
      const message: ResendMessage = {
        from: `${transactional?.editorial ? transactional.senderName ?? config.from_name : config.from_name} <${config.from_email}>`, to: [recipient], reply_to: config.reply_to,
        subject: rendered.subject, text: rendered.text, html: rendered.html,
        ...(transactional?.editorial && transactional.unsubscribeUrl ? { headers: { "List-Unsubscribe": `<${transactional.unsubscribeUrl}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } } : {}),
        tags: [{ name: "environment", value: environment }, { name: "message_type", value: transactional?.messageType ?? (transactional ? transactional.editorial ? "nachtpost" : "transactional" : delivery.template) }, ...(transactional?.outboxId ? [{ name: "outbox_id", value: transactional.outboxId }] : [])],
      };
      const fingerprint = await mailFingerprint(env("MAIL_IDENTITY_SECRET")!, JSON.stringify(message));
      const envelope = await rpc<Envelope>("worker_mail_prepare", {
        _environment: environment, _key: key, _config_id: config.id, _outbox_id: transactional?.outboxId ?? null,
        _channel: channel, _message_type: transactional?.messageType ?? (transactional ? transactional.editorial ? "nachtpost" : "transactional" : delivery.template), _recipient: recipient,
        _payload: channel === "auth" ? null : message, _payload_hash: fingerprint, _credential_hash: await mailFingerprint(env("MAIL_IDENTITY_SECRET")!, apiKey),
      });
      if (!envelope.dispatch) {
        if (envelope.status === "accepted" && envelope.provider_id) return result(200, undefined, { "x-mail-status": "accepted", "x-mail-provider": envelope.provider, "x-provider-message-id": envelope.provider_id });
        return result(envelope.status === "reconcile" ? 409 : envelope.status === "failed" ? 422 : 503, envelope.error_code ?? "MAIL_ATTEMPT_IN_PROGRESS", { "retry-after": "2" });
      }
      const material = envelope.payload ?? message;
      const send = envelope.provider === "resend"
        ? await sendResend(material, key, apiKey, { fetcher: deps.fetcher, signal: AbortSignal.any([signal, AbortSignal.timeout(2300)]) })
        : await legacySend(material, apiKey, AbortSignal.any([signal, AbortSignal.timeout(2300)]), deps.fetcher ?? fetch);
      // Durable acknowledgement precedes success. Storage failure leaves a
      // recoverable processing envelope, with the same key and provider.
      await rpc("worker_mail_finish", { _id: envelope.id, _token: envelope.claim_token, _status: send.status, _provider_id: send.providerId ?? null, _code: send.code ?? null, _retry_after: send.retryAfterSeconds ?? null });
      if (send.status !== "accepted") return result(send.status === "failed" ? 422 : 503, send.code, { "retry-after": String(send.retryAfterSeconds ?? 2), "x-mail-status": send.status });
      return result(200, undefined, { "x-mail-status": "accepted", "x-mail-provider": envelope.provider, "x-provider-message-id": send.providerId! });
    });
    const outcomes = await Promise.allSettled(tasks);
    if (outcomes.some(o => o.status === "rejected")) return result(503, "MAIL_STORE_OR_CONFIG_UNAVAILABLE", { "retry-after": "2" });
    const responses = outcomes.map(o => (o as PromiseFulfilledResult<Response>).value);
    return responses.find(r => !r.ok) ?? (transactional ? responses[0] : result(200));
  } catch { return result(503, "MAIL_STORE_OR_CONFIG_UNAVAILABLE", { "retry-after": "2" }); }
}
