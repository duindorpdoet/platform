import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({
  env: {
    APP_ENVIRONMENT: "production",
    POORTENBOEK_DEMO_ENABLED: "true",
    EVENT_SLUG: "event",
  },
  rpc: vi.fn(),
  writeDemo: vi.fn(),
  snapshot: vi.fn(),
  getUser: vi.fn(),
  jar: new Map<string, string>(),
  setCookie: vi.fn(),
}));
vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (key: string) =>
      mocks.jar.has(key) ? { value: mocks.jar.get(key) } : undefined,
    set: mocks.setCookie,
  }),
}));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => mocks.env }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ auth: { getUser: mocks.getUser } }),
}));
vi.mock("@/lib/http/api", () => ({
  assertTrustedOrigin: (request: Request) => {
    if (request.headers.get("origin") !== "https://example.invalid")
      throw new Error("INVALID_ORIGIN");
  },
}));
vi.mock("@/lib/poortenboek/server", async () => {
  const { demoEnabled } = await import("@/lib/poortenboek/model");
  return {
    canDemo: () =>
      demoEnabled(
        mocks.env.APP_ENVIRONMENT,
        mocks.env.POORTENBOEK_DEMO_ENABLED,
      ),
    childRpc: mocks.rpc,
    childSnapshot: mocks.snapshot,
    readDemo: async () => null,
    writeDemo: mocks.writeDemo,
    childSecrets: () => ({
      pepper: Buffer.alloc(32, 7).toString("base64"),
      encryptionKey: Buffer.alloc(32, 9).toString("base64"),
    }),
    CHILD_COOKIE: "__Host-poortenboek-session",
    DEMO_COOKIE: "__Host-poortenboek-demo",
    DEVICE_COOKIE: "__Host-poortenboek-device",
    cookieOptions: { secure: true, httpOnly: true, sameSite: "lax", path: "/" },
    privateHeaders: {
      "Cache-Control": "private, no-store, max-age=0",
      "X-Robots-Tag": "noindex, nofollow",
    },
  };
});
vi.mock("next/navigation", () => ({
  notFound: () => {
    throw new Error("HTTP_404");
  },
}));
import { GET, POST } from "./route";
import DemoPage from "@/app/poortenboek/demo/page";
import { LOGIN_ERROR } from "@/lib/poortenboek/model";
import { tokenHash } from "@/lib/poortenboek/crypto";
const post = (
  action: string,
  payload: object,
  origin = "https://example.invalid",
) =>
  POST(
    new Request(`https://example.invalid/api/poortenboek/${action}`, {
      method: "POST",
      headers: { origin, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }),
    { params: Promise.resolve({ action }) },
  );
beforeEach(() => {
  vi.clearAllMocks();
  mocks.jar.clear();
  mocks.env.APP_ENVIRONMENT = "production";
  mocks.env.POORTENBOEK_DEMO_ENABLED = "true";
  mocks.rpc.mockResolvedValue({ ok: false, delayMs: 1 });
  mocks.getUser.mockResolvedValue({ data: { user: null }, error: null });
});
describe("child HTTP boundaries", () => {
  it("production demo page is 404 even with the flag enabled", async () => {
    expect(() => DemoPage()).toThrow("HTTP_404");
    expect((await post("demo-phase", { phase: "winner" })).status).toBe(404);
    const result = await post("login", { code: "DEMO26" });
    expect(result.status).toBe(400);
    expect(await result.json()).toEqual({ error: LOGIN_ERROR });
    expect(mocks.writeDemo).not.toHaveBeenCalled();
  });
  it("staging demo requires the flag and writes only its isolated cookie", async () => {
    mocks.env.APP_ENVIRONMENT = "staging";
    mocks.env.POORTENBOEK_DEMO_ENABLED = "false";
    expect(() => DemoPage()).toThrow("HTTP_404");
    mocks.env.POORTENBOEK_DEMO_ENABLED = "true";
    expect((await post("login", { code: " demo26 " })).status).toBe(200);
    expect(mocks.writeDemo).toHaveBeenCalledOnce();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
  it("invalid, limited and backend-failed logins have the same public error", async () => {
    for (const code of ["ABC234", "", "XXXXXX"]) {
      const result = await post("login", { code });
      expect(result.status).toBe(400);
      expect(await result.json()).toEqual({ error: LOGIN_ERROR });
    }
    mocks.rpc.mockRejectedValueOnce(new Error("private database detail"));
    expect(await (await post("login", { code: "ABC234" })).json()).toEqual({
      error: LOGIN_ERROR,
    });
    expect(JSON.stringify(mocks.rpc.mock.calls)).not.toContain("ABC234");
  });
  it("cross-origin writes cannot reach the privileged database", async () => {
    expect(
      (await post("login", { code: "ABC234" }, "https://hostile.invalid"))
        .status,
    ).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
  it("parent identity is obtained from verified Auth, never a supplied actor", async () => {
    mocks.getUser.mockResolvedValue({
      data: { user: { id: "verified-parent" } },
      error: null,
    });
    mocks.rpc.mockResolvedValue({});
    await post("parent", {
      action: "revoke",
      childId: "11111111-1111-4111-8111-111111111111",
      actor: "forged-parent",
    });
    expect(mocks.rpc).toHaveBeenCalledWith(
      "poortenboek_parent",
      expect.objectContaining({ _actor: "verified-parent" }),
    );
  });
  it("child actions require their own cookie and private responses are never cacheable", async () => {
    expect(
      (await post("checklist", { values: Array(6).fill(true) })).status,
    ).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
    mocks.snapshot.mockResolvedValue(null);
    const result = await GET(
      new Request("https://example.invalid/api/poortenboek/snapshot"),
      { params: Promise.resolve({ action: "snapshot" }) },
    );
    expect(result.status).toBe(401);
    expect(result.headers.get("cache-control")).toBe(
      "private, no-store, max-age=0",
    );
    expect(result.headers.get("x-robots-tag")).toBe("noindex, nofollow");
  });
  it("opening as a child requires verified parent Auth and a trusted origin", async () => {
    const payload = { action: "open", childId: "11111111-1111-4111-8111-111111111111" };
    mocks.jar.set("__Host-poortenboek-session", "a".repeat(43));
    expect((await post("parent", payload)).status).toBe(401);
    expect((await post("parent", payload, "https://hostile.invalid")).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.setCookie).not.toHaveBeenCalled();
  });
  it("parent opening sets only an independent child cookie and sends hashed tokens", async () => {
    mocks.getUser.mockResolvedValue({ data: { user: { id: "verified-parent" } }, error: null });
    const previous = "a".repeat(43);
    mocks.jar.set("__Host-poortenboek-session", previous);
    const expiresAt = new Date(Date.now() + 43_200_000).toISOString();
    mocks.rpc.mockResolvedValue({ ok: true, expiresAt });
    const result = await post("parent", {
      action: "open", childId: "11111111-1111-4111-8111-111111111111", actor: "forged",
    });
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ ok: true });
    expect(result.headers.get("cache-control")).toContain("no-store");
    const [name, token, options] = mocks.setCookie.mock.calls[0];
    expect(name).toBe("__Host-poortenboek-session");
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(token).not.toBe(previous);
    expect(options).toEqual({ secure: true, httpOnly: true, sameSite: "lax", path: "/", expires: new Date(expiresAt) });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("poortenboek_parent_open", {
      _actor: "verified-parent", _event_slug: "event", _child_id: "11111111-1111-4111-8111-111111111111",
      _token_hash: tokenHash(token), _previous_token_hash: tokenHash(previous),
    });
    expect(mocks.setCookie.mock.calls.map(([key]) => key)).toEqual(["__Host-poortenboek-session", "__Host-poortenboek-demo"]);
  });
  it("first parent opening provisions an encrypted code with collision retry without exposing it", async () => {
    mocks.getUser.mockResolvedValue({ data: { user: { id: "verified-parent" } }, error: null });
    mocks.rpc
      .mockResolvedValueOnce({ needsCode: true, eventId: "test-event" })
      .mockRejectedValueOnce(Object.assign(new Error("collision"), { code: "23505" }))
      .mockResolvedValueOnce({ ok: true, expiresAt: new Date(Date.now() + 43_200_000).toISOString() });
    const result = await post("parent", { action: "open", childId: "11111111-1111-4111-8111-111111111111" });
    expect(await result.json()).toEqual({ ok: true });
    expect(mocks.rpc).toHaveBeenCalledTimes(3);
    for (const [, args] of mocks.rpc.mock.calls.slice(1)) {
      expect(args._digest).toMatch(/^[a-f0-9]{64}$/);
      expect(args._ciphertext).toMatch(/^v1\./);
      expect(args._token_hash).toBe(mocks.rpc.mock.calls[0][1]._token_hash);
    }
    expect(mocks.rpc.mock.calls[1][1]._digest).not.toBe(mocks.rpc.mock.calls[2][1]._digest);
  });
  it("a rejected child selection preserves the existing child cookie", async () => {
    mocks.getUser.mockResolvedValue({ data: { user: { id: "verified-parent" } }, error: null });
    mocks.rpc.mockRejectedValueOnce(new Error("NOT_AUTHORIZED"));
    expect((await post("parent", { action: "open", childId: "11111111-1111-4111-8111-111111111111" })).status).toBe(401);
    expect(mocks.setCookie).not.toHaveBeenCalled();
  });
});
