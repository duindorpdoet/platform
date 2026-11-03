import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ snapshot: vi.fn(), rpc: vi.fn(), walk: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", () => ({ frightnightSnapshot: mocks.snapshot, rpcError: () => { throw new Error("database rejected"); } }));
vi.mock("./walking", () => ({ walkingRoute: mocks.walk }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: mocks.rpc }) }) }));
import { GET } from "@/app/api/frightnight/admin/walk/route";
const first = "f7270000-0000-4000-8000-000000000001", second = "f7270000-0000-4000-8000-000000000002";
const request = () => new Request(`http://localhost:3000/api/frightnight/admin/walk?fromZoneId=${first}&toZoneId=${second}&latitude=0&longitude=100`);
beforeEach(() => {
  vi.resetAllMocks();
  mocks.snapshot.mockResolvedValue({ actor: { capabilities: ["event_admin"] }, event: { slug: "frightnight-2027-test-januari" } });
  mocks.rpc.mockResolvedValue({ data: { items: [{ id: first, latitude: 52.095, longitude: 4.25 }, { id: second, latitude: 52.096, longitude: 4.251 }], total: 2 }, error: null });
  mocks.walk.mockResolvedValue({ available: true, minutes: 3, geometry: { type: "LineString", coordinates: [[4.25, 52.095], [4.251, 52.096]] } });
});
describe("servergebonden wandelpreview voor de organisatie", () => {
  it("neemt uitsluitend coördinaten uit de eigen geautoriseerde editie", async () => {
    const response = await GET(request()); expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith("frightnight_admin_list", expect.objectContaining({ p_slug: "frightnight-2027-test-januari" }));
    expect(mocks.walk).toHaveBeenCalledWith({ latitude: 52.095, longitude: 4.25 }, { latitude: 52.096, longitude: 4.251 });
  });
  it("weigert gewone deelnemers en vreemde zone-UUID's zonder externe oproep", async () => {
    mocks.snapshot.mockResolvedValue({ actor: { capabilities: [] }, event: { slug: "frightnight-2027-test-januari" } });
    expect((await GET(request())).status).toBe(403); expect(mocks.rpc).not.toHaveBeenCalled();
    mocks.snapshot.mockResolvedValue({ actor: { capabilities: ["event_admin"] }, event: { slug: "frightnight-2027-test-januari" } });
    mocks.rpc.mockResolvedValue({ data: { items: [{ id: first, latitude: 52.095, longitude: 4.25 }], total: 1 }, error: null });
    expect((await GET(request())).status).toBe(422); expect(mocks.walk).not.toHaveBeenCalled();
  });
});
