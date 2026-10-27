import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe,expect,it } from "vitest";
function run(mode:string,actions=false) {
 const code=`
 globalThis.fetch=async(input,init)=>{
 const u=new URL(String(input));
 if(u.pathname.endsWith('/worker_mail_config'))return Response.json({id:'e07af2b0-ad41-4b87-81f1-6f633c83e87f',provider:'resend'});
 if(u.pathname==='/webhooks')return Response.json({data:[{id:'unrelated',endpoint:'https://another-app.invalid/webhook',events:['email.sent']},{id:'our-own',endpoint:'https://staging-halloween.duindorpdoet.nl/api/webhooks/resend',events:['email.sent'],status:'enabled'}],has_more:false});
 if(u.pathname==='/webhooks/our-own') {if(init.method==='PATCH')console.log('OWN_ENDPOINT_UPDATED');return Response.json({id:'our-own',signing_secret:'whsec_'+Buffer.alloc(32,1).toString('base64')});}
 if(u.pathname.endsWith('/send-email-hook')){console.log('NON_SENDING_PROBE');return new Response('{}',{headers:{'x-mail-status':'validated','x-mail-provider':'resend'}});}
 throw new Error('Unexpected external write');
 };
 await import(${JSON.stringify(mode==='provision'?'./scripts/deploy/configure-resend-webhook.mjs':'./scripts/deploy/verify-mail-provider.mjs')});`;
 return spawnSync(process.execPath,["--input-type=module","-e",code],{encoding:"utf8",env:{...process.env,GITHUB_ACTIONS:actions?"true":"false",APP_ENVIRONMENT:"staging",APP_URL:"https://staging-halloween.duindorpdoet.nl",NEXT_PUBLIC_SUPABASE_URL:"https://fixture.supabase.co",SUPABASE_SERVICE_ROLE_KEY:"local-service-fixture",RESEND_API_KEY:"local-sending-fixture",RESEND_ADMIN_API_KEY:"local-admin-fixture",RESEND_WEBHOOK_SECRET:"local-signing-fixture",SEND_EMAIL_HOOK_SECRET:Buffer.alloc(32,1).toString("base64"),TEST_EMAIL_1:"test@example.invalid",GITHUB_ENV:"/dev/null"},timeout:5000});
}
describe("Resend release provisioning",()=>{
 it("updates only the exact environment endpoint and never prints its signing secret",()=>{const r=run("provision");expect(r.status,r.stderr).toBe(0);expect(r.stdout).toContain("OWN_ENDPOINT_UPDATED");expect(r.stdout).not.toContain("whsec_");});
 it("registers the secret with Actions before any runtime environment handoff",()=>{const r=run("provision",true);expect(r.status,r.stderr).toBe(0);const lines=r.stdout.split("\n");expect(lines.filter(line=>line.startsWith("::add-mask::whsec_"))).toHaveLength(1);expect(lines.filter(line=>!line.startsWith("::add-mask::")).join("\n")).not.toContain("whsec_");});
 it("keeps runtime validation non-sending and does not claim provider delivery",()=>{const r=run("validate");expect(r.status,r.stderr).toBe(0);expect(r.stdout).toContain("NON_SENDING_PROBE");expect(r.stdout).toContain("validated without sending");expect(r.stdout).not.toContain("delivered");});
 it("preserves exact staging SHA, backup and mailbox gates in deployment workflows",()=>{
  for(const name of ["deploy-staging.yml","deploy-production.yml"]) {const s=readFileSync(`.github/workflows/${name}`,"utf8");expect(s).toContain("redesign-backup.mjs");expect(s).toContain("redesign-preflight.mjs");expect(s).toContain("configure-resend-webhook.mjs");}
  expect(readFileSync('.github/workflows/deploy-production.yml','utf8')).toContain('require-staging-success.mjs');expect(readFileSync('.github/workflows/deploy-staging.yml','utf8')).toContain('staging_mail.py');
 });
});
