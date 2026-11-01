import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const state = vi.hoisted(() => ({ auth: vi.fn(), rpc: vi.fn(), abort: vi.fn() }));
vi.mock("@/lib/account/server", () => ({ accountClient: state.auth }));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => ({ EVENT_SLUG: "synthetic-event" }), allowedOrigins: () => new Set(["https://app.example.invalid"]) }));
import { ApiError } from "@/lib/http/api";
import { GET, POST } from "./route";
const id = "11111111-1111-4111-8111-111111111111";
const fixed = { closed: true, event: { id, slug: "synthetic-event", title: "Synthetische avond" }, closure: { id, subject: "Vast", body: "Bewaard" } };
const post = (body: object, origin = "https://app.example.invalid") => new Request("https://app.example.invalid/api/event-evening/closure", { method: "POST", headers: { Origin: origin, "Content-Type": "application/json" }, body: JSON.stringify(body) });
const confirm = { eventSlug: "synthetic-event", action: "confirm", commandId: id, subject: "  Dank jullie! 🎃 ", body: "\nBeste deelnemers,\n\nZelf toegevoegde alinea.\n" };
beforeEach(() => {
  vi.clearAllMocks();
  state.abort.mockResolvedValue({ data: fixed, error: null });
  state.rpc.mockImplementation(() => Object.assign(Promise.resolve({ data: fixed, error: null }), { abortSignal: state.abort }));
  state.auth.mockResolvedValue({ client: { schema: () => ({ rpc: state.rpc }) }, user: { id } });
});
describe("deliberate event closure HTTP boundary", () => {
  it("opening the admin modal reads only; no command, mail or physical action", async () => {
    const request = new Request("https://app.example.invalid/api/event-evening/closure?eventSlug=synthetic-event&scope=admin");
    const response = await GET(request);
    expect(response.status).toBe(200);
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("event_closure_admin_snapshot", { _event_slug: "synthetic-event" });
    expect(state.abort).toHaveBeenCalledExactlyOnceWith(request.signal);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(response.headers.get("vary")).toBe("Cookie");
  });
  it("uses participant authorization for the default read scope", async () => {
    await GET(new Request("https://app.example.invalid/api/event-evening/closure?eventSlug=synthetic-event"));
    expect(state.rpc).toHaveBeenCalledWith("event_closure_snapshot", { _event_slug: "synthetic-event" });
  });
  it("passes the complete confirmed copy and command identity verbatim without a mutation abort signal", async () => {
    const response = await POST(post(confirm));
    expect(response.status).toBe(200);
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("event_closure_confirm", { _event_slug: "synthetic-event", _subject: confirm.subject, _body: confirm.body, _command_id: id });
    expect(state.abort).not.toHaveBeenCalled();
  });
  it("returns the existing immutable confirmation from the server after a competing or repeated command", async () => {
    const response = await POST(post({ ...confirm, subject: "Een verliezend bericht" }));
    expect((await response.json()).data).toEqual(fixed);
    expect(state.rpc).toHaveBeenCalledTimes(1);
  });
  it("only acknowledges a concrete closure for the authenticated account", async () => {
    await POST(post({ eventSlug: "synthetic-event", action: "acknowledge", closureId: id }));
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("event_closure_acknowledge", { _event_slug: "synthetic-event", _closure_id: id });
  });
  it("uses the restricted retry command without addresses, recipient ids or provider retries from the client", async () => {
    await POST(post({ eventSlug: "synthetic-event", action: "retry_failed" }));
    expect(state.rpc).toHaveBeenCalledExactlyOnceWith("event_closure_retry_failed", { _event_slug: "synthetic-event" });
  });
  it.each([
    { ...confirm, admin: true },
    { ...confirm, householdId: id },
    { ...confirm, subject: "Onderwerp\r\nBcc: stranger@example.invalid" },
    { ...confirm, body: " " },
    { ...confirm, body: "x".repeat(20_001) },
    { ...confirm, commandId: "no-idempotency" },
    { eventSlug: "synthetic-event", action: "acknowledge" },
  ])("rejects malformed or forged command fields before auth/RPC", async body => {
    expect((await POST(post(body))).status).toBe(422);
    expect(state.auth).not.toHaveBeenCalled();
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("rejects another event and untrusted origin without touching the database", async () => {
    expect((await POST(post({ ...confirm, eventSlug: "other-event" }))).status).toBe(404);
    expect((await POST(post(confirm, "https://untrusted.example.invalid"))).status).toBe(403);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("bounds actual request bytes and never starts a partial confirmation", async () => {
    expect((await POST(post({ ...confirm, body: "🎃".repeat(30_000) }))).status).toBe(413);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("preserves server-side event-role denial and clears cacheability on error", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "NOT_AUTHORIZED" } });
    const response = await POST(post(confirm));
    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect((await response.json()).error.code).toBe("NOT_AUTHORIZED");
  });
  it("requires a verified current account", async () => {
    state.auth.mockRejectedValue(new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in."));
    expect((await POST(post(confirm))).status).toBe(401);
    expect(state.rpc).not.toHaveBeenCalled();
  });
  it("does not retry an unknown RPC result or expose raw database text", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "57014", message: "private fixture data" } });
    const response = await POST(post(confirm));
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain("private fixture");
    expect(state.rpc).toHaveBeenCalledTimes(1);
  });
  it("reports an ineligible event as a rejected command, not an uncertain database outage", async () => {
    state.rpc.mockResolvedValue({ data: null, error: { code: "23514", message: "EVENT_NOT_CLOSABLE" } });
    const response = await POST(post(confirm));
    expect(response.status).toBe(409);
    expect((await response.json()).error.code).toBe("EVENT_NOT_CLOSABLE");
    expect(state.rpc).toHaveBeenCalledTimes(1);
  });
});
