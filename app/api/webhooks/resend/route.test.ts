import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import { Webhook } from "svix";
vi.mock("server-only", () => ({}));
const secret = `whsec_${Buffer.alloc(32, 7).toString("base64")}`;
const { rpc, config } = vi.hoisted(() => ({ rpc: vi.fn(), config: { RESEND_WEBHOOK_SECRET: "", APP_ENVIRONMENT: "staging" } }));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => config }));
vi.mock("@/lib/supabase/privileged", () => ({ createPrivilegedClient: () => ({ schema: () => ({ rpc }) }) }));
import { POST } from "./route";
const emailId = "e07af2b0-ad41-4b87-81f1-6f633c83e87f";
const event = { type: "email.delivered", created_at: "2026-01-01T00:00:00Z", data: { email_id: emailId, to: ["private@example.com"], subject: "Private subject", tags: { outbox_id: "someone-elses-outbox", environment: "production" } } };
function signed(body = JSON.stringify(event), date = new Date(), id = "msg_signed_event") {
  return new Request("https://app.example/api/webhooks/resend", { method: "POST", body, headers: { "svix-id": id, "svix-timestamp": String(Math.floor(date.getTime()/1000)), "svix-signature": new Webhook(secret).sign(id,date,body) } });
}
beforeEach(() => { config.RESEND_WEBHOOK_SECRET = secret; rpc.mockReset().mockResolvedValue({ data: true, error: null }); });
describe("Resend signed durable event ingestion", () => {
  it("verifies raw bytes, accepts an old business event with a fresh signature and ignores routing tags", async () => {
    expect((await POST(signed())).status).toBe(204);
    expect(rpc).toHaveBeenCalledWith("worker_store_resend_event", { _environment:"staging",_event_id:"msg_signed_event",_provider_id:emailId,_kind:"email.delivered",_occurred_at:event.created_at,_recipient:"private@example.com",_safe_code:null,_verification_key_hash:createHash("sha256").update(secret).digest("hex") });
    expect(JSON.stringify(rpc.mock.calls)).not.toMatch(/Private subject|someone-elses-outbox/);
  });
  it("rejects missing and incorrect signatures without storing anything", async () => {
    expect((await POST(new Request("https://app.example",{method:"POST",body:"{}"}))).status).toBe(401);
    const bad=signed(); bad.headers.set("svix-signature","v1,wrong");
    expect((await POST(bad)).status).toBe(401);expect(rpc).not.toHaveBeenCalled();
  });
  it("rejects raw-body mutation and expired/future signature timestamps", async () => {
    const valid=signed();
    expect((await POST(new Request(valid,{body:JSON.stringify(event,null,2)}))).status).toBe(401);
    expect((await POST(signed(undefined,new Date(Date.now()-600000)))).status).toBe(401);
    expect((await POST(signed(undefined,new Date(Date.now()+600000)))).status).toBe(401);
    expect(rpc).not.toHaveBeenCalled();
  });
  it("enforces actual byte limit without Content-Length", async () => {
    expect((await POST(signed("é".repeat(65000)))).status).toBe(413);expect(rpc).not.toHaveBeenCalled();
  });
  it.each(["{",JSON.stringify({...event,data:{email_id:"invalid",to:[]}}),JSON.stringify({...event,created_at:"bad"})])("rejects malformed verified payload", async body => {
    expect((await POST(signed(body))).status).toBeGreaterThanOrEqual(400);expect(rpc).not.toHaveBeenCalled();
  });
  it("stores verified irrelevant events minimally and acknowledges duplicates", async () => {
    rpc.mockResolvedValue({data:false,error:null});
    expect((await POST(signed(JSON.stringify({type:"domain.updated",created_at:event.created_at,data:{id:"domain"}})))).status).toBe(204);
    expect(rpc.mock.calls[0][1]._provider_id).toBeNull();
    expect((await POST(signed())).status).toBe(204);
  });
  it("responds 503 on returned or thrown durable-storage errors", async () => {
    rpc.mockResolvedValueOnce({data:null,error:{code:"offline"}}).mockRejectedValueOnce(new Error("private detail"));
    expect((await POST(signed())).status).toBe(503);expect((await POST(signed())).status).toBe(503);
  });
});
