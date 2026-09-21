const target = process.argv[2];
if (!new Set(["staging", "production"]).has(target)) {
  throw new Error("Usage: node scripts/deploy/validate-environment.mjs <staging|production>");
}

const required = [
  "APP_ENVIRONMENT",
  "APP_REVISION",
  "APP_URL",
  "NEXT_PUBLIC_SITE_URL",
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_PROJECT_REF",
  "SUPABASE_ACCESS_TOKEN",
  "SUPABASE_DB_PASSWORD",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SENDGRID_API",
  "SEND_EMAIL_HOOK_SECRET",
  "CRON_SECRET",
  "PORTAL_CODE_PEPPER",
  "ABUSE_HASH_SECRET",
  "EVENT_SLUG",
  "REGISTRATION_MODE",
  "MAIL_MODE",
];

for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing required ${target} variable: ${name}`);
}

const hookKey = process.env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/, "");
const decodedHookKey = Buffer.from(hookKey, "base64");
if (!/^[A-Za-z0-9+/]+={0,2}$/.test(hookKey) || decodedHookKey.byteLength < 32 || decodedHookKey.toString("base64") !== hookKey) {
  throw new Error("SEND_EMAIL_HOOK_SECRET does not have the required Standard Webhooks base64 format.");
}

if (process.env.APP_ENVIRONMENT !== target) throw new Error("APP_ENVIRONMENT does not match the deployment target.");
if (!/^[a-f0-9]{40}$/.test(process.env.APP_REVISION)) throw new Error("APP_REVISION must be an exact Git commit.");
if (new URL(process.env.APP_URL).origin !== new URL(process.env.NEXT_PUBLIC_SITE_URL).origin) {
  throw new Error("APP_URL and NEXT_PUBLIC_SITE_URL must have the same origin.");
}
if (new URL(process.env.NEXT_PUBLIC_SUPABASE_URL).hostname !== `${process.env.SUPABASE_PROJECT_REF}.supabase.co`) {
  throw new Error("Supabase URL and project reference do not match.");
}
if (target === "staging") {
  if (process.env.REGISTRATION_MODE !== "staging_test") throw new Error("Staging must use staging_test registration mode.");
  if (process.env.MAIL_MODE !== "allowlist") throw new Error("Staging mail must use allowlist mode.");
  const allowed = new Set((process.env.MAIL_ALLOWED_RECIPIENTS ?? "").split(",").map((value) => value.trim()).filter(Boolean));
  if (allowed.size !== 2 || !allowed.has(process.env.TEST_EMAIL_1) || !allowed.has(process.env.TEST_EMAIL_2)) {
    throw new Error("Staging mail allowlist must exactly contain the two authorized test inboxes.");
  }
} else {
  if (process.env.REGISTRATION_MODE !== "closed") throw new Error("Production registration must remain closed.");
  if (process.env.MAIL_MODE !== "live") throw new Error("Production transactional mail must use live mode after staging approval.");
}

console.log(`${target} environment contract is valid.`);
