import { randomUUID } from "node:crypto";
import { Webhook } from "standardwebhooks";

for (const name of [
  "NEXT_PUBLIC_SUPABASE_URL",
  "SEND_EMAIL_HOOK_SECRET",
  "SENDGRID_API",
  "SENDGRID_FROM_EMAIL",
  "TEST_EMAIL_1",
  "TEST_EMAIL_2",
]) {
  if (!process.env[name]) throw new Error(`Missing required mail-provider verification variable: ${name}`);
}

const sendgridBaseUrl = process.env.SENDGRID_API_BASE_URL ?? "https://api.sendgrid.com/v3";
const sendgridHeaders = { Authorization: `Bearer ${process.env.SENDGRID_API}` };
const recipientCandidates = [...new Set([process.env.TEST_EMAIL_1, process.env.TEST_EMAIL_2].map((email) => email.toLowerCase()))];

async function timedRequest(label, url, init) {
  const started = Date.now();
  console.log(`Mail verification: ${label} started.`);
  try {
    const response = await fetch(url, { ...init, signal: AbortSignal.timeout(10_000) });
    console.log(`Mail verification: ${label} returned HTTP ${response.status} after ${Date.now() - started}ms.`);
    return response;
  } catch (error) {
    const kind = error?.name === "TimeoutError" ? "timed out after 10 seconds" : "failed before an HTTP response";
    throw new Error(`Mail verification: ${label} ${kind}.`);
  }
}

async function sendgrid(path) {
  // Do not log recipient addresses, message identifiers or query strings.
  const label = path.startsWith("/messages") ? "SendGrid activity lookup" : `SendGrid ${path.split("?")[0].split("/").slice(0, 3).join("/")}`;
  const response = await timedRequest(label, `${sendgridBaseUrl}${path}`, { headers: sendgridHeaders });
  if (response.status === 401) throw new Error("SendGrid rejected the configured API key.");
  if (response.status === 403) return { available: false, body: null };
  if (response.status === 404) return { available: true, body: null };
  if (!response.ok) throw new Error(`SendGrid readiness request failed with status ${response.status}.`);
  return { available: true, body: await response.json() };
}

let suppressionReadAvailable = false;
const recipientChecks = [];
for (const candidate of recipientCandidates) {
  const suppressionChecks = [
    ["bounce", `/suppression/bounces/${encodeURIComponent(candidate)}`],
    ["invalid", `/suppression/invalid_emails/${encodeURIComponent(candidate)}`],
    ["spam", `/suppression/spam_reports/${encodeURIComponent(candidate)}`],
  ];
  // Blocks describe historical message rejections, not ongoing address suppression.
  // https://www.twilio.com/docs/sendgrid/api-reference/blocks-api
  const blocks = await sendgrid(`/suppression/blocks/${encodeURIComponent(candidate)}`);
  if (Array.isArray(blocks.body) && blocks.body.length > 0) {
    const reasons = blocks.body.map((block) => String(block.reason ?? "No reason supplied")
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
      .replace(/[\r\n]/g, " ").slice(0, 600));
    console.log(`Historical SendGrid block for test recipient ${recipientChecks.length + 1} (does not prevent a fresh probe): ${JSON.stringify(reasons)}`);
  }
  const suppressions = [];
  for (const [kind, path] of suppressionChecks) {
    const result = await sendgrid(path);
    suppressionReadAvailable ||= result.available;
    if (Array.isArray(result.body) && result.body.length > 0) suppressions.push(kind);
  }
  const globalSuppression = await sendgrid(`/asm/suppressions/global/${encodeURIComponent(candidate)}`);
  suppressionReadAvailable ||= globalSuppression.available;
  if (globalSuppression.body?.recipient_email) suppressions.push("global");
  recipientChecks.push({ recipient: candidate, suppressions });
}
const usableRecipient = recipientChecks.find((check) => check.suppressions.length === 0);
if (!usableRecipient) {
  const summary = recipientChecks.map((check, index) => `recipient ${index + 1}: ${check.suppressions.join(", ")}`).join("; ");
  throw new Error(`All authorized staging recipients are suppressed by SendGrid (${summary}).`);
}
const recipient = usableRecipient.recipient;
const suppressedRecipientCount = recipientChecks.filter((check) => check.suppressions.length > 0).length;
if (suppressedRecipientCount > 0) {
  console.log(
    `::warning title=SendGrid recipient suppression::${suppressedRecipientCount} authorized test recipient(s) are suppressed; using an unsuppressed authorized recipient.`,
  );
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
const hookResponse = await timedRequest("signed Supabase Auth email hook", `${new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).origin}/functions/v1/send-email-hook`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "webhook-id": messageId,
    "webhook-timestamp": String(Math.floor(timestamp.getTime() / 1000)),
    "webhook-signature": signature,
  },
  body: payload,
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
