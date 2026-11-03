import { createECDH } from "node:crypto";
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

const vapid=createECDH("prime256v1");
vapid.setPrivateKey(Buffer.alloc(32,1));
const required=["SUPABASE_ACCESS_TOKEN","SUPABASE_DB_PASSWORD","SUPABASE_SERVICE_ROLE_KEY","SENDGRID_API","MAIL_IDENTITY_SECRET","CRON_SECRET","PORTAL_CODE_PEPPER","ABUSE_HASH_SECRET"];
const fixture:Record<string,string>={
 ...Object.fromEntries(required.map(name=>[name,`synthetic-local-${name}-independent-long-value`])),
 APP_ENVIRONMENT:"staging",APP_REVISION:"a".repeat(40),APP_URL:"https://staging.example.invalid",NEXT_PUBLIC_SITE_URL:"https://staging.example.invalid",
 NEXT_PUBLIC_SUPABASE_URL:"https://fixture.supabase.co",NEXT_PUBLIC_SUPABASE_ANON_KEY:"synthetic-public-key",SUPABASE_PROJECT_REF:"fixture",
 SEND_EMAIL_HOOK_SECRET:Buffer.alloc(32,2).toString("base64"),CHILD_CODE_PEPPER:Buffer.alloc(32,3).toString("base64"),CHILD_CODE_ENCRYPTION_KEY:Buffer.alloc(32,4).toString("base64"),
 POORTENBOEK_DEMO_ENABLED:"false",EVENT_SLUG:"synthetic-fixture",REGISTRATION_MODE:"staging_test",MAIL_MODE:"allowlist",AUTH_MAIL_MODE:"allowlist",
 NEXT_PUBLIC_VAPID_PUBLIC_KEY:vapid.getPublicKey().toString("base64url"),VAPID_PRIVATE_KEY:vapid.getPrivateKey().toString("base64url"),VAPID_SUBJECT:"mailto:synthetic@example.invalid",
 MAIL_ALLOWED_RECIPIENTS:"tester-a@example.invalid,tester-b@example.invalid",TEST_EMAIL_1:"tester-a@example.invalid",TEST_EMAIL_2:"tester-b@example.invalid",
};
function validate(target:string,changes:Record<string,string>={}) {
 return spawnSync(process.execPath,["scripts/deploy/validate-environment.mjs",target],{encoding:"utf8",env:{PATH:process.env.PATH,...fixture,...changes,NODE_ENV:"test"}});
}
describe("release authentication-mail policy",()=>{
 it("accepts staging only with its exact two authorized inboxes and explicit Auth allowlist",()=>{
  expect(validate("staging").status).toBe(0);
  const extra=validate("staging",{MAIL_ALLOWED_RECIPIENTS:fixture.MAIL_ALLOWED_RECIPIENTS+",outside@example.invalid"});
  expect(extra.status).not.toBe(0);expect(extra.stderr).toContain("exactly contain the two authorized test inboxes");
 });
 it.each(["live","sandbox","disabled"])("rejects staging Auth mode %s even while transactional mail is allowlisted",mode=>{
  const result=validate("staging",{AUTH_MAIL_MODE:mode});
  expect(result.status).not.toBe(0);expect(result.stderr).toContain("Staging authentication mail must use the explicit tester allowlist");
 });
 it("retains production live Auth policy and rejects an accidental production allowlist",()=>{
  const production={APP_ENVIRONMENT:"production",REGISTRATION_MODE:"live",MAIL_MODE:"live",AUTH_MAIL_MODE:"live"};
  expect(validate("production",production).status).toBe(0);
  const result=validate("production",{...production,AUTH_MAIL_MODE:"allowlist"});
  expect(result.status).not.toBe(0);expect(result.stderr).toContain("Production authentication mail must use live mode");
 });
});
