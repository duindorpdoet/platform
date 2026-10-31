import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RefreshResult, SnapshotRefreshQueue } from "./refresh-queue";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

const success = (value = "snapshot"): RefreshResult<string> => ({ kind: "success", value });
const flush = () => vi.advanceTimersByTimeAsync(0);

describe("SnapshotRefreshQueue", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-31T17:00:00Z"));
  });
  afterEach(() => vi.useRealTimers());

  it("serializes all triggers, including the response body, into one follow-up", async () => {
    const body = deferred<RefreshResult<string>>();
    const second = deferred<RefreshResult<string>>();
    let active = 0;
    let maxActive = 0;
    const run = vi.fn(async () => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      const value = await (run.mock.calls.length === 1 ? body.promise : second.promise);
      active -= 1;
      return value;
    });
    const queue = new SnapshotRefreshQueue({ run, requestTimeoutMs: 60_000 });
    queue.setAvailable(true);
    await vi.advanceTimersByTimeAsync(12_000);
    const focus = queue.request();
    const online = queue.request();
    const manual = queue.request();
    expect(online).toBe(focus);
    expect(manual).toBe(focus);
    expect(run).toHaveBeenCalledTimes(1);
    body.resolve(success("first"));
    await flush();
    expect(run).toHaveBeenCalledTimes(2);
    expect(maxActive).toBe(1);
    second.resolve(success("second"));
    await expect(Promise.all([focus, online, manual])).resolves.toEqual(["second", "second", "second"]);
    await flush();
    expect(run).toHaveBeenCalledTimes(2);
    queue.stop();
  });

  it("polls 12 seconds after completion and schedules no poll while a request is active", async () => {
    const first = deferred<RefreshResult<string>>();
    const run = vi.fn().mockImplementationOnce(() => first.promise).mockResolvedValue(success());
    const queue = new SnapshotRefreshQueue({ run, requestTimeoutMs: 60_000 });
    queue.setAvailable(true);
    await vi.advanceTimersByTimeAsync(20_000);
    expect(run).toHaveBeenCalledTimes(1);
    first.resolve(success());
    await flush();
    await vi.advanceTimersByTimeAsync(11_999);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(2);
    queue.stop();
  });

  it("lets a manual resume await the resumed refresh without queuing an extra one", async () => {
    const first = deferred<RefreshResult<string>>();
    const run = vi.fn(() => first.promise);
    const queue = new SnapshotRefreshQueue({ run, pollIntervalMs: null });
    const resumed = queue.setAvailable(true) ?? queue.request();
    first.resolve(success());
    await expect(resumed).resolves.toBe("snapshot");
    await flush();
    expect(run).toHaveBeenCalledTimes(1);
    expect(queue.setAvailable(true)).toBeUndefined();
    queue.stop();
  });

  it("backs off 503/504/network failures and events cannot bypass the deadline", async () => {
    const run = vi.fn()
      .mockResolvedValueOnce({ kind: "retry" })
      .mockRejectedValueOnce(new TypeError("network unavailable"))
      .mockResolvedValue({ kind: "retry" });
    const queue = new SnapshotRefreshQueue({ run, random: () => 0, pollIntervalMs: null });
    queue.setAvailable(true);
    await flush();
    for (const [index, delay] of [5_000, 10_000, 20_000, 30_000, 30_000].entries()) {
      for (let attempt = 0; attempt < 4; attempt += 1) void queue.request();
      await vi.advanceTimersByTimeAsync(delay - 1);
      expect(run).toHaveBeenCalledTimes(index + 1);
      await vi.advanceTimersByTimeAsync(1);
      expect(run).toHaveBeenCalledTimes(index + 2);
    }
    queue.stop();
  });

  it("adds bounded positive jitter and never exceeds 30 seconds of ordinary backoff", async () => {
    const run = vi.fn().mockResolvedValue({ kind: "retry" });
    const queue = new SnapshotRefreshQueue({ run, random: () => 1, pollIntervalMs: null });
    queue.setAvailable(true);
    await flush();
    for (const [index, delay] of [6_000, 12_000, 24_000, 30_000].entries()) {
      await vi.advanceTimersByTimeAsync(delay - 1);
      expect(run).toHaveBeenCalledTimes(index + 1);
      await vi.advanceTimersByTimeAsync(1);
      expect(run).toHaveBeenCalledTimes(index + 2);
    }
    queue.stop();
  });

  it("resets backoff only on success and resumes normal polling with one timer", async () => {
    const run = vi.fn()
      .mockResolvedValueOnce({ kind: "retry" })
      .mockResolvedValueOnce(success())
      .mockResolvedValue({ kind: "retry" });
    const queue = new SnapshotRefreshQueue({ run, random: () => 0 });
    queue.setAvailable(true);
    await flush();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(run).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(1);
    await vi.advanceTimersByTimeAsync(12_000);
    expect(run).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(run).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(4);
    queue.stop();
  });

  it("does not treat a cancelled or swallowed failure as a successful backoff reset", async () => {
    const run = vi.fn()
      .mockResolvedValueOnce({ kind: "retry" })
      .mockResolvedValueOnce({ kind: "cancelled" })
      .mockRejectedValue(new TypeError("network unavailable"));
    const queue = new SnapshotRefreshQueue({ run, random: () => 0 });
    queue.setAvailable(true);
    await flush();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(run).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(12_000);
    expect(run).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(9_999);
    expect(run).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(4);
    queue.stop();
  });

  it("honors Retry-After beyond 30 seconds even across pause/resume and repeated events", async () => {
    const run = vi.fn().mockResolvedValue({ kind: "retry", retryAfterMs: 75_000 });
    const queue = new SnapshotRefreshQueue({ run, random: () => 0 });
    queue.setAvailable(true);
    await flush();
    await vi.advanceTimersByTimeAsync(10_000);
    queue.setAvailable(false);
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(10_000);
    queue.setAvailable(true);
    for (let event = 0; event < 10; event += 1) void queue.request();
    await vi.advanceTimersByTimeAsync(54_999);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(2);
    queue.stop();
  });

  it("stops automatic and event retries permanently after revoked access", async () => {
    const first = deferred<RefreshResult<string>>();
    const run = vi.fn(() => first.promise);
    const queue = new SnapshotRefreshQueue({ run });
    queue.setAvailable(true);
    const queued = queue.request();
    first.resolve({ kind: "stopped" });
    await expect(queued).resolves.toBeNull();
    await vi.advanceTimersByTimeAsync(120_000);
    queue.setAvailable(false);
    queue.setAvailable(true);
    await expect(queue.request()).resolves.toBeNull();
    expect(run).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
    queue.stop();
  });

  it("pauses hidden/offline, invalidates stale data, and coalesces resume", async () => {
    const first = deferred<RefreshResult<string>>();
    const second = deferred<RefreshResult<string>>();
    const signals: AbortSignal[] = [];
    const run = vi.fn((signal: AbortSignal) => {
      signals.push(signal);
      return run.mock.calls.length === 1 ? first.promise : second.promise;
    });
    const queue = new SnapshotRefreshQueue({ run });
    queue.setAvailable(true);
    const stale = queue.request();
    queue.setAvailable(false);
    await expect(stale).resolves.toBeNull();
    expect(signals[0].aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(60_000);
    queue.setAvailable(true);
    queue.setAvailable(true);
    const resumed = queue.request();
    expect(run).toHaveBeenCalledTimes(1);
    first.resolve(success("private old child"));
    await flush();
    expect(run).toHaveBeenCalledTimes(2);
    second.resolve(success("current child"));
    await expect(resumed).resolves.toBe("current child");
    queue.stop();
  });

  it("invalidates identity changes while keeping the previous read in flight until it settles", async () => {
    const initial = deferred<RefreshResult<string>>();
    const run = vi.fn().mockImplementationOnce(() => initial.promise).mockResolvedValue(success("new child"));
    const queue = new SnapshotRefreshQueue({ run });
    queue.setAvailable(true);
    const oldChild = queue.request();
    queue.invalidate();
    const newChild = queue.request();
    await expect(oldChild).resolves.toBeNull();
    expect(run).toHaveBeenCalledTimes(1);
    initial.resolve(success("old child"));
    await expect(newChild).resolves.toBe("new child");
    expect(run).toHaveBeenCalledTimes(2);
    queue.stop();
  });

  it("survives Strict Mode stop/setup without two concurrent schedulers", async () => {
    const initial = deferred<RefreshResult<string>>();
    const run = vi.fn().mockImplementationOnce(() => initial.promise).mockResolvedValue(success());
    const queue = new SnapshotRefreshQueue({ run });
    queue.setAvailable(true);
    queue.stop();
    queue.setAvailable(true);
    expect(run).toHaveBeenCalledTimes(1);
    initial.resolve(success("discarded"));
    await flush();
    expect(run).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(1);
    queue.stop();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("aborts deadlines but does not release the guard when transport ignores cancellation", async () => {
    const first = deferred<RefreshResult<string>>();
    const signals: AbortSignal[] = [];
    const run = vi.fn((signal: AbortSignal) => {
      signals.push(signal);
      return run.mock.calls.length === 1 ? first.promise : Promise.resolve(success());
    });
    const queue = new SnapshotRefreshQueue({ run, requestTimeoutMs: 8_000, random: () => 0 });
    queue.setAvailable(true);
    const requested = queue.request();
    await vi.advanceTimersByTimeAsync(20_000);
    expect(signals[0].aborted).toBe(true);
    expect(run).toHaveBeenCalledTimes(1);
    first.resolve(success("late after timeout"));
    await flush();
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    await expect(requested).resolves.toBe("snapshot");
    expect(run).toHaveBeenCalledTimes(2);
    queue.stop();
  });
});
