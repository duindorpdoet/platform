import "server-only";
import { simulatedTestRecipient } from "@/supabase/functions/send-email-hook/testing";
import { editorialRecipientAllowed } from "@/lib/editorial/security";
import { editorialAllowlist } from "@/lib/editorial/server";
import { randomUUID } from "node:crypto";
import { Webhook } from "standardwebhooks";
import { mailAllowlist, serverEnv } from "@/lib/config/server-env";
import { ApiError } from "@/lib/http/api";

type Message = {
  to: string;
  subject: string;
  text: string;
  html: string;
  outboxId?: string;
  testKey?: string;
  messageType?: string;
  registrationBindingHash?: string;
  checkConfigId?: string;
  testConfigId?: string;
  sandbox?: boolean;
  editorial?: boolean;
  senderName?: string;
  unsubscribeUrl?: string;
};

export class MailGatewayError extends ApiError {
  constructor(code: string, public readonly outcome: "unknown" | "deferred", public readonly retryAfterSeconds: number) {
    super(503, code, "De maildienst verwerkt de verzenduitkomst.");
  }
}

export async function sendMailViaGateway(message: Message) {
  const env = serverEnv();
  if (!env.SEND_EMAIL_HOOK_SECRET || !env.NEXT_PUBLIC_SUPABASE_URL) {
    throw new ApiError(503, "MAIL_NOT_CONFIGURED", "De maildienst is niet geconfigureerd.");
  }
  if (env.MAIL_MODE === "disabled") {
    throw new ApiError(503, "MAIL_DISABLED", "De maildienst staat uit.");
  }

  const recipient = message.to.trim().toLowerCase();
  if (message.editorial && (env.NEWSLETTER_SENDING_ENABLED !== "true" || !editorialRecipientAllowed(env.APP_ENVIRONMENT, recipient, editorialAllowlist()))) throw new ApiError(403, "EDITORIAL_RECIPIENT_NOT_ALLOWED", "Nachtpost is uitgeschakeld of deze ontvanger staat niet op de redactionele testlijst.");
  if (env.MAIL_MODE === "allowlist" && !mailAllowlist().has(recipient) && !(message.messageType === "mail_provider_test" && message.outboxId && simulatedTestRecipient(recipient))) {
    throw new ApiError(403, "RECIPIENT_NOT_ALLOWED", "Deze ontvanger staat niet op de testlijst.");
  }

  const hookSecret = env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/, "");
  const payload = JSON.stringify({
    kind: "transactional",
    message: {
      to: recipient,
      subject: message.subject,
      text: message.text,
      html: message.html,
      outboxId: message.outboxId,
      testKey: message.testKey,
      messageType: message.messageType,
      registrationBindingHash: message.registrationBindingHash,
      checkConfigId: message.checkConfigId,
      testConfigId: message.testConfigId,
      providerProbe: message.sandbox === true,
      ...(message.editorial ? { editorial: true, senderName: message.senderName, unsubscribeUrl: message.unsubscribeUrl } : {}),
    },
  });

  const messageId = `msg_${randomUUID()}`;
  const timestamp = new Date();
  const signature = new Webhook(hookSecret).sign(messageId, timestamp, payload);

  let response: Response;
  try {
    response = await fetch(
      `${new URL(env.NEXT_PUBLIC_SUPABASE_URL).origin}/functions/v1/send-email-hook`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "webhook-id": messageId,
          "webhook-timestamp": String(Math.floor(timestamp.getTime() / 1000)),
          "webhook-signature": signature,
        },
        body: payload,
        signal: AbortSignal.timeout(10_000),
        cache: "no-store",
      },
    );
  } catch {
    throw new ApiError(502, "MAIL_GATEWAY_NETWORK", "De beveiligde mailgateway is tijdelijk niet bereikbaar.");
  }

  if (!response.ok) {
    if ([409, 422].includes(response.status) && message.registrationBindingHash) {
      const body = await response.clone().json().catch(() => null);
      if (body?.error?.message === "REGISTRATION_MAIL_SUPERSEDED") throw new ApiError(422, "REGISTRATION_MAIL_SUPERSEDED", "Deze uitnodiging of groepswijziging is vervangen door een actuele versie.");
    }
    if (response.status === 409) throw new ApiError(409, "MAIL_RECONCILIATION_REQUIRED", "Deze verzendpoging vereist controle.");
    if ([400, 413, 422].includes(response.status)) throw new ApiError(422, "MAIL_PROVIDER_REJECTED", "De mailprovider heeft het bericht afgewezen.");
    if (response.status === 403) {
      throw new ApiError(403, "RECIPIENT_NOT_ALLOWED", "Deze ontvanger staat niet op de testlijst.");
    }
    if (response.status === 503) {
      const body = await response.json().catch(() => null);
      const supplied = body?.error?.message;
      const code = typeof supplied === "string" && /^[A-Z0-9_]{1,100}$/.test(supplied) ? supplied : "MAIL_ACCEPTANCE_UNCERTAIN";
      const configuration = ["PROVIDER_KEY_MISSING", "MAIL_IDENTITY_SECRET_MISSING", "MAIL_CONFIG_MISSING", "AUTH_SITE_URL_MISSING", "HOOK_SECRET_MISSING"].includes(code);
      const seconds = Number(response.headers.get("retry-after") ?? "30");
      throw new MailGatewayError(code, configuration || response.headers.get("x-mail-status") === "deferred" ? "deferred" : "unknown", Number.isFinite(seconds) ? Math.min(86400, Math.max(1, seconds)) : 30);
    }
    if (response.status === 504) {
      throw new ApiError(502, "MAIL_PROVIDER_TIMEOUT", "De mailprovider reageerde niet op tijd.");
    }
    throw new ApiError(502, `MAIL_GATEWAY_${response.status}`, `De mailgateway heeft het bericht niet geaccepteerd (${response.status}).`);
  }

  const status = response.headers.get("x-mail-status");
  const providerId = response.headers.get("x-provider-message-id");
  const provider = response.headers.get("x-mail-provider");
  if (status === "validated") return { accepted: false, validated: true, provider, providerId: null, credentialHash: response.headers.get("x-mail-credential-hash") };
  if (!providerId || !["resend", "sendgrid"].includes(provider ?? "")) throw new ApiError(502, "MAIL_ACCEPTANCE_UNCERTAIN", "De verzenduitkomst wordt gecontroleerd.");
  return { accepted: true, validated: false, provider, providerId };
}
