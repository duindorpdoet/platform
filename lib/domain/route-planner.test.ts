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

  it("rejects a together bundle that cannot fit without silently splitting it", () => {
    const result = proposePlan({
      ...base,
      parties: [{ id: "a", childCount: 6, togetherKey: "same" }, { id: "b", childCount: 5, togetherKey: "same" }],
    });

    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "TOGETHER_PARTY_TOO_LARGE" }));
  });

  it("counts overlapping visit intervals instead of only identical timestamps", () => {
    const result = proposePlan({
      parties: [
        { id: "a", childCount: 1, requestedStartId: "start-a" },
        { id: "b", childCount: 1, requestedStartId: "start-b" },
      ],
      starts: [
        { id: "start-a", startsAt: "2026-10-31T18:30:00+01:00", maxGroups: 1, maxChildren: 10 },
        { id: "start-b", startsAt: "2026-10-31T18:31:00+01:00", maxGroups: 1, maxChildren: 10 },
      ],
      portals: [{ id: "portal", worldId: "world", opensAt: "2026-10-31T18:00:00+01:00", closesAt: "2026-10-31T22:00:00+01:00", visitMinutes: 5, maxConcurrentGroups: 1, maxChildren: 10 }],
      targetGroupSize: 1,
      maxGroupSize: 1,
      stopsPerGroup: 1,
    });

    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "PORTAL_CAPACITY_EXCEEDED" }));
  });

  it("respects each portal's total child capacity across the complete proposal", () => {
    const result = proposePlan({
      ...base,
      targetGroupSize: 5,
      maxGroupSize: 7,
      portals: base.portals.map((portal) => ({ ...portal, maxTotalChildren: 8 })),
    });

    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "PORTAL_CAPACITY_EXCEEDED" }));
  });

  it("supports a non-hardcoded number of portals and stops", () => {
    const result = proposePlan({ ...base, portals: base.portals.slice(0, 4), stopsPerGroup: 4 });
    expect(result.conflicts).toEqual([]);
    expect(result.groups.every((group) => group.portalIds.length === 4)).toBe(true);
  });

  it("surfaces incompatible start preferences inside one together bundle", () => {
    const result = proposePlan({
      ...base,
      starts: [...base.starts, { ...base.starts[0], id: "start-b" }],
      parties: [
        { id: "a", childCount: 2, togetherKey: "same", requestedStartId: "start-a" },
        { id: "b", childCount: 2, togetherKey: "same", requestedStartId: "start-b" },
      ],
    });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "START_PREFERENCE_CONFLICT" }));
  });
});
