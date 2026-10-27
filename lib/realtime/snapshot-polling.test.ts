import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { startSnapshotPolling } from "./snapshot-polling";

let browser: EventTarget, page: EventTarget & { visibilityState: string }, network: { onLine: boolean };
let stop: (() => void) | undefined;
beforeEach(() => {
  vi.useFakeTimers();
  vi.spyOn(Math, "random").mockReturnValue(.5);
  browser = new EventTarget();
  page = Object.assign(new EventTarget(), { visibilityState: "visible" });
  network = { onLine: true };
  vi.stubGlobal("window", browser);
  vi.stubGlobal("document", page);
  vi.stubGlobal("navigator", network);
});
afterEach(() => { stop?.(); stop = undefined; vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("visible fallback polling", () => {
  it("polls without a WebSocket and schedules the next poll after the read completes", async () => {
    let finish!: () => void;
    const read = vi.fn().mockImplementationOnce(() => new Promise<void>(resolve => { finish = resolve; })).mockResolvedValue(undefined);
    stop = startSnapshotPolling(read);
    await vi.advanceTimersByTimeAsync(16_499);
    expect(read).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(read).toHaveBeenCalledTimes(1);
    finish();
    await vi.advanceTimersByTimeAsync(16_500);
    expect(read).toHaveBeenCalledTimes(2);
  });

  it("skips hidden and offline reads, then coalesces wake events with bounded jitter", async () => {
    const read = vi.fn();
    stop = startSnapshotPolling(read);
    page.visibilityState = "hidden";
    await vi.advanceTimersByTimeAsync(16_500);
    expect(read).not.toHaveBeenCalled();
    page.visibilityState = "visible";
    network.onLine = false;
    browser.dispatchEvent(new Event("focus"));
    await vi.advanceTimersByTimeAsync(500);
    expect(read).not.toHaveBeenCalled();
    network.onLine = true;
    for (const type of ["online", "focus", "pageshow"]) browser.dispatchEvent(new Event(type));
    page.dispatchEvent(new Event("visibilitychange"));
    await vi.advanceTimersByTimeAsync(499);
    expect(read).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(read).toHaveBeenCalledTimes(1);
  });

  it("continues bounded fallback reads after a failed request", async () => {
    const read = vi.fn().mockRejectedValueOnce(new Error("service unavailable")).mockResolvedValue(undefined);
    stop = startSnapshotPolling(read, 20_000);
    await vi.advanceTimersByTimeAsync(22_000);
    expect(read).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(21_999);
    expect(read).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(read).toHaveBeenCalledTimes(2);
  });

  it("removes listeners and timers on unmount even with a pending read", async () => {
    let finish!: () => void;
    const read = vi.fn(() => new Promise<void>(resolve => { finish = resolve; }));
    stop = startSnapshotPolling(read);
    browser.dispatchEvent(new Event("focus"));
    await vi.advanceTimersByTimeAsync(500);
    stop();
    browser.dispatchEvent(new Event("online"));
    finish();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(read).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });
});
