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
    expect(secretBlock).toContain('"SENDGRID_REPLY_TO=${SENDGRID_REPLY_TO}"');
  });
});
