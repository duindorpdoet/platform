import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { mailTestPolicy } from "./mail-test-policy.mjs";
const sha="a".repeat(40), now=Date.parse("2026-10-27T10:00:00Z");
const context={GITHUB_SHA:sha,GITHUB_EVENT_NAME:"push",GITHUB_REPOSITORY:"duindorpdoet/platform"};
const waiver={...context,MAIL_TEST_WAIVER_SHA:sha,MAIL_TEST_WAIVER_EXPIRES_AT:"2026-10-28T10:00:00Z",MAIL_TEST_WAIVER_REASON:"Explicit account/app release authorization: no mail tests."};
describe("release-bound mail-test exception",()=>{
 it("keeps the normal acceptance policy as default",()=>expect(mailTestPolicy(context,now).skip).toBe(false));
 it("accepts only the exact authorized release SHA on automatic pushes",()=>{
  expect(mailTestPolicy(waiver,now)).toMatchObject({skip:true,source:"exact-release-sha",sha});
  expect(mailTestPolicy({...waiver,GITHUB_SHA:"b".repeat(40)},now).skip).toBe(false);
 });
 it.each(["", "2026-10-26T10:00:00Z", "2027-01-01T00:00:00Z"])("refuses expired or unbounded automatic waivers: %s",expiry=>expect(()=>mailTestPolicy({...waiver,MAIL_TEST_WAIVER_EXPIRES_AT:expiry},now)).toThrow("MAIL_WAIVER_EXPIRED_OR_UNBOUNDED"));
 it("requires an explicit audit reason and the right repository",()=>{
  expect(()=>mailTestPolicy({...waiver,MAIL_TEST_WAIVER_REASON:""},now)).toThrow("MAIL_WAIVER_REASON_REQUIRED");
  expect(()=>mailTestPolicy({...waiver,GITHUB_REPOSITORY:"other/project"},now)).toThrow("MAIL_WAIVER_REPOSITORY_MISMATCH");
 });
 it("limits a manual exception to an explicitly selected dispatch run",()=>{
  expect(mailTestPolicy({...context,SKIP_MAIL_TESTS_REQUESTED:"true"},now).skip).toBe(false);
  expect(mailTestPolicy({...context,GITHUB_EVENT_NAME:"workflow_dispatch",SKIP_MAIL_TESTS_REQUESTED:"true"},now)).toMatchObject({skip:true,source:"explicit-dispatch"});
  expect(mailTestPolicy({...context,GITHUB_EVENT_NAME:"workflow_dispatch",SKIP_MAIL_TESTS_REQUESTED:"false"},now).skip).toBe(false);
 });
 it.each(["deploy-staging.yml","deploy-production.yml"])("retains backup and non-mail gates while gating mail checks in %s",name=>{
  const source=readFileSync(`.github/workflows/${name}`,"utf8");
  expect(source).toContain("skip_mail_tests:");expect(source).toContain("mail-test-policy.mjs");
  expect(source).toContain("SKIP_MAIL_TESTS: ${{ needs.release-policy.outputs.skip_mail_tests }}");
  expect(source).toContain("redesign-backup.mjs");expect(source).toContain("check-security-advisors.mjs");expect(source).toContain("verify-deployment.mjs");
  expect(source).toContain("env.SKIP_MAIL_TESTS != 'true' && env.MAIL_ACTIVE_PROVIDER == 'resend'");
  if(name==="deploy-staging.yml")expect(source).toContain("needs.release-policy.outputs.skip_mail_tests != 'true'");
 });
 it("also skips the configuration script's nested worker and gateway probes",()=>{
  const source=readFileSync("scripts/deploy/configure-supabase.mjs","utf8");
  expect(source).toContain('process.env.MAIL_MODE !== "disabled" && process.env.SKIP_MAIL_TESTS !== "true"');
  expect(source).toContain('hook_send_email_enabled: true');
 });
});
