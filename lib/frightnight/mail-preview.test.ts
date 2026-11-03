import { beforeEach, describe, expect, it, vi } from "vitest";
const stubs = vi.hoisted(() => ({ snapshot: vi.fn(), rpc: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", async () => { const { ApiError } = await import("@/lib/http/api"); return { frightnightSnapshot: stubs.snapshot, rpcError: () => { throw new ApiError(403, "FORBIDDEN", "Geen toegang"); } }; });
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: stubs.rpc }) }) }));
import { GET } from "@/app/api/frightnight/mail-preview/route";
import { ApiError } from "@/lib/http/api";
const id = "1b30219e-e56d-4e0c-8361-d1c290776ac0";
const request = () => new Request(`https://staging-halloween.duindorpdoet.nl/api/frightnight/mail-preview?id=${id}&cursor=50`);
beforeEach(() => {
  vi.resetAllMocks();
  stubs.snapshot.mockResolvedValue({ actor: { capabilities: ["payments_manage"] }, event: { slug: "frightnight-2027-test-own" } });
  stubs.rpc.mockResolvedValue({ data: { items: [{ id, template: "frightnight-payment-confirmed", mode: "sink", payload: { brandVersion: 7, orderId: id, amountCents: 1050 } }] }, error: null });
});
describe("editie- en actorbegrensde mailpreview zonder bezorging", () => {
  it("rendert alleen de huidige actorpagina met private no-store en beperkende CSP", async () => {
    const result = await GET(request());
    expect(result.status).toBe(200); expect(result.headers.get("cache-control")).toBe("private, no-store");
    expect(result.headers.get("content-security-policy")).toContain("default-src 'none'");
    const html = await result.text();
    expect(html).toContain("€ 10,50"); expect(html).toContain('alt="De Pompoenkoning"'); expect(html).toContain("data:image/webp;base64,");
    expect(stubs.rpc).toHaveBeenCalledExactlyOnceWith("frightnight_admin_list", { p_slug: "frightnight-2027-test-own", p_resource: "sink", p_cursor: 50, p_limit: 100 });
  });
  it("weigert onbekende sessie en deelnemer vóór de lijst wordt gelezen", async () => {
    stubs.snapshot.mockRejectedValueOnce(new ApiError(401, "SIGN_IN_REQUIRED", "Log in"));
    expect((await GET(request())).status).toBe(401);
    stubs.snapshot.mockResolvedValue({ actor: { capabilities: [] }, event: { slug: "frightnight-2027-test-own" } });
    expect((await GET(request())).status).toBe(403); expect(stubs.rpc).not.toHaveBeenCalled();
  });
  it("vindt een mail-ID uit een andere editie niet en bewaart databaseweigering", async () => {
    stubs.rpc.mockResolvedValueOnce({ data: { items: [] }, error: null });
    expect((await GET(request())).status).toBe(404);
    stubs.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501" } });
    expect((await GET(request())).status).toBe(403);
  });
  it("weigert onbekende of gemanipuleerde capturepayloads", async () => {
    stubs.rpc.mockResolvedValue({ data: { items: [{ id, template: "frightnight-payment-confirmed", mode: "sink", payload: { brandVersion: 7, amountCents: -1, orderId: id } }] }, error: null });
    expect((await GET(request())).status).toBe(409);
  });
});
