import { appendFile } from "node:fs/promises";

for (const name of ["APP_ENVIRONMENT", "APP_URL", "SENDGRID_API", "GITHUB_ENV", "EVENT_WEBHOOK_REQUIRED"]) {
  if (!process.env[name]) throw new Error(`Missing required SendGrid deployment variable: ${name}`);
}

const target = process.env.APP_ENVIRONMENT;
if (!new Set(["staging", "production"]).has(target)) throw new Error("SendGrid webhook setup is release-only.");
const webhookRequired = process.env.EVENT_WEBHOOK_REQUIRED === "true";
if (!new Set(["true", "false"]).has(process.env.EVENT_WEBHOOK_REQUIRED)) {
  throw new Error("EVENT_WEBHOOK_REQUIRED must be true or false.");
}
const baseUrl = process.env.SENDGRID_API_BASE_URL ?? "https://api.sendgrid.com/v3";
const endpoint = `${new URL(process.env.APP_URL).origin}/api/webhooks/sendgrid`;
const friendlyName = `duindorphalloween-${target}`;
const headers = { Authorization: `Bearer ${process.env.SENDGRID_API}`, "Content-Type": "application/json" };

async function request(path, init = {}) {
  const response = await fetch(`${baseUrl}${path}`, { ...init, headers: { ...headers, ...init.headers } });
  if (!response.ok) throw new Error(`SendGrid configuration request failed (${response.status}) at ${path}.`);
  if (response.status === 204) return null;
  return response.json();
}

const configuration = {
  enabled: true,
  url: endpoint,
  delivered: true,
  spam_report: true,
  bounce: true,
  deferred: true,
  processed: true,
  dropped: true,
  open: false,
  click: false,
  group_resubscribe: false,
  group_unsubscribe: false,
  unsubscribe: false,
  friendly_name: friendlyName,
};

const current = await request("/user/webhooks/event/settings/all");
const webhooks = Array.isArray(current.webhooks) ? current.webhooks : [];
let webhook = webhooks.find((item) => item.url === endpoint || item.friendly_name === friendlyName);

if (!webhook && target === "production" && webhooks.length >= Number(current.max_allowed ?? 1)) {
  webhook = webhooks.find((item) => item.friendly_name === "duindorphalloween-staging");
}
if (!webhook && webhooks.length >= Number(current.max_allowed ?? 1)) {
  const message = "No free SendGrid Event Webhook slot is available; existing non-application webhooks were left untouched.";
  if (webhookRequired) throw new Error(message);

  await appendFile(process.env.GITHUB_ENV, "SENDGRID_EVENT_WEBHOOK_AVAILABLE=false\n", { mode: 0o600 });
  console.log(`::warning title=SendGrid delivery tracking unavailable::${message}`);
  process.exit(0);
}

if (webhook) {
  webhook = await request(`/user/webhooks/event/settings/${webhook.id}`, { method: "PATCH", body: JSON.stringify(configuration) });
} else {
  webhook = await request("/user/webhooks/event/settings", { method: "POST", body: JSON.stringify(configuration) });
}
if (!webhook?.id) throw new Error("SendGrid did not return an Event Webhook identifier.");

const signed = await request(`/user/webhooks/event/settings/signed/${webhook.id}`, {
  method: "PATCH",
  body: JSON.stringify({ enabled: true }),
});
if (!signed?.public_key) throw new Error("SendGrid signature verification did not return a public key.");

const delimiter = `SENDGRID_PUBLIC_KEY_${Date.now()}`;
await appendFile(process.env.GITHUB_ENV, `SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY<<${delimiter}\n${signed.public_key}\n${delimiter}\nSENDGRID_EVENT_WEBHOOK_ID=${webhook.id}\nSENDGRID_EVENT_WEBHOOK_AVAILABLE=true\n`, { mode: 0o600 });
console.log(`Application-specific signed SendGrid Event Webhook configured for ${target}.`);
