const required = [
  "SUPABASE_ACCESS_TOKEN",
  "SUPABASE_PROJECT_REF",
  "NEXT_PUBLIC_SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "APP_URL",
  "EVENT_SLUG",
  "CRON_SECRET",
  "SEND_EMAIL_HOOK_SECRET",
];

for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing required deployment variable: ${name}`);
}

const projectRef = process.env.SUPABASE_PROJECT_REF;
const appUrl = new URL(process.env.APP_URL).origin;
const supabaseUrl = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL);
const authEmailRateLimit = process.env.APP_ENVIRONMENT === "production" ? 120 : 30;
if (supabaseUrl.hostname !== `${projectRef}.supabase.co`) {
  throw new Error("Supabase URL and project reference do not match.");
}

const rawHookSecret = process.env.SEND_EMAIL_HOOK_SECRET;
const hookSecret = rawHookSecret.startsWith("v1,whsec_") ? rawHookSecret : `v1,whsec_${rawHookSecret}`;
const hookKey = hookSecret.replace(/^v1,whsec_/, "");
const decodedHookKey = Buffer.from(hookKey, "base64");
if (!/^[A-Za-z0-9+/]+={0,2}$/.test(hookKey) || decodedHookKey.byteLength < 32 || decodedHookKey.toString("base64") !== hookKey) {
  throw new Error("SEND_EMAIL_HOOK_SECRET does not have the required Standard Webhooks format.");
}

async function request(url, init) {
  const response = await fetch(url, init);
  if (!response.ok) {
    throw new Error(`Deployment API request failed (${response.status}) at ${new URL(url).pathname}.`);
  }
  return response.status === 204 ? null : response.json();
}

async function rpcRequest(url, init) {
  for (let attempt = 1; attempt <= 10; attempt += 1) {
    const response = await fetch(url, init);
    if (response.ok) return response.status === 204 ? null : response.json();
    if (![404, 406, 503].includes(response.status) || attempt === 10) {
      throw new Error(`Deployment RPC request failed (${response.status}) at ${new URL(url).pathname}.`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error("Deployment RPC did not become available.");
}

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function safeProbeError(value) {
  return String(value ?? "")
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/(?:bearer|token|secret|key)[=: ]+[^\s,;]+/gi, "$1=[redacted]")
    .replace(/[\r\n]/g, " ")
    .slice(0, 500);
}

async function verifyRuntimeMailGateway() {
  let response;
  try {
    response = await fetch(`${appUrl}/api/jobs/mail`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.CRON_SECRET}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ probe: "transactional_gateway" }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new Error("The deployed application could not complete the transactional mail gateway runtime probe.");
  }

  if (response.ok) return;

  let detail = "";
  try {
    detail = safeProbeError(await response.text());
  } catch {
    detail = "";
  }

  if (response.status === 401) {
    throw new Error("Transactional mail gateway runtime probe was rejected by CRON authentication.");
  }
  if (response.status === 403) {
    throw new Error("Transactional mail gateway runtime probe was rejected by the staging recipient allowlist.");
  }
  if (response.status === 503) {
    throw new Error("Transactional mail gateway runtime configuration is unavailable or disabled.");
  }
  if (response.status === 502 || response.status === 504) {
    throw new Error(`Transactional mail gateway could not reach or was rejected by the mail provider${detail ? `: ${detail}` : "."}`);
  }
  throw new Error(`Transactional mail gateway runtime probe returned HTTP ${response.status}${detail ? `: ${detail}` : "."}`);
}

async function verifyMailWorkerProbe() {
  const requestId = await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/dispatch_mail_worker_probe`, {
    method: "POST",
    headers: serviceHeaders,
    body: "{}",
  });
  if (!Number.isInteger(requestId)) {
    throw new Error("Mail worker probe could not be queued because no active worker request was created.");
  }

  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const result = await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/mail_worker_probe_result`, {
      method: "POST",
      headers: serviceHeaders,
      body: JSON.stringify({ _request_id: requestId }),
    });
    if (!result?.found) {
      await sleep(750);
      continue;
    }
    if (result.timedOut === true) {
      throw new Error("Supabase pg_net timed out while reaching the deployed mail worker.");
    }
    if (result.error) {
      throw new Error(`Supabase pg_net could not reach the deployed mail worker: ${safeProbeError(result.error)}`);
    }
    const statusCode = result.statusCode;
    if (statusCode >= 200 && statusCode < 300) return;
    if (statusCode === 401) throw new Error("Mail worker probe reached the application but CRON authentication was rejected.");
    if (statusCode === 404) throw new Error("Mail worker endpoint was not available on the deployed staging release.");
    if (statusCode >= 500 && statusCode < 600) throw new Error("Mail worker endpoint returned an application error.");
    throw new Error(`Mail worker probe reached the application but returned HTTP ${statusCode ?? "an invalid status"}.`);
  }
  throw new Error("Mail worker probe did not receive a pg_net response within 20 seconds.");
}

const managementHeaders = {
  Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,
  "Content-Type": "application/json",
};

await request(`https://api.supabase.com/v1/projects/${projectRef}/postgrest`, {
  method: "PATCH",
  headers: managementHeaders,
  body: JSON.stringify({ db_schema: "api", db_extra_search_path: "api,extensions", max_rows: 1000 }),
});

