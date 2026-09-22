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
    ...(process.env.APP_ENVIRONMENT === "staging" ? { rate_limit_email_sent: 30 } : {}),
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
if (process.env.APP_ENVIRONMENT === "staging" && authConfig.rate_limit_email_sent !== 30) {
  throw new Error("Supabase Auth did not retain the bounded staging email rate limit.");
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

const releaseMode = process.env.REGISTRATION_MODE === "staging_test" ? "staging_test_open" : "production_closed";
const release = await rpcRequest(`${supabaseUrl.origin}/rest/v1/rpc/configure_release_mode`, {
  method: "POST",
  headers: serviceHeaders,
  body: JSON.stringify({ _event_slug: process.env.EVENT_SLUG, _mode: releaseMode }),
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
if (releaseMode === "staging_test_open" && (release?.phase !== "registration_open" || release?.registrationPublished !== true)) {
  throw new Error("Staging test registration was not opened.");
}
if (process.env.MAIL_MODE !== "disabled" && mailWorker?.active !== true) {
  throw new Error("The durable mail worker was not activated.");
}

console.log(`Supabase release controls configured for ${process.env.APP_ENVIRONMENT}.`);
