import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ rpc: vi.fn(), getUser: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({ allowedOrigins: () => new Set(["https://staging.example.invalid"]) }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ auth: { getUser: mocks.getUser }, schema: () => ({ rpc: mocks.rpc }) }) }));
import { POST } from "./route";

const eventSlug = "duindorp-halloween-2026";
const portal = "12000000-0000-0000-0000-000000000002";
const save = () => ({ action: "save", eventSlug, expectedVersion: 1, maxTotalWalkingSeconds: 3900,
  maxEarlyFinishSeconds: 1800, organizerCoveragePortalIds: [portal], reason: "Afgesproken routebeleid toepassen" });
function request(body: unknown, key: string | null = "policy-command-unique") {
  const headers = new Headers({ origin: "https://staging.example.invalid", "content-type": "application/json" });
  if (key) headers.set("idempotency-key", key);
  return new Request("https://staging.example.invalid/api/admin/routes/policy", { method: "POST", headers, body: JSON.stringify(body) });
}
beforeEach(() => {
  mocks.getUser.mockReset().mockResolvedValue({ data: { user: { id: "admin" } }, error: null });
  mocks.rpc.mockReset().mockResolvedValue({ data: { version: 1 }, error: null });
});
describe("authorized event route policy", () => {
  it("loads private current policy without a save or client-supplied planning data", async () => {
    const response = await POST(request({ action: "get", eventSlug }, null));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("admin_joint_route_policy_get", { _event_slug: eventSlug });
  });
  it("forwards existing PostgreSQL UUIDs, precise seconds, version and the reusable command key to the locked policy command", async () => {
    const response = await POST(request(save()));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("admin_joint_route_policy_save", { _event_slug: eventSlug,
      _expected_version: 1, _max_total_walking_seconds: 3900, _max_early_finish_seconds: 1800,
      _organizer_coverage_portal_ids: [portal], _reason: save().reason, _idempotency_key: "policy-command-unique" });
  });
  it("requires real identity and database capability, and keeps database error details private", async () => {
    mocks.getUser.mockResolvedValueOnce({ data: { user: null }, error: null });
    expect((await POST(request(save()))).status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501", message: "sensitive database details" } });
    const denied = await POST(request(save()));
    expect(denied.status).toBe(403);
    expect(await denied.text()).not.toContain("sensitive database details");
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "P0001", message: "ROUTE_POLICY_VERSION_STALE" } });
    const stale = await POST(request(save()));
    expect(stale.status).toBe(409);
    expect(await stale.text()).toContain("invoer blijft behouden");
  });
  it("rejects cross-origin writes, missing command keys, forged fields and invalid limits before SQL", async () => {
    const cross = request(save()); cross.headers.set("origin", "https://attacker.invalid");
    expect((await POST(cross)).status).toBe(403);
    expect((await POST(request(save(), null))).status).toBe(400);
    for (const body of [
      { ...save(), maxTotalWalkingSeconds: 0 }, { ...save(), maxEarlyFinishSeconds: -1 },
      { ...save(), organizerCoveragePortalIds: [portal, portal] }, { ...save(), role: "event_admin" },
      { ...save(), expectedVersion: 1.1 }, { ...save(), maxTotalWalkingSeconds: 86_401 },
    ]) expect((await POST(request(body))).status).toBe(422);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
