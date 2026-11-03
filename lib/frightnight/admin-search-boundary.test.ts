import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ snapshot: vi.fn(), rpc: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({ allowedOrigins: () => new Set(["http://localhost:3000"]) }));
vi.mock("./server", async () => {
  const { ApiError } = await import("@/lib/http/api");
  return { frightnightSnapshot: mocks.snapshot, smallJson: (request: Request) => request.json(), rpcError: () => { throw new ApiError(403, "FORBIDDEN", "Geen toegang"); } };
});
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: mocks.rpc }) }) }));
import { GET, POST } from "@/app/api/frightnight/admin/list/route";
const origin = "http://localhost:3000";
const request = (body: unknown, from = origin) => new Request(`${origin}/api/frightnight/admin/list`, { method: "POST", headers: { origin: from, "content-type": "application/json" }, body: JSON.stringify(body) });
beforeEach(() => { vi.resetAllMocks(); mocks.snapshot.mockResolvedValue({ event: { slug: "frightnight-2027-test-copy" } }); mocks.rpc.mockResolvedValue({ data: { items: [], total: 153, nextCursor: 50, limit: 50 }, error: null }); });
describe("actor- en editiegebonden serverzoeken", () => {
  it("stuurt zoektekst en filters naar de database en behoudt de gefilterde totalen", async () => {
    const response = await POST(request({ resource: "registrations", search: " Testgezin ", status: "active", routeType: "lantern", paymentStatus: "paid" }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("frightnight_admin_list", { p_slug: "frightnight-2027-test-copy", p_resource: "registrations", p_cursor: 0, p_limit: 50, p_search: "Testgezin", p_filters: { status: "active", routeType: "lantern", paymentStatus: "paid" } });
    expect((await response.json()).data.total).toBe(153);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
  });
  it("weigert bodygestuurde actor/editie, onbegrensd zoeken en een vreemde origin", async () => {
    expect((await POST(request({ resource: "zones", slug: "duindorp-halloween-2026", actor: "other" }))).status).toBe(422);
    expect((await POST(request({ resource: "zones", search: "x".repeat(121) }))).status).toBe(422);
    expect((await POST(request({ resource: "zones" }, "https://other.example"))).status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
  it("behoudt databaseautorisatie en de bestaande begrensde GET-paginering", async () => {
    expect((await GET(new Request(`${origin}/api/frightnight/admin/list?resource=audit&cursor=100&limit=25`))).status).toBe(200);
    expect(mocks.rpc).toHaveBeenLastCalledWith("frightnight_admin_list", expect.objectContaining({ p_slug: "frightnight-2027-test-copy", p_cursor: 100, p_limit: 25, p_search: "", p_filters: {} }));
    mocks.rpc.mockResolvedValue({ data: null, error: { code: "42501" } });
    expect((await POST(request({ resource: "payments" }))).status).toBe(403);
  });
});
