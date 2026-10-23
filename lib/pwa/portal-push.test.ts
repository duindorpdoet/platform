import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ send: vi.fn(), rpc: vi.fn() }));
vi.mock("./push-delivery",()=>({deliverScopedPush:async(target:unknown,_scope:unknown,payload:string)=>{
  try {await mocks.send(target,payload);return {success:true,deactivate:false,error:null};}
  catch(cause) {const code=Number((cause as {statusCode?:number}).statusCode??0);return {success:false,deactivate:[404,410].includes(code),error:`HTTP_${code}`};}
}}));
vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => ({
    APP_ENVIRONMENT: "staging",
    EDITORIAL_ALLOWED_RECIPIENTS: "test@example.invalid",
    WEB_PUSH_SENDING_ENABLED: "true",
    NEXT_PUBLIC_VAPID_PUBLIC_KEY: "public",
    VAPID_PRIVATE_KEY: "private",
    VAPID_SUBJECT: "mailto:test@example.invalid",
  }),
}));
vi.mock("@/lib/supabase/privileged", () => ({
  createPrivilegedClient: () => ({ schema: () => ({ rpc: mocks.rpc }) }),
}));
import { deliverPortalPush, deliverPortalPushBatch } from "./portal-push";
const target = {
  subscriptionId: "device",
  fingerprint:"fixture-hash",
  endpoint: "https://push.example.invalid/endpoint",
  p256dh: "key",
  auth: "auth",
};
describe("Poortkamer uses existing push delivery contracts", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });
  it("sends bounded generic copy and a dedupe tag without portal contacts", async () => {
    mocks.send.mockResolvedValue({});
    expect(
      (await deliverPortalPush(target, "mention", "event-id", {notificationId:"event-id",claimToken:"lease"},new AbortController().signal)).success,
    ).toBe(true);
    const payload = JSON.parse(mocks.send.mock.calls[0][1]);
    expect(payload).toEqual({
      title: "De Poortkamer",
      body: "Een Poortwachter heeft je vermeld in een besloten gesprek.",
      url: "/mijn-huis",
      tag: "poortkamer-event-id",
    });
  });
  it("deactivates gone devices, retains transient failures for retry", async () => {
    mocks.send.mockRejectedValue({ statusCode: 410 });
    expect(await deliverPortalPush(target, "arrived", "id", {notificationId:"id",claimToken:"lease"},new AbortController().signal)).toMatchObject({
      success: false,
      deactivate: true,
    });
    mocks.send.mockRejectedValue({ statusCode: 503 });
    expect(await deliverPortalPush(target, "arrived", "id", {notificationId:"id",claimToken:"lease"},new AbortController().signal)).toMatchObject({
      success: false,
      deactivate: false,
    });
  });
  it("records each delivered device before completing a durable notification", async () => {
    mocks.rpc.mockImplementation(async (name: string) =>
      name === "worker_claim_portal_push"
        ? {
            data: [{ id: "event", claimToken:"lease", kind: "urgent", targets: [target] }],
            error: null,
          }
        : { error: null },
    );
    mocks.send.mockResolvedValue({});
    await deliverPortalPushBatch();
    expect(mocks.rpc).toHaveBeenCalledWith("worker_record_portal_push", {
      _id: "event",
      _delivered: ["device"],
      _failed: false,
      _token:"lease",
    });
  });
});
