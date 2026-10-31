import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { demoSnapshot, newDemoSession } from "./demo";
import type { BookSnapshot } from "./model";
import { readBookSnapshot, retryAfterMs, validateBookSnapshot } from "./snapshot-response";

vi.mock("server-only", () => ({}));

const now = new Date("2026-10-31T16:00:00Z");
let expected: BookSnapshot;
let fetchMock: ReturnType<typeof vi.fn<typeof fetch>>;

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(now);
  expected = {
    ...demoSnapshot(newDemoSession(Date.now())),
    childId: "child-a",
    eventId: "event-a",
    demo: false,
  };
  fetchMock = vi.fn<typeof fetch>();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

const read = () => readBookSnapshot(new AbortController().signal, expected);

describe("Poortenboek snapshot response validation", () => {
  it("accepts a valid snapshot for the same identity and retains optional projections", async () => {
    const confirmed = {
      ...expected,
      firstName: "Updated name",
      reading: { readChapters: [1], stories: [] },
      worldCollection: [],
      worldCoverage: { status: "active", policyVersion: 2, missingWorlds: [] },
    };
    fetchMock.mockResolvedValue(Response.json(confirmed));
    const controller = new AbortController();
    await expect(readBookSnapshot(controller.signal, expected)).resolves.toEqual({
      kind: "success",
      value: confirmed,
    });
    expect(fetchMock).toHaveBeenCalledExactlyOnceWith("/api/poortenboek/snapshot", {
      cache: "no-store",
      signal: controller.signal,
    });
  });

  it("accepts the existing demo snapshot without inventing child or event ids", () => {
    const demo = demoSnapshot(newDemoSession(Date.now()));
    expect(validateBookSnapshot(demo, demo)).toEqual({ kind: "success", value: demo });
  });

  it.each([
    "2026-11-01T04:00:00+00:00",
    "2026-11-01T04:00:00.123456+00:00",
    "2026-11-01T05:00:00.123456+01:00",
  ])("accepts the PostgreSQL offset timestamp %s for the same session", async (expiresAt) => {
    expected = { ...expected, expiresAt };
    fetchMock.mockResolvedValue(Response.json(expected));
    await expect(read()).resolves.toEqual({ kind: "success", value: expected });
  });

  it("accepts the installed SQL projection shape with live progress, nullable world and publication metadata", async () => {
    const prepared = demoSnapshot({ ...newDemoSession(Date.now()), phase: "prepared" });
    const start = {
      name: "Startlocatie volgt",
      startsAt: "2026-10-31T18:00:00+00:00",
      revision: 3,
      publishedAt: "2026-10-30T12:00:00.123456+00:00",
      addressReleaseAt: "2026-10-31T17:00:00+00:00",
      addressReleased: false,
      address: null,
      coordinate: null,
    };
    expected = {
      ...expected,
      expiresAt: "2026-11-01T04:00:00.123456+00:00",
      eventPhase: "live",
      updatedAt: "2026-10-31T16:00:01.123456+00:00",
      election: { ...expected.election, deadline: "2026-10-30T17:00:00+00:00", open: false },
      start,
      worlds: expected.worlds.map((world) => ({ ...world, unlocked: true })),
      unlocks: [{ kind: "chapter", world: null, earnedAt: "2026-10-31T16:00:00.123456+00:00" }],
      journey: {
        ...prepared.journey,
        seals: prepared.journey.seals.map((seal) => ({
          ...seal,
          stopId: "stop-a",
          earnedAt: "2026-10-31T16:00:00.123456+00:00",
        })),
      },
    };
    fetchMock.mockResolvedValue(Response.json(expected));
    await expect(read()).resolves.toEqual({ kind: "success", value: expected });
  });

  it.each([503, 504])("returns retry for HTTP %s without accepting a valid-looking body", async (status) => {
    fetchMock.mockResolvedValue(Response.json(expected, { status }));
    await expect(read()).resolves.toEqual({ kind: "retry", retryAfterMs: undefined });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("propagates a network failure so the queue cannot mistake it for success", async () => {
    const error = new TypeError("network unavailable");
    fetchMock.mockRejectedValue(error);
    await expect(read()).rejects.toBe(error);
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("propagates malformed JSON without reporting success", async () => {
    fetchMock.mockResolvedValue(new Response("{broken-json"));
    await expect(read()).rejects.toBeInstanceOf(SyntaxError);
  });

  it.each([
    ["missing snapshot", null],
    ["error object", { error: "temporary failure" }],
    ["missing required identity", { ...demoSnapshot(newDemoSession(now.getTime())), identity: undefined }],
    ["short checklist", { ...demoSnapshot(newDemoSession(now.getTime())), checklist: [true] }],
    ["invalid expiry", { ...demoSnapshot(newDemoSession(now.getTime())), expiresAt: "unknown" }],
    ["invalid nested election", { ...demoSnapshot(newDemoSession(now.getTime())), election: { phase: "finished" } }],
  ])("returns retry for an invalid schema: %s", async (_name, value) => {
    fetchMock.mockResolvedValue(Response.json(value));
    await expect(read()).resolves.toEqual({ kind: "retry" });
  });

  it.each([
    ["child", { childId: "child-b" }],
    ["missing child", { childId: undefined }],
    ["event", { eventId: "event-b" }],
    ["missing event", { eventId: undefined }],
    ["demo", { demo: true }],
    ["event date", { eventDate: "2027-10-31" }],
    ["session expiry", { expiresAt: "2026-11-02T16:00:00Z" }],
  ])("stops when the %s identity boundary changes", async (_name, change) => {
    fetchMock.mockResolvedValue(Response.json({ ...expected, ...change }));
    await expect(read()).resolves.toEqual({ kind: "stopped" });
  });

  it("stops when the same session has expired", async () => {
    vi.setSystemTime(Date.parse(expected.expiresAt));
    fetchMock.mockResolvedValue(Response.json(expected));
    await expect(read()).resolves.toEqual({ kind: "stopped" });
  });

  it.each([401, 403])("stops immediately on HTTP %s without reading the body", async (status) => {
    const json = vi.fn().mockRejectedValue(new Error("body must not be read"));
    fetchMock.mockResolvedValue({ status, ok: false, json } as unknown as Response);
    await expect(read()).resolves.toEqual({ kind: "stopped" });
    expect(json).not.toHaveBeenCalled();
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("remains pending through the complete response body phase", async () => {
    let releaseBody!: (value: unknown) => void;
    const body = new Promise<unknown>((resolve) => { releaseBody = resolve; });
    const json = vi.fn(() => body);
    fetchMock.mockResolvedValue({ status: 200, ok: true, json } as unknown as Response);
    let settled = false;
    const pending = read().finally(() => { settled = true; });
    await vi.advanceTimersByTimeAsync(10_000);
    expect(json).toHaveBeenCalledOnce();
    expect(settled).toBe(false);
    expect(fetchMock).toHaveBeenCalledOnce();
    releaseBody(expected);
    await expect(pending).resolves.toEqual({ kind: "success", value: expected });
    expect(settled).toBe(true);
  });

  it("does not report success if reading the response body fails", async () => {
    const error = new TypeError("response body interrupted");
    fetchMock.mockResolvedValue({
      status: 200, ok: true, json: () => Promise.reject(error),
    } as unknown as Response);
    await expect(read()).rejects.toBe(error);
  });
});

describe("Retry-After", () => {
  it.each([
    ["45", 45_000],
    [" 60 ", 60_000],
    ["0", 0],
    ["Sat, 31 Oct 2026 16:02:00 GMT", 120_000],
    ["Sat, 31 Oct 2026 15:59:00 GMT", 0],
    [null, undefined],
    ["", undefined],
    ["not-a-date", undefined],
    ["Infinity", undefined],
  ])("parses %s as %s ms", (value, delay) => {
    expect(retryAfterMs(value, now.getTime())).toBe(delay);
  });

  it.each([
    ["90", 90_000],
    ["Sat, 31 Oct 2026 16:01:00 GMT", 60_000],
    ["not-a-date", undefined],
    [null, undefined],
  ])("preserves HTTP 429 retry timing for %s without applying the normal 30-second cap", async (header, delay) => {
    const headers = header === null ? undefined : { "Retry-After": header };
    fetchMock.mockResolvedValue(new Response(null, { status: 429, headers }));
    await expect(read()).resolves.toEqual({ kind: "retry", retryAfterMs: delay });
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});
