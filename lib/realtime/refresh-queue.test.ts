import { afterEach, describe, expect, it, vi } from "vitest";
import { createRefreshQueue, snapshotPollDelay } from "./refresh-queue";

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });
const pending = () => {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
};

describe("snapshot read pressure", () => {
  it("coalesces a burst across topics into one read", async () => {
    vi.useFakeTimers();
    const read = vi.fn(), queue = createRefreshQueue(read, () => 250);
    for (let i = 0; i < 100; i++) queue.invalidate();
    await vi.advanceTimersByTimeAsync(249);
    expect(read).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(read).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(5000);
    expect(read).toHaveBeenCalledTimes(1);
    queue.dispose();
  });

  it("retains one trailing read and never overlaps a slow read", async () => {
    vi.useFakeTimers();
    const first = pending();
    const read = vi.fn().mockImplementationOnce(() => first.promise).mockResolvedValue(undefined);
    const queue = createRefreshQueue(read, () => 250);
    queue.invalidate();
    await vi.advanceTimersByTimeAsync(250);
    for (let i = 0; i < 100; i++) queue.invalidate();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(read).toHaveBeenCalledTimes(1);
    first.resolve();
    await vi.advanceTimersByTimeAsync(250);
    expect(read).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5000);
    expect(read).toHaveBeenCalledTimes(2);
    queue.dispose();
  });

  it("post-command callers await a new read, rather than an older pre-command response", async () => {
    const first = pending();
    let serverVersion = 1, displayedVersion = 0;
    const read = vi.fn(async () => {
      const version = serverVersion;
      if (version === 1) await first.promise;
      displayedVersion = version;
    });
    const queue = createRefreshQueue(read);
    const beforeCommand = queue.load();
    serverVersion = 2;
    const afterCommand = queue.load();
    expect(read).toHaveBeenCalledTimes(1);
    first.resolve();
    await beforeCommand;
    await afterCommand;
    expect(displayedVersion).toBe(2);
    expect(read).toHaveBeenCalledTimes(2);
    queue.dispose();
  });

  it("manual refresh immediately consumes a queued broadcast read", async () => {
    vi.useFakeTimers();
    const read = vi.fn(), queue = createRefreshQueue(read, () => 500);
    queue.invalidate();
    await queue.load();
    expect(read).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1000);
    expect(read).toHaveBeenCalledTimes(1);
    queue.dispose();
  });

  it("a continuous broadcast stream cannot postpone refresh indefinitely", async () => {
    vi.useFakeTimers();
    const read = vi.fn(), queue = createRefreshQueue(read, () => 250);
    for (let i = 0; i < 10; i++) { queue.invalidate(); await vi.advanceTimersByTimeAsync(100); }
    expect(read.mock.calls.length).toBeGreaterThanOrEqual(3);
    queue.dispose();
  });

  it("recovers after a failed read without an automatic retry storm", async () => {
    vi.useFakeTimers();
    const read = vi.fn().mockRejectedValueOnce(new Error("read unavailable")).mockResolvedValue(undefined);
    const queue = createRefreshQueue(read);
    await expect(queue.load()).rejects.toThrow("read unavailable");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(read).toHaveBeenCalledTimes(1);
    await queue.load();
    expect(read).toHaveBeenCalledTimes(2);
    queue.dispose();
  });

  it("discards queued work after source/account teardown, including trailing work", async () => {
    vi.useFakeTimers();
    const first = pending(), read = vi.fn(() => first.promise), queue = createRefreshQueue(read);
    const running = queue.load();
    const queued = queue.load();
    queue.invalidate();
    queue.dispose();
    await queued;
    first.resolve();
    await running;
    await vi.advanceTimersByTimeAsync(5000);
    await queue.load();
    expect(read).toHaveBeenCalledTimes(1);
    const nextRead = vi.fn(), next = createRefreshQueue(nextRead);
    await next.load();
    expect(nextRead).toHaveBeenCalledTimes(1);
    next.dispose();
  });

  it("spreads polling within 100–120% of its interval", () => {
    expect(snapshotPollDelay(15_000, 0)).toBe(15_000);
    expect(snapshotPollDelay(15_000, .5)).toBe(16_500);
    expect(snapshotPollDelay(20_000, .9999)).toBeLessThan(24_000);
    vi.spyOn(Math, "random").mockReturnValue(.5);
    expect(snapshotPollDelay(20_000)).toBe(22_000);
  });
});
