import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const state = vi.hoisted(() => ({ auth: vi.fn(), rpc: vi.fn(), abort: vi.fn() }));
vi.mock("@/lib/account/server", () => ({ accountClient: state.auth }));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => ({ EVENT_SLUG: "synthetic-event" }), allowedOrigins: () => new Set(["https://app.example.invalid"]) }));
import { ApiError } from "@/lib/http/api";
import { GET, POST } from "./route";
const id = "11111111-1111-4111-8111-111111111111";
const fixed = { ready: true, confirmed: true, event: { id, slug: "synthetic-event", title: "Synthetische avond" }, campaign: { id, subject: "Vast", body: "Bewaard" } };
const post = (body: object, origin = "https://app.example.invalid") => new Request("https://app.example.invalid/api/event-evening/portal-certificates", { method: "POST", headers: { Origin: origin, "Content-Type": "application/json" }, body: JSON.stringify(body) });
const confirm = { eventSlug: "synthetic-event", action: "confirm", commandId: id, subject: "  Dank, poortteams! 🎃 ", body: "\nBeste crew,\n\nDenk mee over Duindorp FrightNight.\n" };
beforeEach(() => {
  vi.clearAllMocks();
  state.abort.mockResolvedValue({ data: fixed, error: null });
  state.rpc.mockImplementation(() => Object.assign(Promise.resolve({ data: fixed, error: null }), { abortSignal: state.abort }));
  state.auth.mockResolvedValue({ client: { schema: () => ({ rpc: state.rpc }) }, user: { id } });
});
describe("deliberate portal certificate campaign HTTP boundary", () => {
  it("reads only with the request signal; opening creates no campaign or mail", async () => {
    const request = new Request("https://app.example.invalid/api/event-evening/portal-certificates?eventSlug=synthetic-event");
    const response = await GET(request);
    expect(response.status).toBe(200);
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("portal_certificate_admin_snapshot", { _event_slug: "synthetic-event" });
    expect(state.abort).toHaveBeenCalledExactlyOnceWith(request.signal);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(response.headers.get("vary")).toBe("Cookie");
  });
  it("preserves confirmed text and command identity without attaching a mutation abort signal", async () => {
    expect((await POST(post(confirm))).status).toBe(200);
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("portal_certificate_confirm", { _event_slug: "synthetic-event", _subject: confirm.subject, _body: confirm.body, _command_id: id });
    expect(state.abort).not.toHaveBeenCalled();
  });
  it("delegates safe failed-only recovery without client-selected recipients or provider keys", async () => {
    expect((await POST(post({ eventSlug: "synthetic-event", action: "retry_failed" }))).status).toBe(200);
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("portal_certificate_retry_failed", { _event_slug: "synthetic-event" });
  });
  it.each([
    { ...confirm, recipients: ["stranger@example.invalid"] },
    { ...confirm, userId: id },
    { ...confirm, subject: "Dank\r\nBcc: stranger@example.invalid" },
    { ...confirm, body: " " },
    { ...confirm, body: "x".repeat(20_001) },
    { ...confirm, commandId: "no-idempotency" },
    { eventSlug: "synthetic-event", action: "acknowledge", campaignId: id },
  ])("rejects malformed or forged commands before auth and RPC", async body => {
    expect((await POST(post(body))).status).toBe(422);
    expect(state.auth).not.toHaveBeenCalled();
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("rejects another event and untrusted origin without a database call", async () => {
    expect((await POST(post({ ...confirm, eventSlug: "other-event" }))).status).toBe(404);
    expect((await POST(post(confirm, "https://untrusted.example.invalid"))).status).toBe(403);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("bounds actual request bytes and never starts a partial campaign", async () => {
    expect((await POST(post({ ...confirm, body: "🎃".repeat(30_000) }))).status).toBe(413);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("retains server-side organization authorization and private error caching", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "NOT_AUTHORIZED" } });
    const response = await POST(post(confirm));
    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toContain("no-store");
  });
  it("requires a current verified account", async () => {
    state.auth.mockRejectedValue(new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in."));
    expect((await POST(post(confirm))).status).toBe(401);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("rejects announcing a certificate before the evening is closed", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "23514", message: "CERTIFICATES_NOT_READY" } });
    expect((await POST(post(confirm))).status).toBe(409);
    expect(state.rpc).toHaveBeenCalledTimes(1);
  });
  it("does not retry an unknown result or expose raw database text", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "57014", message: "PRIVATE DATABASE CONTENT" } });
    const response = await POST(post(confirm));
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("PRIVATE DATABASE");
    expect(state.rpc).toHaveBeenCalledTimes(1);
  });
});
