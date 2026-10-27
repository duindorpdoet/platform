import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only",()=>({}));
const state=vi.hoisted(()=>({rpc:vi.fn(),send:vi.fn(),env:{APP_ENVIRONMENT:"staging",CRON_SECRET:"local-cron",MAIL_MODE:"sandbox",NEWSLETTER_SENDING_ENABLED:"false"}}));
vi.mock("@/lib/config/server-env",()=>({serverEnv:()=>state.env,mailAllowlist:()=>new Set(["test@example.invalid"])}));
vi.mock("@/lib/supabase/privileged",()=>({createPrivilegedClient:()=>({schema:()=>({rpc:state.rpc})})}));
vi.mock("@/lib/editorial/worker",()=>({editorialTick:async()=>{}}));
vi.mock("@/lib/pwa/portal-push",()=>({deliverPortalPushBatch:async()=>{}}));
vi.mock("@/lib/social-share/cleanup",()=>({cleanupSocialShareAssets:async()=>{}}));
vi.mock("@/lib/mail/gateway",async importOriginal=>({...await importOriginal<typeof import("@/lib/mail/gateway")>(),sendMailViaGateway:state.send}));
import { POST } from "./route";
import { ApiError } from "@/lib/http/api";
import { MailGatewayError } from "@/lib/mail/gateway";
const row={id:"e07af2b0-ad41-4b87-81f1-6f633c83e87f",message_type:"registration_received",recipient_email:"test@example.invalid",payload:{reference:"LOCAL-TEST"},attempts:1};
const request=()=>new Request("https://staging.example.invalid/api/jobs/mail",{method:"POST",headers:{authorization:"Bearer local-cron"},body:"{}"});
beforeEach(()=>{
 process.env.APP_URL="https://staging.example.invalid";
 state.rpc.mockReset().mockImplementation(async(name:string)=>({data:name==="worker_claim_outbox"?[row]:null,error:null}));state.send.mockReset();
});
describe("outbox worker acceptance and uncertainty contract",()=>{
 it("reports sandbox validation only, and preserves the new envelope claim protocol",async()=>{
  state.send.mockResolvedValue({accepted:false,validated:true,provider:"resend",providerId:null});
  const response=await POST(request());const body=await response.json();expect(response.status).toBe(200);expect(body).toMatchObject({accepted:0,validated:1,unknown:0});expect(body.results[0].status).toBe("validated");
  expect(state.rpc).toHaveBeenCalledWith("worker_claim_outbox",{_batch_size:10,_lease_seconds:300,_environment:"staging"});
  expect(state.rpc).toHaveBeenCalledWith("worker_update_outbox",expect.objectContaining({_status:"validated",_provider_id:null}));
 });
 it("a lost gateway response makes ordinary registration mail unknown rather than proving rejection",async()=>{
  state.send.mockRejectedValue(new ApiError(502,"MAIL_GATEWAY_NETWORK","Veilige fout"));
  const response=await POST(request());expect((await response.json()).unknown).toBe(1);expect(state.send).toHaveBeenCalledOnce();
  expect(state.rpc).toHaveBeenCalledWith("worker_update_outbox",expect.objectContaining({_status:"unknown",_provider_id:null}));
 });
 it("does not hide a durable-store failure after acceptance or initiate another send",async()=>{
  state.send.mockResolvedValue({accepted:true,validated:false,provider:"resend",providerId:row.id});
  state.rpc.mockImplementation(async(name:string)=>({data:name==="worker_claim_outbox"?[row]:null,error:name==="worker_update_outbox"?{code:"offline"}:null}));
  await expect(POST(request())).rejects.toMatchObject({code:"MAIL_STATUS_STORE_FAILED"});expect(state.send).toHaveBeenCalledOnce();
 });
 it("persists provider throttling delay instead of a shorter generic backoff",async()=>{
  state.send.mockRejectedValue(new MailGatewayError("RESEND_RATE_LIMIT","deferred",120));
  const started=Date.now();const response=await POST(request());expect((await response.json()).deferred).toBe(1);
  const args=state.rpc.mock.calls.find(c=>c[0]==="worker_update_outbox")![1];expect(args._status).toBe("deferred");expect(Date.parse(args._next_attempt_at)-started).toBeGreaterThanOrEqual(120000);expect(state.send).toHaveBeenCalledOnce();
 });
});
