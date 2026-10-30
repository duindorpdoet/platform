import { beforeEach, describe, expect, it, vi } from "vitest";
import type { JointRouteInput } from "@/lib/domain/joint-route-planner";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), getUser: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({ allowedOrigins: () => new Set(["https://staging.example.invalid"]) }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ auth: { getUser: mocks.getUser }, schema: () => ({ rpc: mocks.rpc }) }) }));
import { POST } from "./route";

function input(): JointRouteInput {
  const time = (clock: string) => `2026-10-31T${clock}:00.000Z`;
  const window = { opensAt: time("17:00"), arrivalClosesAt: time("22:00"), closesAt: time("22:00"), visitSeconds: 360, bufferSeconds: 0, maxGroups: 1, maxChildren: 20, maxTotalChildren: 300, headwaySeconds: 300 };
  return { eventId: "synthetic", sourceHash: "a".repeat(64), boardHash: "b".repeat(32), policyVersion: "v1", maxGroupOverrunSeconds: 1800, maxLegWalkingSeconds: 900, maxTotalWalkingSeconds: 3600, needsAnders: false,
    groups: [{ id: "group", code: "G-test", childCount: 3, startNodeId: "start:group", startsAt: time("17:00"), startConfirmed: true, ordinaryStopAt: time("20:30"), desiredEndAt: time("21:00"), maxOrdinaryVisits: null, requiresStepFree: false, accessibilityNeedsReview: false, fixedFirstPortalId: null, excludedPortalIds: [], finale: { portalId: "finale", reservedAt: time("21:00"), reservationValid: true, latestArrivalAt: time("21:24") } }],
    portals: [{ id: "house", code: "P-test", name: "Synthetic house", nodeId: "portal:house", worldSlug: "anders", finale: false, accessibilityStatus: "unknown", windows: [window] }, { id: "finale", code: "P-finale", name: "Synthetic finale", nodeId: "portal:finale", worldSlug: "finale", finale: true, accessibilityStatus: "step_free", windows: [window] }],
    legs: [{ from: "start:group", to: "portal:house", seconds: 60, meters: 60 }, { from: "portal:house", to: "portal:finale", seconds: 60, meters: 60 }, { from: "start:group", to: "portal:finale", seconds: 60, meters: 60 }], before: [], fixedVisits: [] };
}
function request(body: unknown = { eventSlug: "duindorp-halloween-2026" }) {
  return new Request("https://staging.example.invalid/api/admin/routes/proposal", { method: "POST", headers: { origin: "https://staging.example.invalid", "content-type": "application/json" }, body: JSON.stringify(body) });
}
beforeEach(() => {
  mocks.getUser.mockReset().mockResolvedValue({ data: { user: { id: "synthetic-admin" } }, error: null });
  mocks.rpc.mockReset().mockResolvedValue({ data: input(), error: null });
});
describe("explicit authenticated joint route proposal", () => {
  it("loads fresh authorized inputs exactly once and computes without applying, publishing or mailing", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    const proposal = (await response.json()).data;
    expect(proposal.valid).toBe(true);
    expect(proposal.sourceHash).toBe("a".repeat(64));
    expect(proposal.groups[0].finaleArrivalAt).toBe("2026-10-31T17:08:00.000Z");
    expect(proposal.groups[0].finaleChange).toEqual({ portalId: "finale", previousReservedAt: "2026-10-31T21:00:00.000Z", proposedReservedAt: "2026-10-31T17:08:00.000Z" });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("admin_joint_route_planning_input", { _event_slug: "duindorp-halloween-2026" });
    expect(JSON.stringify(proposal)).not.toMatch(/@|accessibility_note|private_address/);
  });
  it("requires actual Auth identity and database capability, never browser-supplied roles", async () => {
    mocks.getUser.mockResolvedValueOnce({ data: { user: null }, error: {} });
    expect((await POST(request())).status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
    mocks.getUser.mockResolvedValueOnce({ data: { user: { id: "participant", user_metadata: { event_admin: true } } }, error: null });
    mocks.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501", message: "private database detail" } });
    const denied = await POST(request());
    expect(denied.status).toBe(403);
    expect(await denied.text()).not.toContain("private database detail");
  });
  it("rejects untrusted origins, oversize input and caller-supplied planning data before database access", async () => {
    const untrusted = request(); untrusted.headers.set("origin", "https://attacker.invalid");
    expect((await POST(untrusted)).status).toBe(403);
    expect((await POST(request({ eventSlug: "duindorp-halloween-2026", sourceHash: "forged" }))).status).toBe(422);
    const oversized = request(); oversized.headers.set("content-length", "2049");
    expect((await POST(oversized)).status).toBe(413);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
