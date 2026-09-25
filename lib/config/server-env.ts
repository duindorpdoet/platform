import "server-only";
import { z } from "zod";

const optionalUrl = z.string().url().optional().or(z.literal(""));

const schema = z.object({
  APP_ENVIRONMENT: z.enum(["development", "test", "staging", "production"]).default("development"),
  APP_REVISION: z.string().regex(/^[a-f0-9]{40}$/).optional(),
  APP_URL: optionalUrl.default("http://localhost:3000"),
  NEXT_PUBLIC_SITE_URL: optionalUrl.optional(),
  NEXT_PUBLIC_SUPABASE_URL: optionalUrl.optional(),
  ALLOWED_ORIGINS: z.string().default("http://localhost:3000"),
  EVENT_SLUG: z.string().default("duindorp-halloween-2026"),
  EVENT_TIMEZONE: z.string().default("Europe/Amsterdam"),
  REGISTRATION_MODE: z.enum(["closed", "staging_test", "live"]).default("closed"),
  SUPABASE_SECRET_KEY: z.string().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  SENDGRID_API_KEY: z.string().optional(),
  SENDGRID_API: z.string().optional(),
  SENDGRID_API_BASE_URL: z.string().url().default("https://api.sendgrid.com/v3"),
  SENDGRID_FROM_EMAIL: z.string().email().default("halloween@duindorpdoet.nl"),
  SENDGRID_FROM_NAME: z.string().default("De Duindorpse Poorten van Halloween"),
  SENDGRID_REPLY_TO: z.string().email().optional(),
  MAIL_MODE: z.enum(["disabled", "sandbox", "allowlist", "live"]).default("disabled"),
  MAIL_ALLOWED_RECIPIENTS: z.string().default(""),
  SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: z.string().optional(),
  SENDGRID_EVENT_MAX_AGE_SECONDS: z.coerce.number().int().positive().default(90_000),
  SENDGRID_EVENT_MAX_FUTURE_SKEW_SECONDS: z.coerce.number().int().nonnegative().default(300),
  CRON_SECRET: z.string().optional(),
  PORTAL_CODE_PEPPER: z.string().optional(),
  ABUSE_HASH_SECRET: z.string().optional(),
  SEND_EMAIL_HOOK_SECRET: z.string().optional(),
  AUTH_SITE_URL: optionalUrl.default("http://localhost:3000"),
  ORGANIZATION_SUPPORT_EMAIL: z.string().email().default("halloween@duindorpdoet.nl"),
  ORGANIZATION_EVENT_PHONE: z.string().default("0659019035"),
  NEXT_PUBLIC_VAPID_PUBLIC_KEY: z.string().optional(),
  VAPID_PRIVATE_KEY: z.string().optional(),
  VAPID_SUBJECT: z.string().refine((value) => value.startsWith("mailto:") || value.startsWith("https://"), "VAPID_SUBJECT must be a mailto or https URL").optional(),
});

let cached: z.infer<typeof schema> | undefined;

export function serverEnv() {
  cached ??= schema.parse(process.env);
  return cached;
}

export function allowedOrigins() {
  const env = serverEnv();
  return new Set(
    [env.APP_URL, env.NEXT_PUBLIC_SITE_URL, ...env.ALLOWED_ORIGINS.split(",")]
      .filter((origin): origin is string => Boolean(origin))
      .map((origin) => origin.trim())
      .map((origin) => new URL(origin).origin),
  );
}

export function mailAllowlist() {
  return new Set(serverEnv().MAIL_ALLOWED_RECIPIENTS.split(",").map((email) => email.trim().toLowerCase()).filter(Boolean));
}
