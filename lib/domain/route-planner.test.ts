import { describe, expect, it } from "vitest";
import { proposePlan, type PlanningInput } from "./route-planner";

const base: PlanningInput = {
  parties: [{ id: "a", childCount: 3 }, { id: "b", childCount: 4 }, { id: "c", childCount: 2 }],
  starts: [{ id: "start-a", startsAt: "2026-10-31T18:30:00+01:00", maxGroups: 3, maxChildren: 20 }],
  portals: Array.from({ length: 6 }, (_, index) => ({ id: `portal-${index}`, worldId: `world-${index}`, opensAt: "2026-10-31T18:00:00+01:00", closesAt: "2026-10-31T22:00:00+01:00", visitMinutes: 5, maxConcurrentGroups: 2, maxChildren: 12 })),
  targetGroupSize: 7,
  maxGroupSize: 10,
  stopsPerGroup: 6,
};

describe("deterministic planner", () => {
  it("returns identical output for reordered input", () => {
    expect(proposePlan(base)).toEqual(proposePlan({ ...base, parties: [...base.parties].reverse(), portals: [...base.portals].reverse() }));
  });

  it("keeps together parties intact", () => {
    const result = proposePlan({ ...base, parties: [{ id: "a", childCount: 3, togetherKey: "x" }, { id: "b", childCount: 4, togetherKey: "x" }] });
    expect(result.groups).toHaveLength(1);
    expect(result.groups[0].partyIds).toEqual(["a", "b"]);
  });

  it("reports capacity conflicts instead of overbooking", () => {
    const result = proposePlan({ ...base, starts: [{ ...base.starts[0], maxGroups: 1, maxChildren: 5 }] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts.some((conflict) => conflict.code === "START_CAPACITY_EXCEEDED")).toBe(true);
  });
});
