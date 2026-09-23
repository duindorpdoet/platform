export type HookDelivery = { email: string; token: string };

type HookSendOptions = {
  deliveries: HookDelivery[];
  apiKey: string;
  from: string;
  fromName: string;
  subject: string;
  providerProbe: boolean;
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

function htmlEscape(value: string) {
  return value.replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]!);
}

export function providerAccepted(response: Response, sandbox: boolean) {
  return sandbox ? response.status === 200 : response.status === 202;
}

export async function sendHookDeliveries(options: HookSendOptions) {
  const fetcher = options.fetcher ?? fetch;
  return Promise.all(options.deliveries.map(({ email, token }) => fetcher("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${options.apiKey}`, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(options.timeoutMs ?? 2_500),
    body: JSON.stringify({
      personalizations: [{ to: [{ email }] }],
      from: { email: options.from, name: options.fromName },
      subject: options.subject,
      content: options.providerProbe
        ? [
          { type: "text/plain", value: "Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider." },
          { type: "text/html", value: "<p>Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider.</p>" },
        ]
        : [
          { type: "text/plain", value: `Je code is ${token}. De code verloopt over 10 minuten.` },
          { type: "text/html", value: `<div style="background:#060b13;color:#eee9de;padding:36px;font:16px Arial"><h1 style="font:32px Georgia">Je inlogcode</h1><p>Vul deze code in om veilig verder te gaan:</p><p style="font-size:34px;letter-spacing:.25em"><strong>${htmlEscape(token)}</strong></p><p>De code verloopt over 10 minuten.</p></div>` },
        ],
      tracking_settings: {
        click_tracking: { enable: false, enable_text: false },
        open_tracking: { enable: false },
      },
      mail_settings: options.sandbox ? { sandbox_mode: { enable: true } } : undefined,
    }),
  })));
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
