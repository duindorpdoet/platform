import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function verify(suppression: string, timeoutAt = "") {
  const code = `
    globalThis.fetch = async (input) => {
      const url = new URL(String(input));
      if (${JSON.stringify(timeoutAt)} && url.pathname.includes(${JSON.stringify(timeoutAt)})) throw new DOMException("secret provider detail", "TimeoutError");
      let body = [];
      if (url.pathname.includes('/blocks/')) body = [{reason:'550 old rejection for test-one@example.invalid'}];
      if (url.pathname.includes('/${suppression}/') && ${JSON.stringify(suppression)} !== 'blocks') body = [{reason:'active suppression'}];
      if (url.pathname.includes('/verified_senders')) body = {results:[{verified:true,from_email:'sender@example.invalid'}]};
      if (url.pathname.endsWith('/whitelabel/domains')) body = [{valid:true,domain:'example.invalid'}];
      if (url.pathname.endsWith('/messages')) body = {messages:[{status:'delivered'}]};
      if (url.pathname.endsWith('/send-email-hook')) { console.log('HOOK_PROBE_SENT'); body = {}; }
      return new Response(JSON.stringify(body), {status:200});
    };
    await import('./scripts/deploy/verify-mail-provider.mjs');
  `;
  return spawnSync(process.execPath, ["--input-type=module", "-e", code], {
    encoding: "utf8",
    env: {
      ...process.env,
      NEXT_PUBLIC_SUPABASE_URL: "https://supabase.example.invalid",
      SEND_EMAIL_HOOK_SECRET: Buffer.from("test-hook-secret-never-used-remotely").toString("base64"),
      SENDGRID_API: "test-key-never-sent",
      SENDGRID_API_BASE_URL: "https://sendgrid.example.invalid/v3",
      SENDGRID_FROM_EMAIL: "sender@example.invalid",
      TEST_EMAIL_1: "test-one@example.invalid",
      TEST_EMAIL_2: "test-two@example.invalid",
    },
    timeout: 5000,
  });
}

describe("deployment mail acceptance", () => {
  it("attempts fresh delivery after historical blocks and redacts their reasons", () => {
    const result = verify("blocks");
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("HOOK_PROBE_SENT");
    expect(result.stdout).toContain("550 old rejection for [redacted-email]");
    expect(result.stdout).not.toContain("test-one@example.invalid");
    expect(result.stdout).toContain("passed (delivered)");
  });
  it.each([
    ["/send-email-hook", "signed Supabase Auth email hook"],
    ["/verified_senders", "SendGrid /verified_senders"],
  ])("identifies a timeout at %s without leaking provider details", (path, label) => {
    const result = verify("blocks", path);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain(`${label} timed out after 10 seconds`);
    expect(result.stderr).not.toContain("secret provider detail");
  });
  it("continues to required mailbox acceptance when only activity lookup times out", () => {
    const result = verify("blocks", "/messages");
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("HOOK_PROBE_SENT");
    expect(result.stdout).toContain("Real mailbox acceptance remains required");
    expect(result.stdout).not.toContain("passed (delivered)");
  });
  for (const suppression of ["bounces", "invalid_emails", "spam_reports"]) {
    it(`still stops before sending for ${suppression}`, () => {
      const result = verify(suppression);
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("All authorized staging recipients are suppressed");
      expect(result.stdout).not.toContain("HOOK_PROBE_SENT");
    });
  }
});
