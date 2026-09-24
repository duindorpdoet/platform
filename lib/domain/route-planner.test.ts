import { describe, expect, it } from "vitest";
import { proposePlan, type PlanningInput } from "./route-planner";

const base: PlanningInput = {
  parties: [{ id: "a", childCount: 3, startPreference: "early", paymentEligible: true }, { id: "b", childCount: 4, paymentEligible: true }, { id: "c", childCount: 2, paymentEligible: true }],
  starts: [
    { id: "start-a", startPointId: "point-a", startsAt: "2026-10-31T17:30:00+01:00", maxGroups: 2, maxChildren: 20 },
    { id: "start-b", startPointId: "point-b", startsAt: "2026-10-31T18:30:00+01:00", maxGroups: 2, maxChildren: 20 },
  ],
  targetGroupSize: 7,
  maxGroupSize: 10,
  globalOrdinaryStopAt: "2026-10-31T20:30:00+01:00",
  finaleOpensAt: "2026-10-31T19:00:00+01:00",
  finaleLastArrivalAt: "2026-10-31T21:30:00+01:00",
  finaleClosesAt: "2026-10-31T22:00:00+01:00",
  finaleShowSeconds: 360,
  finaleTurnoverSeconds: 0,
  finalePlanningTransferSeconds: 600,
  finaleMaxGroups: 2,
  finaleMaxChildren: 20,
  earlyPreferenceLatestAt: "2026-10-31T18:00:00+01:00",
  laterPreferenceEarliestAt: "2026-10-31T18:15:00+01:00",
};

describe("group and finale planner", () => {
  it("rejects a configured size above the absolute twenty-child maximum", () => {
    expect(proposePlan({ ...base, maxGroupSize: 21 }).conflicts).toContainEqual(expect.objectContaining({ code: "INVALID_GROUP_LIMIT" }));
  });

  it("keeps the twenty-child ceiling even with a legacy capacity override", () => {
    const result = proposePlan({ ...base, maxGroupSize: 20, parties: [
      { id: "large", childCount: 21, togetherOverride: true, paymentEligible: true },
    ] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "TOGETHER_PARTY_TOO_LARGE" }));
  });

  it("is deterministic for reordered input", () => {
    expect(proposePlan(base)).toEqual(proposePlan({ ...base, parties: [...base.parties].reverse(), starts: [...base.starts].reverse() }));
  });

  it("keeps linked households together and chooses their soft preference", () => {
    const result = proposePlan({ ...base, parties: [
      { id: "a", childCount: 3, togetherKey: "x", startPreference: "early", paymentEligible: true },
      { id: "b", childCount: 4, togetherKey: "x", startPreference: "early", paymentEligible: true },
    ] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ partyIds: ["a", "b"], startId: "start-a", preferenceMatch: "good" });
  });

  it("reports conflicting preferences inside one linked party", () => {
    const result = proposePlan({ ...base, parties: [
      { id: "a", childCount: 2, togetherKey: "same", startPreference: "early" },
      { id: "b", childCount: 2, togetherKey: "same", startPreference: "later" },
    ] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "START_PREFERENCE_CONFLICT" }));
  });

  it("uses the earliest personal or global stop without a fixed visit count", () => {
    const result = proposePlan({ ...base, parties: [{ id: "a", childCount: 3, requestedStopAt: "2026-10-31T19:30:00+01:00", paymentEligible: true }] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0].effectiveStopAt).toBe("2026-10-31T18:30:00.000Z");
    expect(result.groups[0]).not.toHaveProperty("portalIds");
  });

  it("blocks a finale peak that cannot be processed", () => {
    const result = proposePlan({
      ...base,
      targetGroupSize: 1,
      maxGroupSize: 1,
      parties: Array.from({ length: 4 }, (_, index) => ({ id: `p-${index}`, childCount: 1, paymentEligible: true })),
      starts: [{ ...base.starts[0], maxGroups: 10, maxChildren: 20 }],
      finaleLastArrivalAt: "2026-10-31T20:41:00+01:00",
      finaleMaxGroups: 1,
    });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "FINALE_CAPACITY_EXCEEDED" }));
  });

  it("retains unpaid applications in a concept estimate but marks them", () => {
    const result = proposePlan({ ...base, parties: [{ id: "unpaid", childCount: 2, paymentEligible: false }] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0].warnings).toContain("PAYMENT_NOT_CONFIRMED");
  });

  it("spreads dozens of groups over fifteen physical start points at 17:30 and 18:30", () => {
    const starts = Array.from({ length: 15 }, (_, index) => ({
      id: `start-${String(index + 1).padStart(2, "0")}`,
      startPointId: `point-${String(index + 1).padStart(2, "0")}`,
      startsAt: index % 2 === 0 ? "2026-10-31T17:30:00+01:00" : "2026-10-31T18:30:00+01:00",
      maxGroups: 5,
      maxChildren: 5,
    }));
    const result = proposePlan({
      ...base,
      targetGroupSize: 1,
      maxGroupSize: 1,
      parties: Array.from({ length: 75 }, (_, index) => ({ id: `party-${String(index + 1).padStart(2, "0")}`, childCount: 1, paymentEligible: true })),
      starts,
      finaleShowSeconds: 60,
      finaleMaxGroups: 10,
      finaleMaxChildren: 100,
    });

    expect(result.conflicts).toEqual([]);
    expect(result.groups).toHaveLength(75);
    expect(new Set(result.groups.map((group) => group.startId))).toEqual(new Set(starts.map((start) => start.id)));
    expect(result.groups.every((group) => Date.parse(group.expectedFinaleArrivalAt) <= Date.parse(base.finaleLastArrivalAt))).toBe(true);
  });
});
