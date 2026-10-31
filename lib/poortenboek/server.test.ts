import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({
  fetch: vi.fn<typeof fetch>(),
  jar: new Map<string, string>(),
}));
vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (key: string) => mocks.jar.has(key) ? { value: mocks.jar.get(key) } : undefined,
  }),
}));
vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => ({ APP_ENVIRONMENT: "production", POORTENBOEK_DEMO_ENABLED: "false" }),
}));
vi.mock("@/lib/supabase/privileged", async () => {
  const { createClient } = await import("@supabase/supabase-js");
  return {
    createPrivilegedClient: () => createClient("https://supabase.invalid", "sb_secret_test", {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { fetch: (...args) => mocks.fetch(...args) },
    }),
  };
});

import { CHILD_COOKIE, childRpc, childSnapshot } from "./server";
import { tokenHash } from "./crypto";

const snapshot = { child: { id: "child-a" } };
const success = () => new Response(JSON.stringify(snapshot), {
  headers: { "Content-Type": "application/json" },
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.useFakeTimers();
  mocks.jar.clear();
  mocks.jar.set(CHILD_COOKIE, "a".repeat(43));
  mocks.fetch.mockResolvedValue(success());
});
afterEach(() => { vi.useRealTimers(); });

describe("snapshot RPC cancellation with the installed Supabase client", () => {
  it("keeps token hashing and passes the request signal through the real SDK", async () => {
    const controller = new AbortController();
    const remove = vi.spyOn(controller.signal, "removeEventListener");
    expect(await childSnapshot(controller.signal)).toEqual(snapshot);
    const [url, options] = mocks.fetch.mock.calls[0];
    expect(String(url)).toBe("https://supabase.invalid/rest/v1/rpc/poortenboek_child_action");
    expect(options?.method).toBe("POST");
    expect(JSON.parse(String(options?.body))).toEqual({
      _token_hash: tokenHash("a".repeat(43)), _action: "snapshot",
    });
    expect(options?.signal).toBeInstanceOf(AbortSignal);
    expect(remove).toHaveBeenCalledWith("abort", expect.any(Function));
    expect(vi.getTimerCount()).toBe(0);
  });

  it("never starts an RPC for an already aborted or missing child session", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(childSnapshot(controller.signal)).rejects.toMatchObject({ name: "AbortError" });
    mocks.jar.clear();
    expect(await childSnapshot()).toBeNull();
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("cancels a pending response body and clears its timer on browser cancellation", async () => {
    let closeBody!: (error: unknown) => void;
    mocks.fetch.mockImplementationOnce(async (_url, options) => {
      const stream = new ReadableStream({ start(controller) { closeBody = error => controller.error(error); } });
      options?.signal?.addEventListener("abort", () => closeBody(options.signal?.reason), { once: true });
      return new Response(stream, { headers: { "Content-Type": "application/json" } });
    });
    const controller = new AbortController();
    const result = childSnapshot(controller.signal);
    const rejection = expect(result).rejects.toMatchObject({ name: "AbortError" });
    await vi.waitFor(() => expect(mocks.fetch).toHaveBeenCalledOnce());
    controller.abort();
    await rejection;
    expect(vi.getTimerCount()).toBe(0);
    expect(mocks.fetch).toHaveBeenCalledOnce();
  });

  it("bounds snapshot HTTP work at 15 seconds without an internal retry", async () => {
    mocks.fetch.mockImplementationOnce((_url, options) => new Promise((_resolve, reject) => {
      options?.signal?.addEventListener("abort", () => reject(options.signal?.reason), { once: true });
    }));
    const result = childSnapshot();
    const rejection = expect(result).rejects.toMatchObject({ name: "TimeoutError" });
    await vi.waitFor(() => expect(mocks.fetch).toHaveBeenCalledOnce());
    await vi.advanceTimersByTimeAsync(15_000);
    await rejection;
    expect(mocks.fetch).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects a late success even when the transport ignores its abort signal", async () => {
    let finish!: (response: Response) => void;
    mocks.fetch.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const controller = new AbortController();
    const result = childSnapshot(controller.signal);
    const rejection = expect(result).rejects.toMatchObject({ name: "AbortError" });
    await vi.waitFor(() => expect(mocks.fetch).toHaveBeenCalledOnce());
    controller.abort();
    finish(success());
    await rejection;
    expect(mocks.fetch).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("retains revoked-session handling and propagates temporary failures", async () => {
    mocks.fetch.mockResolvedValueOnce(new Response(JSON.stringify({
      message: "CHILD_SESSION_INVALID", code: "P0001", details: null, hint: null,
    }), { status: 400 }));
    expect(await childSnapshot()).toBeNull();
    mocks.fetch.mockResolvedValueOnce(new Response("unavailable", { status: 503 }));
    await expect(childSnapshot()).rejects.toThrow("unavailable");
    expect(mocks.fetch).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("does not impose a snapshot deadline or signal on mutating RPCs", async () => {
    let finish!: (response: Response) => void;
    mocks.fetch.mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const result = childRpc("poortenboek_child_action", {
      _token_hash: tokenHash("a".repeat(43)), _action: "practice", _request_id: "one-idempotency-key",
    });
    await vi.waitFor(() => expect(mocks.fetch).toHaveBeenCalledOnce());
    expect(mocks.fetch.mock.calls[0][1]?.signal).toBeUndefined();
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(30_000);
    finish(success());
    expect(await result).toEqual(snapshot);
    expect(mocks.fetch).toHaveBeenCalledOnce();
  });
});
