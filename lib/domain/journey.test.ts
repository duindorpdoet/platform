import { describe, expect, it } from "vitest";
import { canChangeParticipant, evaluateStopCompletion } from "./journey";

describe("stop completion", () => {
  it.each([1, 5, 7, 10])("handles a dynamic group of %i children", (size) => {
    const statuses = Array.from({ length: size }, () => ({ status: "visited" as const, required: true }));
    expect(evaluateStopCompletion(statuses, true, false)).toEqual({ allowed: true, outcome: "visited" });
  });

  it("requires every required participant to be resolved", () => {
    expect(evaluateStopCompletion([{ status: "pending", required: true }], true, false)).toEqual({ allowed: false, code: "PENDING_PARTICIPANTS" });
  });

  it("requires scan evidence for a visited or mixed stop", () => {
    expect(evaluateStopCompletion([{ status: "visited", required: true }], false, false)).toEqual({ allowed: false, code: "SCAN_REQUIRED" });
  });

  it("requires explicit confirmation when everybody skips", () => {
    const statuses = [{ status: "skipped" as const, required: true }];
    expect(evaluateStopCompletion(statuses, false, false)).toEqual({ allowed: false, code: "ALL_SKIP_CONFIRMATION_REQUIRED" });
    expect(evaluateStopCompletion(statuses, false, true)).toEqual({ allowed: true, outcome: "all_skipped" });
  });

  it("does not let a parent mark another child or record a visit", () => {
    expect(canChangeParticipant("parent", false, "pending", "skipped")).toBe(false);
    expect(canChangeParticipant("parent", true, "pending", "visited")).toBe(false);
    expect(canChangeParticipant("parent", true, "pending", "skipped")).toBe(true);
  });
});
