import { beforeEach, describe, expect, it, vi } from "vitest";
import { clearPrivateSnapshots, readPrivateSnapshot, storePrivateSnapshot } from "./private-snapshot";

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); },
    setItem: (key, value) => { values.set(key, value); },
  };
}

describe("private offline group snapshots", () => {
  const postMessage = vi.fn();

  beforeEach(() => {
    vi.useRealTimers();
    vi.stubGlobal("localStorage", memoryStorage());
    vi.stubGlobal("navigator", { serviceWorker: { controller: { postMessage } } });
    postMessage.mockReset();
  });

  it("binds a stored snapshot to both the user and group key", () => {
    storePrivateSnapshot("user-a", "group-1", { stop: "current-only" });

    expect(readPrivateSnapshot("user-a", "group-1")).toEqual({ stop: "current-only" });
    expect(readPrivateSnapshot("user-b", "group-1")).toBeNull();
    expect(readPrivateSnapshot("user-a", "group-2")).toBeNull();
  });

  it("drops cached pre-marker-fix destinations rather than showing an old address pin", () => {
    localStorage.setItem("duindorp-private-group:ops2:user-a:group-1", JSON.stringify({ userId: "user-a", expiresAt: Date.now() + 60_000, snapshot: { coordinate: [4.26, 52.09] } }));
    expect(readPrivateSnapshot("user-a", "group-1")).toBeNull();
    expect(localStorage.length).toBe(0);
  });

  it("expires stale private data and removes it from storage", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-31T18:00:00Z"));
    storePrivateSnapshot("user-a", "group-1", { stop: "old" }, 30);
    vi.advanceTimersByTime(30 * 60_000 + 1);

    expect(readPrivateSnapshot("user-a", "group-1")).toBeNull();
    expect(localStorage.length).toBe(0);
  });

  it("clears every account snapshot on logout without touching public state", () => {
    storePrivateSnapshot("user-a", "group-1", { stop: 1 });
    storePrivateSnapshot("user-b", "group-2", { stop: 2 });
    localStorage.setItem("public-preference", "kept");

    clearPrivateSnapshots();

    expect(readPrivateSnapshot("user-a", "group-1")).toBeNull();
    expect(readPrivateSnapshot("user-b", "group-2")).toBeNull();
    expect(localStorage.getItem("public-preference")).toBe("kept");
    expect(postMessage).toHaveBeenCalledWith({ type: "CLEAR_PRIVATE_CACHE" });
  });
});
