import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const workflows = ["deploy-staging.yml", "deploy-production.yml"];

describe("Auth email hook deployment", () => {
  it.each(workflows)("passes every runtime dependency to the Edge Function in %s", (workflow) => {
    const source = readFileSync(`.github/workflows/${workflow}`, "utf8");
    const secretBlock = source.match(
      /supabase secrets set[\s\S]*?supabase functions deploy send-email-hook/,
    )?.[0];

    expect(secretBlock).toBeDefined();
    expect(secretBlock).toContain('"AUTH_SITE_URL=${AUTH_SITE_URL}"');
    expect(secretBlock).toContain('"RESEND_API_KEY=${RESEND_API_KEY}"');
    expect(secretBlock).toContain('"MAIL_IDENTITY_SECRET=${MAIL_IDENTITY_SECRET}"');
    expect(secretBlock).toContain('"AUTH_MAIL_MODE=${AUTH_MAIL_MODE}"');
    expect(source).toContain('MAIL_MODE AUTH_MAIL_MODE MAIL_ALLOWED_RECIPIENTS');
    expect(source).toContain('RESEND_API_KEY RESEND_WEBHOOK_SECRET RESEND_ADMIN_API_KEY MAIL_ADMIN_USER_IDS');
  });
});
