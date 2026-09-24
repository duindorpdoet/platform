import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => ({
    ABUSE_HASH_SECRET: "unit-test-secret-with-enough-entropy",
    EVENT_SLUG: "duindorp-halloween-2026",
  }),
  allowedOrigins: () => new Set(["http://localhost:3000"]),
}));
vi.mock("@/lib/supabase/privileged", () => ({
  createPrivilegedClient: () => ({ schema: () => ({ rpc: mocks.rpc }) }),
}));

import { POST } from "./route";

function request(overrides: Record<string, unknown> = {}, forwardedFor = "127.0.0.7") {
  return new Request("http://localhost:3000/api/public/portal-registration", {
    method: "POST",
    headers: { "content-type": "application/json", origin: "http://localhost:3000", "x-forwarded-for": forwardedFor },
    body: JSON.stringify({
      email: "Bewoner@Example.invalid",
      contactName: "Testbewoner",
      phone: "0612345678",
      address: { street: "Fictieve straat", houseNumber: "15", addition: "", postalCode: "2584 AB" },
      website: "",
      startedAt: Date.now() - 1000,
      ...overrides,
    }),
  });
}

describe("pre-OTP house registration endpoint", () => {
  beforeEach(() => mocks.rpc.mockReset().mockResolvedValue({ data: { accepted: true, intakeId: "intake-1" }, error: null }));

  it("durably stores only contact and address details before the OTP request continues", async () => {
    const response = await POST(request());
    expect(response.status).toBe(201);
    expect(mocks.rpc).toHaveBeenCalledOnce();
    expect(mocks.rpc).toHaveBeenCalledWith("portal_registration_begin", expect.objectContaining({
      _event_slug: "duindorp-halloween-2026",
      _email: "bewoner@example.invalid",
      _contact_name: "Testbewoner",
      _street: "Fictieve straat",
      _house_number: "15",
      _postal_code: "2584 AB",
      _opaque_subject_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
    }));
    expect(JSON.stringify(mocks.rpc.mock.calls[0])).not.toContain("portalName");
  });

  it("keeps one rate-limit identity for an email when forwarded headers change", async () => {
    await POST(request({}, "198.51.100.10"));
    await POST(request({}, "203.0.113.20, 192.0.2.1"));

    expect(mocks.rpc).toHaveBeenCalledTimes(2);
    const first = mocks.rpc.mock.calls[0][1] as { _opaque_subject_hash: string };
    const second = mocks.rpc.mock.calls[1][1] as { _opaque_subject_hash: string };
    expect(first._opaque_subject_hash).toBe(second._opaque_subject_hash);
  });

  it("rejects an incomplete concept before touching privileged storage", async () => {
    const response = await POST(request({ phone: "" }));
    expect(response.status).toBe(422);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("preserves the independently configured closed registration channel", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: { message: "PORTAL_REGISTRATION_CLOSED", code: "P0001" } });
    const response = await POST(request());
    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toMatchObject({ error: { code: "PORTAL_REGISTRATION_CLOSED" } });
  });
});
