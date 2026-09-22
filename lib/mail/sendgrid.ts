import "server-only";
import { mailAllowlist, serverEnv } from "@/lib/config/server-env";
import { ApiError } from "@/lib/http/api";

type Message = { to: string; subject: string; text: string; html: string; outboxId?: string };

export async function sendSendGrid(message: Message) {
  const env = serverEnv();
  const apiKey = env.SENDGRID_API_KEY ?? env.SENDGRID_API;
  if (!apiKey || !env.SENDGRID_FROM_EMAIL) throw new ApiError(503, "MAIL_NOT_CONFIGURED", "De maildienst is niet geconfigureerd.");
  if (env.MAIL_MODE === "disabled") throw new ApiError(503, "MAIL_DISABLED", "De maildienst staat uit.");
  const recipient = message.to.trim().toLowerCase();
  if (env.MAIL_MODE === "allowlist" && !mailAllowlist().has(recipient)) throw new ApiError(403, "RECIPIENT_NOT_ALLOWED", "Deze ontvanger staat niet op de testlijst.");

  const response = await fetch(`${env.SENDGRID_API_BASE_URL}/mail/send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(5_000),
    body: JSON.stringify({
      personalizations: [{ to: [{ email: recipient }], custom_args: message.outboxId ? { outbox_id: message.outboxId } : undefined }],
      from: { email: env.SENDGRID_FROM_EMAIL, name: env.SENDGRID_FROM_NAME },
      reply_to: env.SENDGRID_REPLY_TO ? { email: env.SENDGRID_REPLY_TO } : undefined,
      subject: message.subject,
      content: [{ type: "text/plain", value: message.text }, { type: "text/html", value: message.html }],
      mail_settings: env.MAIL_MODE === "sandbox" ? { sandbox_mode: { enable: true } } : undefined,
    }),
    cache: "no-store",
  });
  if (response.status !== 202) {
    throw new ApiError(502, `SENDGRID_${response.status}`, `SendGrid heeft het bericht niet geaccepteerd (${response.status}).`);
  }
  return { accepted: true, providerId: response.headers.get("x-message-id") };
}
