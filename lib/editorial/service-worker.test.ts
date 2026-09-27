import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { describe, expect, it, vi } from "vitest";
function worker() {
  const listeners: Record<string, (e: unknown) => void> = {};
  const showNotification = vi.fn().mockResolvedValue(undefined),
    navigate = vi.fn().mockResolvedValue(undefined),
    focus = vi.fn(),
    openWindow = vi.fn(),
    fetcher = vi.fn().mockRejectedValue(new Error("offline"));
  const cache = {
    match: vi.fn().mockResolvedValue(new Response("Neutrale offlinepagina")),
    open: vi.fn(),
  };
  runInNewContext(readFileSync("public/sw.js", "utf8"), {
    self: {
      addEventListener: (name: string, fn: (e: unknown) => void) =>
        (listeners[name] = fn),
      location: { origin: "https://fixture.invalid" },
      registration: { showNotification },
      clients: {
        matchAll: async () => [
          { url: "https://fixture.invalid/omgeving", navigate, focus },
        ],
        openWindow,
      },
    },
    URL,
    Response,
    fetch: fetcher,
    caches: cache,
  });
  async function event(type: string, data: object) {
    let promise: Promise<unknown> | undefined;
    listeners[type]({
      ...data,
      waitUntil: (p: Promise<unknown>) => (promise = p),
      respondWith: (p: Promise<unknown>) => (promise = p),
    });
    return promise;
  }
  return {
    event,
    showNotification,
    navigate,
    focus,
    openWindow,
    cache,
    fetcher,
  };
}
describe("actual service worker editorial events", () => {
  it("displays generic lockscreen copy and focuses the exact private news link", async () => {
    const w = worker(),
      url =
        "/omgeving/nieuws/de-nacht?push=a0000000-0000-0000-0000-000000000001&device=a0000000-0000-0000-0000-000000000002";
    await w.event("push", {
      data: {
        json: () => ({
          url,
          body: "private household information",
          tag: "news-version",
        }),
      },
    });
    expect(w.showNotification).toHaveBeenCalledWith(
      "De Duindorpse Poorten",
      expect.objectContaining({
        body: "Er staat een nieuw bericht voor je klaar.",
        tag: "news-version",
        data: { url },
      }),
    );
    await w.event("notificationclick", {
      notification: { data: { url }, close: vi.fn() },
    });
    expect(w.navigate).toHaveBeenCalledWith(url);
    expect(w.focus).toHaveBeenCalled();
    expect(w.openWindow).not.toHaveBeenCalled();
  });
  it.each(["https://evil.invalid", "/admin", "/omgeving/nieuws/../../admin"])(
    "does not navigate an unapproved push destination %s",
    async (url) => {
      const w = worker();
      await w.event("notificationclick", {
        notification: { data: { url }, close: vi.fn() },
      });
      expect(w.navigate).toHaveBeenCalledWith("/omgeving");
    },
  );
  it.each([
    "/omgeving/nieuws/ouders/geheim",
    "/api/editorial/admin",
    "/nachtpost/afmelden?token=opaque",
  ])("returns no cached private data for %s", async (path) => {
    const w = worker();
    const result = (await w.event("fetch", {
      request: {
        url: `https://fixture.invalid${path}`,
        method: "GET",
        mode: "navigate",
      },
    })) as Response;
    expect(result.status).toBe(503);
    expect(result.headers.get("cache-control")).toContain("no-store");
    expect(await result.text()).toBe("Neutrale offlinepagina");
    expect(w.cache.open).not.toHaveBeenCalled();
  });
});
