import { beforeEach, describe, expect, it, vi } from "vitest";
const stubs = vi.hoisted(() => ({ actor: vi.fn(), rpc: vi.fn(), service: vi.fn(), selected: vi.fn(), snapshot: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", async () => {
  const { ApiError } = await import("@/lib/http/api");
  return { frightnightActor: stubs.actor, frightnightSnapshot: stubs.snapshot, frightnightServiceRpc: stubs.service, frightnightConfig: () => ({ APP_URL: origin }), smallJson: (request: Request) => request.json(), rpcError: () => { throw new ApiError(403, "FORBIDDEN", "Geen toegang"); } };
});
vi.mock("./edition-context", () => ({ activeFrightnightSlug: async () => "frightnight-2027-test-januari", validTestSlug: (slug: string) => /^frightnight-2027-test(?:-[a-z0-9-]+)?$/.test(slug), selectFrightnightSlug: stubs.selected, editionInvitationSecret: () => "local-test-only-secret-for-edition-entry" }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: stubs.rpc }) }) }));
import { GET, POST } from "@/app/api/frightnight/access/route";
import { POST as selectEdition } from "@/app/api/frightnight/edition/route";
import { POST as inviteEdition } from "@/app/api/frightnight/edition/invite/route";
import { createEditionInvitation } from "./edition-invitation";
const origin = "http://localhost:3000";
const request = (body: unknown, requestOrigin = origin) => new Request(`${origin}/api/frightnight/access`, { method: "POST", headers: { origin: requestOrigin, "content-type": "application/json" }, body: JSON.stringify(body) });
beforeEach(() => { vi.resetAllMocks(); stubs.actor.mockResolvedValue({ userId: "verified-actor" }); stubs.rpc.mockResolvedValue({ data: { members: [] }, error: null }); });
describe("editiegebonden toegangsbeheer", () => {
  it("bindt lezen en muteren aan de servereditie, met de eigen JWT-client", async () => {
    expect((await GET(new Request(`${origin}/api/frightnight/access`))).status).toBe(200);
    expect(stubs.rpc).toHaveBeenCalledWith("admin_access_snapshot", { _event_slug: "frightnight-2027-test-januari" });
    const result = await POST(request({ email: "tester@example.invalid", capabilities: ["payments_manage"], expectedCapabilities: [], reason: "Bewust financieel testbeheer" }));
    expect(result.status).toBe(200);
    expect(stubs.rpc).toHaveBeenLastCalledWith("admin_set_user_capabilities", expect.objectContaining({ _event_slug: "frightnight-2027-test-januari", _expected_capabilities: [] }));
  });
  it("weigert een meegegeven productie-editie of eigen actor/rolvelden vóór SQL", async () => {
    const result = await POST(request({ email: "tester@example.invalid", capabilities: ["event_admin"], expectedCapabilities: [], reason: "Nieuwe testbeheerder", eventSlug: "duindorp-halloween-2026", actor: "victim" }));
    expect(result.status).toBe(422); expect(stubs.rpc).not.toHaveBeenCalled();
  });
  it("weigert vreemde origin en bewaart databaseweigering zonder privécache", async () => {
    expect((await POST(request({}, "https://other.example"))).status).toBe(403);
    expect(stubs.actor).not.toHaveBeenCalled();
    stubs.rpc.mockResolvedValue({ data: null, error: { code: "42501" } });
    const result = await GET(new Request(`${origin}/api/frightnight/access`));
    expect(result.status).toBe(403); expect(result.headers.get("cache-control")).toBe("private, no-store");
  });
});
describe("een eigen testinschrijving openen via uitnodiging", () => {
  const target = { event: { test: true, environment: "staging", slug: "frightnight-2027-test-januari", closed: false }, registration: null, ownZones: [], actor: { capabilities: [] } };
  it("weigert alleen een gekende editiecode voor een nieuwe tester", async () => {
    stubs.rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "EDITION_ACCESS_REQUIRED" } });
    expect((await selectEdition(request({ slug: target.event.slug }))).status).toBe(403);
    expect(stubs.selected).not.toHaveBeenCalled();
    expect(stubs.service).not.toHaveBeenCalled();
  });
  it("laat expliciete instemming met geldige ondertekende link de lege eigen flow openen", async () => {
    stubs.rpc.mockResolvedValue({ data: target, error: null });
    const invitation = createEditionInvitation(target.event.slug, "local-test-only-secret-for-edition-entry").token;
    const result = await selectEdition(request({ invitation, consent: true }));
    expect(result.status).toBe(200);
    expect(stubs.service).toHaveBeenCalledWith("frightnight_entry_grant", {
      p_slug: target.event.slug,
      p_actor: "verified-actor",
      p_expires_at: expect.any(String),
      p_invitation_digest: expect.stringMatching(/^[a-f0-9]{64}$/),
    });
    expect(stubs.service.mock.invocationCallOrder[0]).toBeLessThan(stubs.rpc.mock.invocationCallOrder[0]);
    expect(stubs.selected).toHaveBeenCalledWith("verified-actor", target.event.slug);
  });
  it("selecteert een nog lege kopie alleen wanneer de database de persoonlijke entry toestaat", async () => {
    stubs.rpc.mockResolvedValue({ data: target, error: null });
    expect((await selectEdition(request({ slug: target.event.slug }))).status).toBe(200);
    expect(stubs.service).not.toHaveBeenCalled();
    expect(stubs.selected).toHaveBeenCalledWith("verified-actor", target.event.slug);
  });
  it("bewaart geen editiekeuze als het server-only grantcommand faalt", async () => {
    const { ApiError } = await import("@/lib/http/api");
    stubs.service.mockRejectedValue(new ApiError(403, "EDITION_ACCESS_REQUIRED", "Geen toegang"));
    const invitation = createEditionInvitation(target.event.slug, "local-test-only-secret-for-edition-entry").token;
    expect((await selectEdition(request({ invitation, consent: true }))).status).toBe(403);
    expect(stubs.rpc).not.toHaveBeenCalled(); expect(stubs.selected).not.toHaveBeenCalled();
  });
  it("geeft via de link geen rol en weigert vervallen/gesloten instroom", async () => {
    const invitation = createEditionInvitation(target.event.slug, "local-test-only-secret-for-edition-entry").token;
    expect((await selectEdition(request({ invitation, consent: true, role: "event_admin" }))).status).toBe(422);
    expect((await selectEdition(request({ invitation: invitation + "bad", consent: true }))).status).toBe(403);
    expect(stubs.service).not.toHaveBeenCalled();
    stubs.rpc.mockResolvedValue({ data: { ...target, event: { ...target.event, closed: true } }, error: null });
    expect((await selectEdition(request({ invitation, consent: true }))).status).toBe(403);
    expect(stubs.selected).not.toHaveBeenCalled();
  });
  it("laat uitsluitend de organisator een beperkte link voor de actuele open editie maken", async () => {
    stubs.snapshot.mockResolvedValue(target);
    expect((await inviteEdition(request({}))).status).toBe(403);
    stubs.snapshot.mockResolvedValue({ ...target, actor: { capabilities: ["event_admin"] } });
    const result = await inviteEdition(request({}));
    expect(result.status).toBe(200);
    const { data } = await result.json();
    expect(data.grants).toBe("own-registration-only");
    expect(new URL(data.url).pathname).toBe("/nachtpas");
    expect(result.headers.get("cache-control")).toBe("private, no-store");
  });
});
