import "server-only";
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
  sandbox?: boolean;
};

export async function sendSendGrid(message: Message) {
  const env = serverEnv();
  if (!env.SEND_EMAIL_HOOK_SECRET || !env.NEXT_PUBLIC_SUPABASE_URL) {
    throw new ApiError(503, "MAIL_NOT_CONFIGURED", "De maildienst is niet geconfigureerd.");
  }
  if (env.MAIL_MODE === "disabled") {
    throw new ApiError(503, "MAIL_DISABLED", "De maildienst staat uit.");
  }

  const recipient = message.to.trim().toLowerCase();
  if (env.MAIL_MODE === "allowlist" && !mailAllowlist().has(recipient)) {
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
      replyTo: env.SENDGRID_REPLY_TO,
      providerProbe: message.sandbox === true,
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
    if (response.status === 403) {
      throw new ApiError(403, "RECIPIENT_NOT_ALLOWED", "Deze ontvanger staat niet op de testlijst.");
    }
    if (response.status === 503) {
      throw new ApiError(503, "MAIL_NOT_CONFIGURED", "De mailgateway is niet geconfigureerd.");
    }
    if (response.status === 504) {
      throw new ApiError(502, "MAIL_PROVIDER_TIMEOUT", "De mailprovider reageerde niet op tijd.");
    }
    throw new ApiError(502, `MAIL_GATEWAY_${response.status}`, `De mailgateway heeft het bericht niet geaccepteerd (${response.status}).`);
  }

  return {
    accepted: true,
    providerId: response.headers.get("x-provider-message-id"),
  };
}
