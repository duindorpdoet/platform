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
if (!/^v1,whsec_[A-Za-z0-9+/=_-]{32,}$/.test(hookSecret)) {
  throw new Error("SEND_EMAIL_HOOK_SECRET does not have the required Standard Webhooks format.");
}

async function request(url, init) {
  const response = await fetch(url, init);
  if (!response.ok) {
    throw new Error(`Deployment API request failed (${response.status}) at ${new URL(url).pathname}.`);
  }
  return response.status === 204 ? null : response.json();
}

const managementHeaders = {
  Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,
  "Content-Type": "application/json",
};

await request(`https://api.supabase.com/v1/projects/${projectRef}/config/auth`, {
  method: "PATCH",
  headers: managementHeaders,
  body: JSON.stringify({
    site_url: appUrl,
    uri_allow_list: `${appUrl}/auth/callback,${appUrl}/inloggen`,
    mailer_otp_exp: 600,
    mailer_otp_length: 6,
    hook_send_email_enabled: true,
    hook_send_email_uri: `${supabaseUrl.origin}/functions/v1/send-email-hook`,
    hook_send_email_secrets: hookSecret,
  }),
});

const serviceHeaders = {
  apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

const releaseMode = process.env.REGISTRATION_MODE === "staging_test" ? "staging_test_open" : "production_closed";
const release = await request(`${supabaseUrl.origin}/rest/v1/rpc/configure_release_mode`, {
  method: "POST",
  headers: serviceHeaders,
  body: JSON.stringify({ _event_slug: process.env.EVENT_SLUG, _mode: releaseMode }),
});

const mailWorker = await request(`${supabaseUrl.origin}/rest/v1/rpc/configure_mail_worker`, {
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
