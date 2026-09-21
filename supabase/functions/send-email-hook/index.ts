import { Webhook } from "npm:standardwebhooks@1.1.1";
import { deliveriesForPayload, type HookPayload } from "./payload.ts";

function htmlEscape(value: string) {
  return value.replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]!);
}

Deno.serve(async (request) => {
  const hookSecret = Deno.env.get("SEND_EMAIL_HOOK_SECRET")?.replace(/^v1,whsec_/, "");
  const apiKey = Deno.env.get("SENDGRID_API_KEY") ?? Deno.env.get("SENDGRID_API");
  const from = Deno.env.get("SENDGRID_FROM_EMAIL");
  const mailMode = Deno.env.get("MAIL_MODE") ?? "disabled";
  if (!hookSecret || !apiKey || !from) return new Response("not configured", { status: 503 });
  if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (Number(request.headers.get("content-length") ?? "0") > 128_000) return new Response("too large", { status: 413 });
  const body = await request.text();
  if (body.length > 128_000) return new Response("too large", { status: 413 });
  let payload: HookPayload;
  try {
    payload = new Webhook(hookSecret).verify(body, Object.fromEntries(request.headers), { jsonParse: true }) as HookPayload;
  } catch {
    return new Response("invalid signature", { status: 401 });
  }
  const { deliveries: emails, supported } = deliveriesForPayload(payload);
  if (!supported) return new Response("unsupported action", { status: 422 });
  if (emails.length === 0) return new Response("invalid payload", { status: 422 });
  const allowlist = new Set((Deno.env.get("MAIL_ALLOWED_RECIPIENTS") ?? "").split(",").map((email) => email.trim().toLowerCase()).filter(Boolean));
  if (mailMode === "disabled" || (mailMode === "allowlist" && emails.some(({ email }) => !allowlist.has(email.toLowerCase())))) return new Response("recipient disabled", { status: 403 });
  const providerProbe = payload.email_data.email_action_type === "staging_provider_probe";
  const providerProbeId = (payload.email_data.token_hash ?? "probe").replace(/[^a-zA-Z0-9-]/g, "").slice(-12);
  const subject = providerProbe ? `Staging mailprovidercontrole ${providerProbeId}` : "Je zescijferige inlogcode";
  const responses = await Promise.all(emails.map(({ email, token }) => fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(2_500),
    body: JSON.stringify({
      personalizations: [{ to: [{ email }] }],
      from: { email: from, name: Deno.env.get("SENDGRID_FROM_NAME") ?? "De Duindorpse Poorten van Halloween" },
      subject,
      content: providerProbe
        ? [
          { type: "text/plain", value: "Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider." },
          { type: "text/html", value: "<p>Dit is de geautomatiseerde stagingcontrole van de transactionele mailprovider.</p>" },
        ]
        : [
          { type: "text/plain", value: `Je code is ${token}. De code verloopt over 10 minuten.` },
          { type: "text/html", value: `<div style="background:#060b13;color:#eee9de;padding:36px;font:16px Arial"><h1 style="font:32px Georgia">Je inlogcode</h1><p>Vul deze code in om veilig verder te gaan:</p><p style="font-size:34px;letter-spacing:.25em"><strong>${htmlEscape(token)}</strong></p><p>De code verloopt over 10 minuten.</p></div>` },
        ],
      mail_settings: mailMode === "sandbox" ? { sandbox_mode: { enable: true } } : undefined,
    }),
  })));
  console.log(JSON.stringify({ event: "auth_email_provider_response", statuses: responses.map((response) => response.status) }));
  if (responses.some((response) => response.status !== 202)) return new Response("provider rejected", { status: 502 });
  return new Response(JSON.stringify({}), { status: 200, headers: { "content-type": "application/json" } });
});
