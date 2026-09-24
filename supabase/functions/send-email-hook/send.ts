import { renderAuthMail } from "./auth-template.ts";
import type { HookDelivery } from "./payload.ts";

type HookSendOptions = {
  deliveries: HookDelivery[];
  apiKey: string;
  from: string;
  fromName: string;
  siteUrl: string;
  supportEmail: string;
  providerProbe: boolean;
  providerProbeSubject?: string;
  sandbox: boolean;
  timeoutMs?: number;
  fetcher?: typeof fetch;
};

type TransactionalSendOptions = {
  email: string;
  subject: string;
  text: string;
  html: string;
  outboxId?: string;
  replyTo?: string;
  apiKey: string;
  from: string;
  fromName: string;
  sandbox: boolean;
  timeoutMs?: number;
  fetcher?: typeof fetch;
};

export function providerAccepted(response: Response, sandbox: boolean) {
  return sandbox ? response.status === 200 : response.status === 202;
}

export async function sendHookDeliveries(options: HookSendOptions) {
  const fetcher = options.fetcher ?? fetch;
  return Promise.all(options.deliveries.map((delivery) => {
    const message = options.providerProbe
      ? {
          subject: options.providerProbeSubject ?? "Staging mailprovidercontrole",
          text: "Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider.",
          html: "<p>Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider.</p>",
        }
      : renderAuthMail({
          template: delivery.template,
          token: delivery.token,
          siteUrl: options.siteUrl,
          supportEmail: options.supportEmail,
        });
    return fetcher("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: { Authorization: `Bearer ${options.apiKey}`, "Content-Type": "application/json" },
      signal: AbortSignal.timeout(options.timeoutMs ?? 2_500),
      body: JSON.stringify({
        personalizations: [{ to: [{ email: delivery.email }] }],
        from: { email: options.from, name: options.fromName },
        reply_to: { email: options.supportEmail },
        subject: message.subject,
        content: [
          { type: "text/plain", value: message.text },
          { type: "text/html", value: message.html },
        ],
        tracking_settings: {
          click_tracking: { enable: false, enable_text: false },
          open_tracking: { enable: false },
        },
        mail_settings: options.sandbox ? { sandbox_mode: { enable: true } } : undefined,
      }),
    });
  }));
}

export async function sendTransactionalDelivery(options: TransactionalSendOptions) {
  const fetcher = options.fetcher ?? fetch;
  return fetcher("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${options.apiKey}`, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(options.timeoutMs ?? 5_000),
    body: JSON.stringify({
      personalizations: [{
        to: [{ email: options.email }],
        custom_args: options.outboxId ? { outbox_id: options.outboxId } : undefined,
      }],
      from: { email: options.from, name: options.fromName },
      reply_to: options.replyTo ? { email: options.replyTo } : undefined,
      subject: options.subject,
      content: [
        { type: "text/plain", value: options.text },
        { type: "text/html", value: options.html },
      ],
      tracking_settings: {
        click_tracking: { enable: false, enable_text: false },
        open_tracking: { enable: false },
      },
      mail_settings: options.sandbox ? { sandbox_mode: { enable: true } } : undefined,
    }),
  });
}
