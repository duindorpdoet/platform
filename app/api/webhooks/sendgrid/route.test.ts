import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  verifySignature: vi.fn(),
  convertPublicKeyToECDSA: vi.fn(() => "converted-key"),
  rpc: vi.fn(),
}));

vi.mock("@sendgrid/eventwebhook", () => ({
  EventWebhook: class {
    convertPublicKeyToECDSA = mocks.convertPublicKeyToECDSA;
    verifySignature = mocks.verifySignature;
  },
}));
vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => ({
    SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "test-public-key",
    SENDGRID_EVENT_MAX_AGE_SECONDS: 300,
    SENDGRID_EVENT_MAX_FUTURE_SKEW_SECONDS: 30,
  }),
}));
vi.mock("@/lib/supabase/privileged", () => ({
  createPrivilegedClient: () => ({ schema: () => ({ rpc: mocks.rpc }) }),
}));

import { POST } from "./route";

function signedRequest(body: string, timestamp = String(Math.floor(Date.now() / 1000))) {
  return new Request("https://halloween.duindorpdoet.nl/api/webhooks/sendgrid", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-twilio-email-event-webhook-signature": "test-signature",
      "x-twilio-email-event-webhook-timestamp": timestamp,
    },
    body,
  });
}

describe("signed SendGrid event webhook", () => {
  beforeEach(() => {
    mocks.verifySignature.mockReset().mockReturnValue(true);
    mocks.convertPublicKeyToECDSA.mockClear();
    mocks.rpc.mockReset().mockResolvedValue({ error: null, data: true });
  });

  it("rejects an invalid signature without touching durable state", async () => {
    mocks.verifySignature.mockReturnValue(false);
    const response = await POST(signedRequest("[]"));

    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("rejects a stale signed request before signature verification", async () => {
    const staleTimestamp = String(Math.floor(Date.now() / 1000) - 301);
    const response = await POST(signedRequest("[]", staleTimestamp));

    expect(response.status).toBe(401);
    expect(mocks.verifySignature).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("verifies the exact raw body and stores only the correlated event", async () => {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = '[{"sg_event_id":"event-1","event":"delivered","timestamp":1793471400,"outbox_id":"00000000-0000-0000-0000-000000000001"}]';
    const response = await POST(signedRequest(body, timestamp));

    expect(response.status).toBe(204);
    expect(mocks.verifySignature).toHaveBeenCalledWith("converted-key", body, "test-signature", timestamp);
    expect(mocks.rpc).toHaveBeenCalledOnce();
    expect(mocks.rpc).toHaveBeenCalledWith("worker_store_email_event", {
      _provider_event_id: "event-1",
      _outbox_id: "00000000-0000-0000-0000-000000000001",
      _kind: "delivered",
      _occurred_at: new Date(1793471400 * 1000).toISOString(),
    });
  });

  it("returns retryable failure when durable event storage is unavailable", async () => {
    mocks.rpc.mockResolvedValue({ error: { message: "temporary" } });
    const body = '[{"sg_event_id":"event-2","event":"deferred","timestamp":1793471400,"outbox_id":"00000000-0000-0000-0000-000000000002"}]';
    const response = await POST(signedRequest(body));

    expect(response.status).toBe(503);
  });

  it("acknowledges a provider retry after durable storage reports a duplicate", async () => {
    mocks.rpc.mockResolvedValue({ error: null, data: false });
    const body = '[{"sg_event_id":"event-duplicate","event":"delivered","timestamp":1793471400,"outbox_id":"00000000-0000-0000-0000-000000000003"}]';
    const response = await POST(signedRequest(body));

    expect(response.status).toBe(204);
  });

  it("rejects malformed JSON even if the signature layer accepts its raw bytes", async () => {
    const response = await POST(signedRequest("not-json"));
    expect(response.status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
