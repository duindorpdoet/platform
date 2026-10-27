import { beforeEach, describe, expect, it, vi } from "vitest";
import { handleMail } from "./handler";
import type { Rpc } from "./store";
const id = "e07af2b0-ad41-4b87-81f1-6f633c83e87f";
const config = {id,provider:"resend",version:2,from_email:"sender@example.com",from_name:"De Poorten",reply_to:"reply@example.com"};
const env: Record<string,string> = {APP_ENVIRONMENT:"staging",MAIL_MODE:"allowlist",AUTH_MAIL_MODE:"live",MAIL_ALLOWED_RECIPIENTS:"old@example.com,new@example.com",RESEND_API_KEY:"test-only",MAIL_IDENTITY_SECRET:"independent-stable-local-test-identity-secret",SEND_EMAIL_HOOK_SECRET:"fixture-secret-for-tests",AUTH_SITE_URL:"https://staging.example.com"};
const auth = { metadata:{uuid:"first-logical-auth-invocation"}, user:{id,email:"old@example.com",new_email:"new@example.com"},email_data:{email_action_type:"email_change",token:"123456",token_new:"654321",token_hash:"hash-a",token_hash_new:"hash-b"}};
const envelopes=new Map<string,Record<string,unknown>>();
let calls: Array<[string,Record<string,unknown>]>;
const rpc:Rpc=async <T>(name:string,args:Record<string,unknown>)=>{
 calls.push([name,args]);
 if(name==="worker_mail_config")return config as T;
 if(name==="worker_mail_prepare"){
  const old=envelopes.get(String(args._key));
  if(old?.status==="accepted")return {...old,dispatch:false} as T;
  const row={id:String(args._key),provider:"resend",claim_token:id,status:"processing",dispatch:true,payload:args._payload};envelopes.set(String(args._key),row);return row as T;
 }
 const found=envelopes.get(String(args._id))!;Object.assign(found,{status:args._status,provider_id:args._provider_id});return found as T;
};
const request=()=>new Request("https://edge.example.com",{method:"POST",body:"verified in dependency"});
beforeEach(()=>{calls=[];envelopes.clear();env.AUTH_MAIL_MODE="live";env.MAIL_MODE="allowlist";env.AUTH_SITE_URL="https://staging.example.com";});
describe("shared durable Auth and outbox dispatch",()=>{
 it("recovers partial dual email_change without repeating the accepted delivery or storing OTP content",async()=>{
  const fetcher=vi.fn().mockImplementation(async(_url:string,init:RequestInit)=>JSON.parse(String(init.body)).to[0]==="new@example.com"&&fetcher.mock.calls.length===2?new Response(null,{status:429}):Response.json({id}));
  const deps={env:(key:string)=>env[key],rpc,verify:()=>auth,fetcher};
  expect((await handleMail(request(),deps)).status).toBe(503);
  expect((await handleMail(request(),deps)).status).toBe(200);
  expect(fetcher).toHaveBeenCalledTimes(3);
  const to=fetcher.mock.calls.map(c=>JSON.parse(c[1].body).to[0]);expect(to).toEqual(["old@example.com","new@example.com","new@example.com"]);
  const first=JSON.parse(fetcher.mock.calls[0][1].body);const second=JSON.parse(fetcher.mock.calls[1][1].body);
  expect(first.text).toContain("123456");expect(first.text).not.toContain("654321");expect(second.text).toContain("654321");
  expect(fetcher.mock.calls[1][1].headers["Idempotency-Key"]).toBe(fetcher.mock.calls[2][1].headers["Idempotency-Key"]);
  expect(fetcher.mock.calls[0][1].headers["Idempotency-Key"]).not.toBe(fetcher.mock.calls[1][1].headers["Idempotency-Key"]);
  const prepares=calls.filter(c=>c[0]==="worker_mail_prepare");expect(prepares.every(c=>c[1]._payload===null)).toBe(true);
  expect(JSON.stringify(calls)).not.toMatch(/123456|654321|hash-a|hash-b/);
 });
 it("distinguishes a new OTP request even when its transport webhook ID is reused",async()=>{
  const fetcher=vi.fn().mockImplementation(async()=>Response.json({id}));
  const deps={env:(key:string)=>env[key],rpc,verify:()=>auth,fetcher};
  await handleMail(request(),deps);
  await handleMail(request(),{...deps,verify:()=>({...auth,email_data:{...auth.email_data,token_hash:"new-otp-hash",token:"987654"}})});
  expect(fetcher).toHaveBeenCalledTimes(4);
 });
 it("a fresh Auth invocation with coincidentally identical OTP material still has a new opaque identity",async()=>{
  const fetcher=vi.fn().mockImplementation(async()=>Response.json({id}));
  const deps={env:(key:string)=>env[key],rpc,verify:()=>auth,fetcher};
  await handleMail(request(),deps);
  await handleMail(request(),{...deps,verify:()=>({...auth,metadata:{uuid:"second-new-auth-invocation"}})});
  expect(fetcher).toHaveBeenCalledTimes(4);
  expect(fetcher.mock.calls[0][1].headers["Idempotency-Key"]).not.toBe(fetcher.mock.calls[2][1].headers["Idempotency-Key"]);
 });
 it("never turns legacy provider probes or sandbox into a live send",async()=>{
  const fetcher=vi.fn();
  const probe={...auth,email_data:{...auth.email_data,email_action_type:"staging_provider_probe"}};
  const res=await handleMail(request(),{env:key=>env[key],rpc,verify:()=>probe,fetcher});
  expect(res.status).toBe(200);expect(res.headers.get("x-mail-status")).toBe("validated");expect(fetcher).not.toHaveBeenCalled();
  env.AUTH_MAIL_MODE="sandbox";
  expect((await handleMail(request(),{env:key=>env[key],rpc,verify:()=>auth,fetcher})).status).toBe(503);
 });
 it("non-sending checks also refuse an invalid Auth site before a provider can be activated",async()=>{
  env.AUTH_SITE_URL="http://insecure.example.com";const fetcher=vi.fn();
  const probe={...auth,email_data:{...auth.email_data,email_action_type:"staging_provider_probe"}};
  const response=await handleMail(request(),{env:key=>env[key],rpc,verify:()=>probe,fetcher});
  expect(response.status).toBe(503);expect(await response.text()).toContain("AUTH_SITE_URL_INVALID");expect(fetcher).not.toHaveBeenCalled();
 });
 it("uses the identical adapter for individually addressed outbox mail and enforces staging policy",async()=>{
  const fetcher=vi.fn().mockImplementation(async()=>Response.json({id}));
  const message={kind:"transactional",message:{to:"old@example.com",subject:"Bevestiging",text:"Tekst",html:"<p>Tekst</p>",outboxId:id,messageType:"registration_received"}};
  const deps={env:(key:string)=>env[key],rpc,verify:()=>message,fetcher};
  const response=await handleMail(request(),deps);expect(response.status).toBe(200);expect(response.headers.get("x-mail-provider")).toBe("resend");expect(response.headers.get("x-provider-message-id")).toBe(id);
  expect(fetcher.mock.calls[0][1].headers["Idempotency-Key"]).toBe(`mail/${id}/1`);
  expect((await handleMail(request(),{...deps,verify:()=>({...message,message:{...message.message,to:"other@example.com"}})})).status).toBe(403);
  expect(fetcher).toHaveBeenCalledOnce();
 });
 it("does not acknowledge acceptance after a database failure and does not expose the cause",async()=>{
  const response=await handleMail(request(),{env:key=>env[key],rpc:async <T>(name:string,args:Record<string,unknown>)=>{if(name==="worker_mail_finish")throw new Error("private OTP 123456");return rpc<T>(name,args);},verify:()=>auth,fetcher:vi.fn().mockImplementation(async()=>Response.json({id}))});
  expect(response.status).toBe(503);expect(await response.text()).not.toMatch(/123456|private OTP/);
 });
 it("preserves provider rejection/unknown distinctions and pins envelope material on retry",async()=>{
  const frozen={from:"De Poorten <sender@example.com>",to:["old@example.com"],subject:"Earlier",text:"Original",html:"<p>Original</p>",tags:[]};
  const fetcher=vi.fn().mockImplementation(async()=>Response.json({id}));
  const response=await handleMail(request(),{env:key=>env[key],rpc:async <T>(name:string,args:Record<string,unknown>)=>name==="worker_mail_prepare"?{id,provider:"resend",claim_token:id,dispatch:true,payload:frozen} as T:name==="worker_mail_finish"?{} as T:rpc<T>(name,args),verify:()=>({kind:"transactional",message:{to:"old@example.com",subject:"Changed",text:"Changed",html:"<p>Changed</p>",outboxId:id}}),fetcher});
  expect(response.status).toBe(200);expect(JSON.parse(fetcher.mock.calls[0][1].body)).toEqual(frozen);
 });
});
