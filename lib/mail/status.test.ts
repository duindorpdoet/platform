import { describe, expect, it } from "vitest";
import { nextRetry, statusForProviderEvent, summarizeMailWorkerResults } from "./status";

describe("mail delivery state", () => {
  it("does not confuse HTTP acceptance with delivery", () => expect(statusForProviderEvent("accepted", "processed")).toBe("accepted"));
  it("makes delivered and failed terminal", () => {
    expect(statusForProviderEvent("delivered", "deferred")).toBe("delivered");
    expect(statusForProviderEvent("failed", "delivered")).toBe("failed");
  });
  it("backs off retries with a one-hour ceiling", () => expect(nextRetry(20, 0).getTime()).toBe(3_600_000));
  it("reports handled batch outcomes without treating a deferred message as a worker outage", () => {
    expect(summarizeMailWorkerResults([
      { status: "accepted" },
      { status: "deferred" },
      { status: "failed" },
    ])).toEqual({ accepted: 1, deferred: 1, failed: 1 });
  });
});
