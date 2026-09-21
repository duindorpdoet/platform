import { randomUUID } from "node:crypto";
import { Webhook } from "standardwebhooks";

for (const name of [
  "NEXT_PUBLIC_SUPABASE_URL",
  "SEND_EMAIL_HOOK_SECRET",
  "SENDGRID_API",
  "SENDGRID_FROM_EMAIL",
  "TEST_EMAIL_2",
]) {
  if (!process.env[name]) throw new Error(`Missing required mail-provider verification variable: ${name}`);
}

const sendgridBaseUrl = process.env.SENDGRID_API_BASE_URL ?? "https://api.sendgrid.com/v3";
const sendgridHeaders = { Authorization: `Bearer ${process.env.SENDGRID_API}` };
const recipient = process.env.TEST_EMAIL_2.toLowerCase();

async function sendgrid(path) {
  const response = await fetch(`${sendgridBaseUrl}${path}`, { headers: sendgridHeaders, signal: AbortSignal.timeout(10_000) });
  if (response.status === 401) throw new Error("SendGrid rejected the configured API key.");
  if (response.status === 403) return { available: false, body: null };
  if (response.status === 404) return { available: true, body: null };
  if (!response.ok) throw new Error(`SendGrid readiness request failed with status ${response.status}.`);
  return { available: true, body: await response.json() };
}

const suppressionChecks = [
  ["bounce", `/suppression/bounces/${encodeURIComponent(recipient)}`],
  ["block", `/suppression/blocks/${encodeURIComponent(recipient)}`],
  ["invalid", `/suppression/invalid_emails/${encodeURIComponent(recipient)}`],
  ["spam", `/suppression/spam_reports/${encodeURIComponent(recipient)}`],
];
const suppressions = [];
let suppressionReadAvailable = false;
for (const [kind, path] of suppressionChecks) {
  const result = await sendgrid(path);
  suppressionReadAvailable ||= result.available;
  if (Array.isArray(result.body) && result.body.length > 0) suppressions.push(kind);
}
const globalSuppression = await sendgrid(`/asm/suppressions/global/${encodeURIComponent(recipient)}`);
suppressionReadAvailable ||= globalSuppression.available;
if (globalSuppression.body?.recipient_email) suppressions.push("global");
if (suppressions.length > 0) {
  throw new Error(`The authorized staging recipient is suppressed by SendGrid (${suppressions.join(", ")}).`);
}
if (!suppressionReadAvailable) {
  console.log("::warning title=SendGrid suppression read unavailable::The restricted API key cannot inspect suppression lists.");
}

let senderVerified = false;
const verifiedSenders = await sendgrid("/verified_senders?limit=100");
if (verifiedSenders.body?.results) {
  senderVerified = verifiedSenders.body.results.some(
    (sender) => sender.verified === true && sender.from_email?.toLowerCase() === process.env.SENDGRID_FROM_EMAIL.toLowerCase(),
  );
}
const authenticatedDomains = await sendgrid("/whitelabel/domains");
if (Array.isArray(authenticatedDomains.body)) {
  const fromDomain = process.env.SENDGRID_FROM_EMAIL.split("@").at(-1)?.toLowerCase();
  senderVerified ||= authenticatedDomains.body.some(
    (domain) => domain.valid === true && (fromDomain === domain.domain?.toLowerCase() || fromDomain?.endsWith(`.${domain.domain?.toLowerCase()}`)),
  );
}
if ((verifiedSenders.available || authenticatedDomains.available) && !senderVerified) {
  throw new Error("The configured SendGrid From address is not covered by a verified sender or authenticated domain.");
}
if (!verifiedSenders.available && !authenticatedDomains.available) {
  console.log("::warning title=SendGrid sender-auth read unavailable::The restricted API key cannot inspect sender authentication.");
}

const hookSecret = process.env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/, "");
const probeId = randomUUID().slice(-12);
const probeSubject = `Staging mailprovidercontrole ${probeId}`;
const payload = JSON.stringify({
  user: { email: recipient },
  email_data: {
    token: "000000",
    token_hash: probeId,
    email_action_type: "staging_provider_probe",
    redirect_to: process.env.NEXT_PUBLIC_SUPABASE_URL,
    site_url: process.env.NEXT_PUBLIC_SUPABASE_URL,
  },
});
const messageId = `msg_${randomUUID()}`;
const timestamp = new Date();
const signature = new Webhook(hookSecret).sign(messageId, timestamp, payload);
const hookResponse = await fetch(`${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).origin}/functions/v1/send-email-hook`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "webhook-id": messageId,
    "webhook-timestamp": String(Math.floor(timestamp.getTime() / 1000)),
    "webhook-signature": signature,
  },
  body: payload,
  signal: AbortSignal.timeout(10_000),
});
if (!hookResponse.ok) {
  await hookResponse.body?.cancel();
  throw new Error(`The signed Auth email hook verification failed with status ${hookResponse.status}.`);
}

const activityQuery = encodeURIComponent(`to_email="${recipient}" AND subject="${probeSubject}"`);
let activityAvailable = true;
let deliveryStatus;
let deliveryMessage;
for (let attempt = 1; attempt <= 5; attempt += 1) {
  if (attempt > 1) await new Promise((resolve) => setTimeout(resolve, 5_000));
  const activity = await sendgrid(`/messages?limit=1&query=${activityQuery}`);
  if (!activity.available) {
    activityAvailable = false;
    break;
  }
  deliveryMessage = activity.body?.messages?.[0];
  deliveryStatus = deliveryMessage?.status;
  if (deliveryStatus === "delivered" || deliveryStatus === "not_delivered") break;
}
if (deliveryStatus === "not_delivered") {
  const details = deliveryMessage?.msg_id ? await sendgrid(`/messages/${encodeURIComponent(deliveryMessage.msg_id)}`) : null;
  const reason = details?.body?.events?.map((event) => event.reason).find(Boolean);
  if (reason) {
    const redactedReason = reason
      .replaceAll(recipient, "[test-recipient]")
      .replaceAll(process.env.SENDGRID_FROM_EMAIL.toLowerCase(), "[configured-sender]")
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
      .slice(0, 600);
    console.log(`::error title=SendGrid non-delivery reason::${redactedReason}`);
  }
  throw new Error("SendGrid reports the signed Auth-hook test message as not delivered.");
}
if (!activityAvailable) {
  console.log("::warning title=SendGrid activity read unavailable::Provider acceptance is verified, but this plan/key cannot query final delivery.");
} else if (deliveryStatus !== "delivered") {
  console.log("::warning title=SendGrid delivery still processing::The signed Auth-hook message was accepted but has no final status yet.");
}

console.log(`Signed Auth email hook and SendGrid provider acceptance passed${deliveryStatus ? ` (${deliveryStatus})` : ""}.`);
