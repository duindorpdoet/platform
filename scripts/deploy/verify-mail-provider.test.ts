import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function verify(suppression: string, timeoutAt = "", options: {waiver?:boolean;environment?:string;hookStatus?:number;notDelivered?:boolean} = {}) {
  const code = `
    let probeSubject;
    globalThis.fetch = async (input, init) => {
      const url = new URL(String(input));
      if (${JSON.stringify(timeoutAt)} && url.pathname.includes(${JSON.stringify(timeoutAt)})) throw new DOMException("secret provider detail", "TimeoutError");
      let body = [];
      if (url.pathname.includes('/blocks/')) body = [{reason:'550 old rejection for test-one@example.invalid'}];
      if (url.pathname.includes('/${suppression}/') && ${JSON.stringify(suppression)} !== 'blocks') body = [{reason:'active suppression'}];
      if (url.pathname.includes('/verified_senders')) body = {results:[{verified:true,from_email:'sender@example.invalid'}]};
      if (url.pathname.endsWith('/whitelabel/domains')) body = [{valid:true,domain:'example.invalid'}];
      if (url.pathname.endsWith('/messages')) {
        console.log('DELIVERY_STATUS_CHECKED');
        body = {messages:[{subject:probeSubject,msg_id:'fake-probe',status:${options.notDelivered ? "'not_delivered'" : "'delivered'"}}]};
      }
      if (url.pathname.endsWith('/messages/fake-probe')) body = {events:[{reason:'550 Mailbox does not exist.'}]};
      if (url.pathname.endsWith('/send-email-hook')) {
        console.log('HOOK_PROBE_SENT');
        probeSubject = 'Staging mailprovidercontrole ' + JSON.parse(init.body).email_data.token_hash;
        return new Response('{}', {status:${options.hookStatus ?? 200}});
      }
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
      SENDGRID_ACTIVITY_POLL_INTERVAL_MS: "1",
      SENDGRID_FROM_EMAIL: "sender@example.invalid",
      TEST_EMAIL_1: "test-one@example.invalid",
      TEST_EMAIL_2: "test-two@example.invalid",
      APP_ENVIRONMENT: options.environment ?? "test",
      MAIL_RECEIPT_ACCEPTANCE_WAIVED: String(options.waiver === true),
    },
    timeout: 5000,
  });
}

describe("deployment mail acceptance", () => {
  it("keeps provider and signed-hook acceptance while explicitly waiving staging recipient receipt",()=>{
    const result=verify("blocks","",{waiver:true,environment:"staging",notDelivered:true});
    expect(result.status,result.stderr).toBe(0);
    expect(result.stdout).toContain("HOOK_PROBE_SENT");
    expect(result.stdout).toContain("Recipient delivery status is not checked");
    expect(result.stdout).not.toContain("DELIVERY_STATUS_CHECKED");
    expect(result.stdout).not.toContain("passed (delivered)");
  });
  it("never waives a failed signed Auth hook",()=>{
    const result=verify("blocks","",{waiver:true,environment:"staging",hookStatus:503});
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("hook verification failed with status 503");
  });
  it.each([
    {waiver:false,environment:"staging"},
    {waiver:true,environment:"production"},
  ])("requires receipt status without the explicit staging waiver: %j",options=>{
    const result=verify("blocks","",{...options,notDelivered:true});
    expect(result.status).not.toBe(0);
    expect(result.stdout).toContain("DELIVERY_STATUS_CHECKED");
    expect(result.stderr).toContain("test message as not delivered");
  });
  it("attempts fresh delivery after historical blocks and redacts their reasons", () => {
    const result = verify("blocks");
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("HOOK_PROBE_SENT");
    expect(result.stdout).toContain("550 old rejection for [redacted-email]");
    expect(result.stdout).not.toContain("test-one@example.invalid");
    expect(result.stdout).toContain("Signed Auth email hook and SendGrid provider acceptance passed");
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