await request(`https://api.supabase.com/v1/projects/${projectRef}/config/auth`, {
  method: "PATCH",
  headers: managementHeaders,
  body: JSON.stringify({
    site_url: appUrl,
    uri_allow_list: `${appUrl}/auth/callback,${appUrl}/inloggen`,
    mailer_autoconfirm: false,
    mailer_allow_unverified_email_sign_ins: false,
    mailer_secure_email_change_enabled: true,
    mailer_otp_exp: 600,
    mailer_otp_length: 6,
    rate_limit_email_sent: authEmailRateLimit,
    hook_send_email_enabled: true,
    hook_send_email_uri: `${supabaseUrl.origin}/functions/v1/send-email-hook`,
    hook_send_email_secrets: hookSecret,
  }),
});

const authConfig = await request(`https://api.supabase.com/v1/projects/${projectRef}/config/auth`, {
  headers: managementHeaders,
});
if (authConfig.hook_send_email_enabled !== true || authConfig.hook_send_email_uri !== `${supabaseUrl.origin}/functions/v1/send-email-hook`) {
  throw new Error("Supabase Auth did not retain the configured Send Email hook.");
}
if (authConfig.rate_limit_email_sent !== authEmailRateLimit) {
  throw new Error(`Supabase Auth did not retain the bounded ${process.env.APP_ENVIRONMENT} email rate limit.`);
}

if (authConfig.mailer_autoconfirm !== false
    || authConfig.mailer_allow_unverified_email_sign_ins !== false
    || authConfig.mailer_secure_email_change_enabled !== true
    || authConfig.mailer_otp_exp !== 600
    || authConfig.mailer_otp_length !== 6) {
  throw new Error("Supabase Auth did not retain the required verified-email, secure-change and six-digit OTP contract.");
}

const serviceHeaders = {
  apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
  "Content-Profile": "api",
  "Accept-Profile": "api",
};

const releaseMode = process.env.REGISTRATION_MODE === "staging_test" ? "staging_test_open" : process.env.REGISTRATION_MODE === "live" ? "production_open" : "production_closed";
const release = await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/configure_release_mode`, {
  method: "POST",
  headers: serviceHeaders,
  body: JSON.stringify({ _event_slug: process.env.EVENT_SLUG, _mode: releaseMode }),
});

// Public forms send only to a deployment-controlled organization mailbox.
// Staging uses the primary authorized acceptance mailbox as that destination.
const notificationRecipient = (process.env.APP_ENVIRONMENT === "staging"
  ? process.env.TEST_EMAIL_1
  : process.env.ORGANIZATION_SUPPORT_EMAIL)?.trim().toLowerCase();
if (!notificationRecipient || (process.env.APP_ENVIRONMENT === "staging"
    && !new Set((process.env.MAIL_ALLOWED_RECIPIENTS ?? "").split(",").map((value) => value.trim().toLowerCase())).has(notificationRecipient))) {
  throw new Error("The fixed notification recipient must be configured and allowlisted on staging.");
}
await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/configure_notification_recipient`, {
  method: "POST",
  headers: serviceHeaders,
  body: JSON.stringify({ _event_slug: process.env.EVENT_SLUG, _email: notificationRecipient }),
});

const mailWorker = await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/configure_mail_worker`, {
  method: "POST",
  headers: serviceHeaders,
  body: JSON.stringify({
    _endpoint: `${appUrl}/api/jobs/mail`,
    _secret: process.env.CRON_SECRET,
    _active: process.env.MAIL_MODE !== "disabled",
  }),
});

if (releaseMode === "production_closed" && (release?.phase !== "draft" || release?.registrationPublished !== false)) {
  throw new Error("Production release mode did not remain closed.");
}
if (typeof release?.groupRegistrationOpen !== "boolean" || typeof release?.portalRegistrationOpen !== "boolean") {
  throw new Error("Independent registration channel controls were not configured.");
}
if (releaseMode === "staging_test_open" && (release?.phase !== "registration_open" || release?.registrationPublished !== true || release?.groupRegistrationOpen !== true || release?.portalRegistrationOpen !== true)) {
  throw new Error("Staging test registration was not opened.");
}
if (releaseMode === "production_open" && release?.releaseMode !== "production_open") {
  throw new Error("Production participant registration release was not configured.");
}
if (process.env.MAIL_MODE !== "disabled" && mailWorker?.active !== true) {
  throw new Error("The durable mail worker was not activated.");
}
if (process.env.MAIL_MODE !== "disabled") {
  await verifyMailWorkerProbe();
  console.log("Supabase pg_net mail worker probe passed.");
  await verifyRuntimeMailGateway();
  console.log("Transactional mail gateway runtime probe passed.");
}

console.log(`Supabase release controls configured for ${process.env.APP_ENVIRONMENT}.`);
