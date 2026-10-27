import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only",()=>({}));
const state=vi.hoisted(()=>({rpc:vi.fn(),getUser:vi.fn(),env:{APP_ENVIRONMENT:"staging",APP_URL:"https://staging.example.invalid",EVENT_SLUG:"duindorp-halloween-2026",MAIL_ADMIN_USER_IDS:"f0000000-0000-0000-0000-000000000001",MAIL_MODE:"allowlist",AUTH_MAIL_MODE:"live",MAIL_ALLOWED_RECIPIENTS:"test@example.invalid",EDITORIAL_ALLOWED_RECIPIENTS:"",NEWSLETTER_SENDING_ENABLED:"false",RESEND_API_KEY:"secret-sending-key-never-render",RESEND_WEBHOOK_SECRET:"secret-webhook-never-render",RESEND_ADMIN_API_KEY:"secret-admin-key-never-render",SEND_EMAIL_HOOK_SECRET:`v1,whsec_${Buffer.alloc(32,1).toString("base64")}`,NEXT_PUBLIC_SUPABASE_URL:"https://fixture.supabase.co",ORGANIZATION_SUPPORT_EMAIL:"support@example.invalid"}}));
vi.mock("@/lib/config/server-env",()=>({serverEnv:()=>state.env,mailAllowlist:()=>new Set(["test@example.invalid"]),allowedOrigins:()=>new Set([state.env.APP_URL])}));
vi.mock("@/lib/supabase/server",()=>({createClient:async()=>({auth:{getUser:state.getUser}})}));
vi.mock("@/lib/supabase/privileged",()=>({createPrivilegedClient:()=>({schema:()=>({rpc:state.rpc})})}));
import {GET,POST} from "./route";
const id="e07af2b0-ad41-4b87-81f1-6f633c83e87f";
const config={id,version:2,provider:"resend",from_email:"sender@example.invalid",from_name:"De Poorten",reply_to:"reply@example.invalid",config_hash:"config-hash"};
const snapshot={revision:1,active:{...config,id:"a07af2b0-ad41-4b87-81f1-6f633c83e87f",provider:"sendgrid",version:1},draft:config,checkedAt:null,checkedId:null,checkResult:null,suppressionsImportedAt:null,lastWebhookAt:null,legacyReconciliation:1,attempts:[],events:[]};
const request=(body:unknown)=>new Request(state.env.APP_URL+"/api/mail/settings",{method:"POST",headers:{origin:state.env.APP_URL,"content-type":"application/json","idempotency-key":"test-command-key"},body:JSON.stringify(body)});
beforeEach(()=>{
 state.env.MAIL_ADMIN_USER_IDS="f0000000-0000-0000-0000-000000000001";
 state.getUser.mockReset().mockResolvedValue({data:{user:{id:state.env.MAIL_ADMIN_USER_IDS,email:"admin@example.invalid"}},error:null});
 state.rpc.mockReset().mockResolvedValue({data:snapshot,error:null});vi.unstubAllGlobals();
});
describe("environment-wide mail administration",()=>{
 it("requires a verified Auth identity and a deployment-controlled user ID before database access",async()=>{
  state.getUser.mockResolvedValueOnce({data:{user:null},error:{}});
  expect((await GET(request({}))).status).toBe(401);
  state.env.MAIL_ADMIN_USER_IDS="different-user-id";
  expect((await GET(request({}))).status).toBe(403);expect(state.rpc).not.toHaveBeenCalled();
 });
 it("also requires the existing event_admin right, checked server-side in the database",async()=>{
  state.rpc.mockResolvedValueOnce({data:null,error:{code:"42501"}});
  expect((await GET(request({}))).status).toBe(403);
 });
 it("returns central effective/draft versions and secret presence without any secret values",async()=>{
  const response=await GET(request({}));expect(response.status).toBe(200);
  const text=await response.text();expect(text).not.toMatch(/secret-sending|secret-webhook|secret-admin|whsec_/);
  const body=JSON.parse(text).data;expect(body.active.provider).toBe("sendgrid");expect(body.draft.provider).toBe("resend");expect(body.secrets).toEqual({apiKey:true,webhookSecret:true,administrationKey:true});expect(body.lastWebhookAt).toBeNull();expect(body.modes.auth).toBe("live");
 });
 it("rejects stale versions, browser-supplied secrets, invalid senders and untrusted origins without mutation",async()=>{
  expect((await POST(request({command:"save",expectedRevision:0,draft:{provider:"resend",fromName:"Name",fromEmail:"sender@example.invalid",replyTo:"reply@example.invalid"}}))).status).toBe(409);
  expect((await POST(request({command:"save",expectedRevision:1,apiKey:"browser-secret"}))).status).toBe(422);
  expect((await POST(request({command:"save",expectedRevision:1,draft:{provider:"resend",fromName:"Name\r\nBcc: someone",fromEmail:"invalid",replyTo:"reply@example.invalid"}}))).status).toBe(422);
  const bad=request({});bad.headers.set("origin","https://attacker.example");expect((await POST(bad)).status).toBe(403);
  expect(state.rpc.mock.calls.every(c=>c[0]==="mail_admin_snapshot")).toBe(true);
 });
 it("configuration checks validate the draft through the signed non-sending gateway and never call POST /emails",async()=>{
  const fetcher=vi.fn().mockImplementation(async(url:string)=>url.startsWith("https://api.resend.com/domains")?Response.json({data:[{id,name:"example.invalid",status:"verified",open_tracking:false,click_tracking:false}],has_more:false}):new Response("{}",{headers:{"x-mail-status":"validated","x-mail-provider":"resend","x-mail-credential-hash":"c".repeat(64)}}));vi.stubGlobal("fetch",fetcher);
  expect((await POST(request({command:"check",expectedRevision:1,configId:id}))).status).toBe(200);
  expect(fetcher).toHaveBeenCalledTimes(2);
  expect(fetcher.mock.calls.some(c=>String(c[0]).endsWith("/emails"))).toBe(false);
  const check=state.rpc.mock.calls.find(c=>c[0]==="mail_admin_command")![1];expect(check._check.ready).toBe(true);expect(check._config_id).toBe(id);expect(check._check.configHash).toBe(config.config_hash);
  expect(JSON.parse(String(fetcher.mock.calls[1][1].body)).message.providerProbe).toBe(true);
 });
 it("blocks activation if current domain/key checks fail and never treats a checkbox as authorization",async()=>{
  vi.stubGlobal("fetch",vi.fn().mockResolvedValue(new Response("{}",{status:401})));
  expect((await POST(request({command:"activate",expectedRevision:1,configId:id,confirmed:true}))).status).toBe(409);
  expect(state.rpc.mock.calls.every(c=>c[0]==="mail_admin_snapshot")).toBe(true);
 });
 it("queues one explicit allowed test through the existing outbox rather than calling a provider from the browser route",async()=>{
  state.rpc.mockImplementation(async(name:string)=>({data:name==="mail_admin_test"?id:snapshot,error:null}));const fetcher=vi.fn();vi.stubGlobal("fetch",fetcher);
  const command={command:"test",expectedRevision:1,recipient:"test@example.invalid",confirmed:true};
  const response=await POST(request(command));expect(response.status).toBe(200);expect((await response.json()).data).toMatchObject({queued:true,accepted:false,deliveryStatus:"pending",outboxId:id,simulated:false});
  expect(fetcher).not.toHaveBeenCalled();expect(state.rpc.mock.calls.find(c=>c[0]==="mail_admin_test")![1]._command_key).toBe("test-command-key");
  expect((await POST(request({...command,recipient:"other@example.invalid"}))).status).toBe(403);
 });
});
