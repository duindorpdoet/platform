import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { Webhook as HookVerifier } from "standardwebhooks";
import { Webhook as ResendSigner } from "svix";
vi.mock("server-only", () => ({}));
const state=vi.hoisted(()=>({rpc:vi.fn(),env:{APP_ENVIRONMENT:"staging",CRON_SECRET:"local-cron",MAIL_MODE:"allowlist",NEWSLETTER_SENDING_ENABLED:"false",NEXT_PUBLIC_SUPABASE_URL:"https://fixture.supabase.co",SEND_EMAIL_HOOK_SECRET:`v1,whsec_${Buffer.alloc(32,1).toString("base64")}`,RESEND_WEBHOOK_SECRET:`whsec_${Buffer.alloc(32,7).toString("base64")}`,APP_URL:"https://staging.example.invalid",MAIL_IDENTITY_SECRET:"local-independent-identity-secret-for-regression-tests"},recipients:new Set<string>()}));
vi.mock("@/lib/config/server-env",()=>({serverEnv:()=>state.env,mailAllowlist:()=>state.recipients}));
vi.mock("@/lib/supabase/privileged",()=>({createPrivilegedClient:()=>({schema:()=>({rpc:state.rpc})})}));
vi.mock("@/lib/editorial/worker",()=>({editorialTick:async()=>{}}));
vi.mock("@/lib/pwa/portal-push",()=>({deliverPortalPushBatch:async()=>{}}));
vi.mock("@/lib/social-share/cleanup",()=>({cleanupSocialShareAssets:async()=>{}}));
import {POST as worker} from "@/app/api/jobs/mail/route";
import {POST as webhook} from "@/app/api/webhooks/resend/route";
import {handleMail} from "@/supabase/functions/send-email-hook/handler";
import type {Rpc} from "@/supabase/functions/send-email-hook/store";
const container=process.env.MAIL_INTEGRATION_CONTAINER;
function sql(query:string) {
 if(!container||!["duindorp-resend-db","supabase_db_duindorphalloween","supabase_db_duindorp-resend-browser"].includes(container))throw new Error("ISOLATED_MAIL_TEST_DATABASE_REQUIRED");
 return execFileSync("docker",["exec","-i",container,"psql","-X","-qAt","-U","postgres","-d","postgres","-v","ON_ERROR_STOP=1"],{input:query,encoding:"utf8",stdio:["pipe","pipe","pipe"]}).trim();
}
function sqlAsync(query:string):Promise<string> {
 if(!container||!["duindorp-resend-db","supabase_db_duindorphalloween","supabase_db_duindorp-resend-browser"].includes(container))throw new Error("ISOLATED_MAIL_TEST_DATABASE_REQUIRED");
 return new Promise((resolve,reject)=>{
  const child=spawn("docker",["exec","-i",container,"psql","-X","-qAt","-U","postgres","-d","postgres","-v","ON_ERROR_STOP=1"]);
  let output="";child.stdout.on("data",chunk=>{output+=chunk.toString();});child.stderr.resume();
  child.on("error",()=>reject(new Error("LOCAL_MAIL_RPC_UNAVAILABLE")));
  child.on("close",code=>code===0?resolve(output.trim()):reject(new Error("LOCAL_MAIL_RPC_FAILED")));
  child.stdin.end(query);
 });
}
const literal=(v:unknown)=>v===null||v===undefined?"null":typeof v==="number"||typeof v==="boolean"?String(v):"'"+(typeof v==="string"?v:JSON.stringify(v)).replaceAll("'","''")+"'";
async function rpc(name:string,args:Record<string,unknown>) {
 if(!/^[a-z_]+$/.test(name)||Object.keys(args).some(k=>!/^_[a-z_]+$/.test(k)))throw new Error("INVALID_TEST_RPC");
 const call=`api.${name}(${Object.entries(args).map(([k,v])=>`${k}=>${literal(v)}`).join(",")})`;
 const query=name==="worker_claim_outbox"?`select coalesce(jsonb_agg(to_jsonb(r)),'[]') from ${call} r;`:`select to_jsonb(${call});`;
 // Hold real claim locks briefly so concurrent kicks necessarily overlap in
 // separate PostgreSQL transactions rather than serializing in the JS bridge.
 const transactional=name==="worker_claim_outbox"?`begin;${query} select pg_sleep(0.15);commit;`:query;
 return JSON.parse(await sqlAsync(transactional)||"null");
}
const actor="select set_config('request.jwt.claims','{\"sub\":\"f0000000-0000-0000-0000-000000000001\",\"role\":\"authenticated\"}',false);";
const runWorker=()=>worker(new Request("https://staging.example.invalid/api/jobs/mail",{method:"POST",headers:{authorization:"Bearer local-cron"},body:"{}"}));
describe.skipIf(!container)("real planboard -> one worker -> signed Edge gateway -> Resend -> signed durable webhook",()=>{
 beforeAll(()=>{
  const original=readFileSync("supabase/tests/085_planboard_publication.sql","utf8");
  let setup=original.slice(0,original.indexOf("update board set vid="));
  setup=setup.replace("begin;","").replace("select no_plan();","").replace("create extension if not exists pgtap with schema extensions;","").replace("create temp table board(","create table app_private.resend_test_board(").replaceAll(/\bboard\b/g,"app_private.resend_test_board").replace("create temp table board_recipients","create table app_private.resend_test_recipients").replaceAll("board_recipients","app_private.resend_test_recipients");
  // Standalone local fixture; no user or remote database can be selected.
  sql("begin;drop table if exists app_private.resend_test_board;drop table if exists app_private.resend_test_recipients;"+setup+"commit;");
  sql("update app_private.email_outbox set status='suppressed' where status in ('pending','deferred');");
  sql("select api.worker_mail_bootstrap('staging','sender@example.invalid','De Poorten','reply@example.invalid');"+actor+"select api.mail_admin_command('staging','f0000000-0000-0000-0000-000000000001','duindorp-halloween-2026','save',0,null,'{\"provider\":\"resend\",\"fromEmail\":\"sender@example.invalid\",\"fromName\":\"De Poorten\",\"replyTo\":\"reply@example.invalid\"}');update app_private.mail_config_heads set active_id=draft_id,draft_id=null where environment='staging';");
  state.recipients=new Set(JSON.parse(sql("select jsonb_agg(email) from app_private.resend_test_recipients")));
  process.env.APP_URL="https://staging.example.invalid";
  state.rpc.mockImplementation(async(name:string,args:Record<string,unknown>)=>{
   try{return {data:await rpc(name,args),error:null};}catch{return {data:null,error:{code:"TEST_RPC_FAILED"}};}
  });
 });
 it("keeps a published time until protected draft confirmation and separate publication, then sends exact correction once across parallel kicks",async()=>{
  sql(actor+"update app_private.resend_test_board set vid=(select id from app_private.live_route_visits where group_id=gid order by sequence limit 1);update app_private.resend_test_board set command=jsonb_build_object('action','move','visitId',vid,'portalId',pid,'startsAt','2026-10-31T17:10:00Z','shiftFollowing',true);update app_private.resend_test_board set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026');");
  const confirmation="select api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Bevestiging van de bestaande gepubliceerde start','integration-resend-draft') from app_private.resend_test_board;";
  expect(()=>sql(actor+confirmation)).toThrow();
  const before=sql("select count(*) from app_private.email_outbox");
  sql(actor+confirmation.replace(",false,",",true,"));
  expect(sql("select count(*) from app_private.email_outbox")).toBe(before);
  expect(sql("select (app_private.current_start_publication(gid)).starts_at from app_private.resend_test_board")).toContain("17:00:00");
  const provider=vi.fn().mockImplementation(async()=>Response.json({id:crypto.randomUUID()}));
  vi.stubGlobal("fetch",async(_url:string,init:RequestInit)=>handleMail(new Request("https://fixture.supabase.co/functions/v1/send-email-hook",init),{
   env:name=>({...state.env,RESEND_API_KEY:"local-test-only",MAIL_ALLOWED_RECIPIENTS:[...state.recipients].join(",")} as Record<string,string>)[name],
   verify:(body,headers)=>new HookVerifier(state.env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/,"")).verify(body,Object.fromEntries(headers),{jsonParse:true}),rpc:rpc as Rpc,fetcher:provider,
  }));
  expect((await runWorker()).status).toBe(200);expect(provider).not.toHaveBeenCalled();
  sql(actor+"update app_private.resend_test_board set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026'),schedule=(select current_schedule_revision_id from app_private.walking_groups where id=gid);select api.admin_live_planboard_publish('duindorp-halloween-2026',gid,snapshot->>'inputHash',schedule,(select revision from app_private.group_schedule_revisions where id=schedule),(select settings_version from app_private.events where id=eid),'integration-resend-publish') from app_private.resend_test_board;");
  const responses=await Promise.all([runWorker(),runWorker(),runWorker()]);expect(responses.every(r=>r.ok)).toBe(true);
  expect(provider).toHaveBeenCalledTimes(state.recipients.size);
  for(const call of provider.mock.calls) {
   expect(call[0]).toBe("https://api.resend.com/emails");const body=JSON.parse(call[1].body);
   expect(body.to).toHaveLength(1);expect(state.recipients.has(body.to[0])).toBe(true);
   expect(body.tags).toContainEqual({name:"message_type",value:"group_schedule_corrected"});
   expect(body.text).toContain("18:00");expect(body.text).toContain("18:10");
   expect(body.text).not.toContain("NIET-BESTAAND TESTADRES");
  }
  const rows=JSON.parse(sql("select jsonb_agg(jsonb_build_object('id',id,'providerId',provider_id,'recipient',recipient_email,'status',status)) from app_private.email_outbox where provider='resend'"));
  expect(rows).toHaveLength(state.recipients.size);expect(rows.every((r:{status:string})=>r.status==="accepted")).toBe(true);
  const recipient=rows[0];const date=new Date();const eventId="msg_planboard_delivery";
  const body=JSON.stringify({type:"email.delivered",created_at:date.toISOString(),data:{email_id:recipient.providerId,to:[recipient.recipient]}});
  const signature=new ResendSigner(state.env.RESEND_WEBHOOK_SECRET).sign(eventId,date,body);
  const callback=()=>new Request("https://staging.example.invalid/api/webhooks/resend",{method:"POST",body,headers:{"svix-id":eventId,"svix-timestamp":String(Math.floor(date.getTime()/1000)),"svix-signature":signature}});
  expect((await webhook(callback())).status).toBe(204);expect((await webhook(callback())).status).toBe(204);
  expect(sql(`select status from app_private.email_outbox where id=${literal(recipient.id)}`)).toBe("delivered");
  expect(sql("select count(*) from app_private.email_events where provider='resend' and provider_event_id='msg_planboard_delivery'")).toBe("1");
  await runWorker();expect(provider).toHaveBeenCalledTimes(state.recipients.size);vi.unstubAllGlobals();
 },30000);
});
