import { describe, expect, it } from "vitest";
import { eveningCandidateCost, proposePlan, type PlanningInput, type PlanningParty } from "./route-planner";
const at = (time: string) => `2026-10-31T${time.length === 5 ? `${time}:00` : time}+01:00`;
const iso = (time: string) => new Date(at(time)).toISOString();
const party = (id: string, end = "21:00", start = "18:30"): PlanningParty => ({ id, fixedGroupId: id, childCount: 3, desiredEndAt: at(end), preferredStartAt: at(start) });
const base: PlanningInput = {
  parties: [party("synthetic-late")], starts: ["18:30", "18:40"].map(time => ({ id: time, startsAt: at(time), startPointId: "synthetic-start", maxGroups: 1, maxChildren: 20 })),
  targetGroupSize: 15, maxGroupSize: 20, globalOrdinaryStopAt: at("20:30"),
  finaleOpensAt: at("19:00"), finaleLastArrivalAt: at("21:25"), finaleClosesAt: at("21:40"),
  finaleShowSeconds: 600, finaleTurnoverSeconds: 120, finalePlanningTransferSeconds: 900,
  finaleMaxGroups: 1, finaleMaxChildren: 20, maxGroupOverrunSeconds: 1800,
};
const cost = (endDeviationMinutes: number, routeLostMinutes = 0, startDeviationMinutes = 0) => eveningCandidateCost({ endDeviationMinutes, routeLostMinutes, startDeviationMinutes });

describe("completion target and bounded overrun", () => {
  it("records the score tradeoffs explicitly", () => {
    expect(cost(-5)).toBeLessThan(cost(10));
    expect(cost(5)).toBeLessThan(cost(-72, 63));
    expect(cost(-5)).toBeLessThan(cost(5));
    expect(cost(0, 60, 0)).toBeGreaterThan(cost(0, 0, 10));
  });
  it("recovers the synthetic 63-minute loss using a genuinely available late finale", () => {
    const occupied = ["19:54", "20:06", "20:18", "20:30", "20:42"].map((time, i) => ({ id: `reserved-${i}`, groupId: `other-${i}`, startId: `other-slot-${i}`, startPointId: "other-start", startsAt: at("17:00"), childCount: 3, expectedFinaleArrivalAt: at(time) }));
    const input = { ...base, starts: [base.starts[1]], existingSchedules: occupied };
    const result = proposePlan(input);
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ effectiveStopAt: iso("20:30"), expectedFinaleArrivalAt: iso("20:54"), expectedCompletionAt: iso("21:04"), endDeviationMinutes: 4 });
    expect(result.groups[0].warnings).toContain("GROUP_END_OVERRUN");
    expect(result.groups[0].warnings).not.toContain("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
    // The strict historical policy produces exactly the reported synthetic loss.
    expect(proposePlan({ ...input, maxGroupOverrunSeconds: 0 }).groups[0]).toMatchObject({ effectiveStopAt: iso("19:27"), expectedFinaleArrivalAt: iso("19:42") });
  });
  it("does not use allowance or invent waiting when an adequate earlier completion fits", () => {
    const result = proposePlan(base);
    expect(result.groups[0]).toMatchObject({ expectedCompletionAt: iso("20:55"), effectiveStopAt: iso("20:30"), endDeviationMinutes: -5 });
    expect(result.groups[0].warnings).not.toContain("GROUP_END_OVERRUN");
  });
  it.each([925, 1114, 1200])("preserves a %s-second final transfer when reserving a real final slot", transferSeconds => {
    const result = proposePlan({ ...base, finalePlanningTransferSeconds: transferSeconds });
    expect(result.conflicts).toEqual([]);
    const group = result.groups[0];
    expect(group.effectiveStopAt).toBe(iso("20:30"));
    expect(Date.parse(group.expectedFinaleArrivalAt) - Date.parse(group.effectiveStopAt)).toBe(transferSeconds * 1_000);
    expect(Date.parse(group.expectedCompletionAt) - Date.parse(group.expectedFinaleArrivalAt)).toBe(base.finaleShowSeconds * 1_000);
    expect(Date.parse(group.physicalFinaleEndsAt) - Date.parse(group.expectedFinaleArrivalAt)).toBe((base.finaleShowSeconds + base.finaleTurnoverSeconds) * 1_000);
  });
  it("cannot reserve a twenty-minute final transfer in the five minutes after departure", () => {
    const result = proposePlan({ ...base, parties: [party("late", "21:00", "20:50")],
      starts: [{ ...base.starts[0], startsAt: at("20:50") }], globalOrdinaryStopAt: at("20:55"),
      finalePlanningTransferSeconds: 1200, finaleLastArrivalAt: at("20:55"), finaleClosesAt: at("21:07") });
    expect(result.groups).toEqual([]);
    expect(result.conflicts.some(conflict => conflict.code === "FINALE_WINDOW_CONFLICT")).toBe(true);
  });
  it.each(["21:00", "20:30"])("keeps the deadline per group with desired %s", end => {
    const target = Date.parse(at(end));
    const arrival = new Date(target + 20 * 60_000).toISOString();
    const input = { ...base, parties: [party("boundary", end)], globalOrdinaryStopAt: new Date(target + 5 * 60_000).toISOString(), finaleOpensAt: arrival, finaleLastArrivalAt: arrival, finaleClosesAt: new Date(target + 32 * 60_000).toISOString() };
    const valid = proposePlan(input);
    expect(valid.conflicts).toEqual([]);
    expect(Date.parse(valid.groups[0].expectedCompletionAt)).toBe(target + 30 * 60_000);
    expect(proposePlan({ ...input, finaleOpensAt: new Date(Date.parse(arrival) + 1000).toISOString() }).groups).toEqual([]);
    expect(proposePlan({ ...input, finaleShowSeconds: 601 }).groups).toEqual([]);
    expect(proposePlan({ ...input, finaleTurnoverSeconds: 121 }).groups).toEqual([]);
    expect(proposePlan({ ...input, finaleTurnoverSeconds: 121, finaleClosesAt: new Date(target + 33 * 60_000).toISOString() }).conflicts).toEqual([]);
  });
  it("does not permit arrival at 21:25 for a ten-minute show ending by 21:30", () => {
    expect(proposePlan({ ...base, finaleOpensAt: at("21:25") }).groups).toEqual([]);
  });
  it("allocates earlier-end and later-end groups together independently of row order", () => {
    const input = { ...base, parties: [party("later"), party("earlier", "20:30")], globalOrdinaryStopAt: at("20:45") };
    const result = proposePlan(input);
    expect(result.conflicts).toEqual([]);
    expect(result.groups.find(g => g.key === "earlier")?.expectedCompletionAt).toBe(iso("20:30"));
    expect(result.groups.find(g => g.key === "later")?.expectedCompletionAt).toBe(iso("21:00"));
    expect(result.groups.every(g => g.ordinaryRouteLostMinutes <= 10)).toBe(true);
    expect(proposePlan({ ...input, parties: [...input.parties].reverse(), starts: [...input.starts].reverse() })).toEqual(result);
  });
  it("prefers a nearby departure giving more real route time over a token exact start", () => {
    const input = { ...base, starts: ["18:20", "18:30"].map(time => ({ ...base.starts[0], id: time, startsAt: at(time) })), finaleLastArrivalAt: at("19:00"), finaleClosesAt: at("19:12") };
    const result = proposePlan(input);
    expect(result.groups[0].startId).toBe("18:20");
    expect(result.groups[0].warnings).toContain("GROUP_END_SIGNIFICANTLY_EARLY");
  });
  it("honors ordinary closure during finale overrun and independent physical windows", () => {
    const result = proposePlan({ ...base, finaleWindows: [{ opensAt: at("21:05"), closesAt: at("21:20"), maxGroups: 1, maxChildren: 20, maxTotalChildren: 20 }] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0].effectiveStopAt).toBe(iso("20:30"));
    expect(result.groups[0].expectedCompletionAt).toBe(iso("21:15"));
    expect(proposePlan({ ...base, finaleWindows: [{ opensAt: at("21:05"), closesAt: at("21:16"), maxGroups: 1, maxChildren: 20, maxTotalChildren: 20 }] }).groups).toEqual([]);
    expect(proposePlan({ ...base, finaleWindows: [] }).conflicts).not.toEqual([]);
  });
  it("names the actual deadline, physical window or child capacity bottleneck", () => {
    const late = proposePlan({ ...base, parties: [party("early-target", "18:20", "17:00")] });
    expect(late.conflicts[0]).toMatchObject({ code: "DESIRED_END_UNREACHABLE" });
    expect(late.conflicts[0].message).toContain("50 minuten");
    expect(late.conflicts[0].message).toContain("18:50");
    const short = proposePlan({ ...base, finaleWindows: [{ opensAt: at("21:05"), closesAt: at("21:16"), maxGroups: 1, maxChildren: 20, maxTotalChildren: 20 }] });
    expect(short.conflicts[0]).toMatchObject({ code: "FINALE_WINDOW_CONFLICT" });
    expect(short.conflicts[0].message).toContain("10 minuten plus 2 minuten");
    const capacity = proposePlan({ ...base, finaleMaxChildren: 2 });
    expect(capacity.conflicts[0]).toMatchObject({ code: "FINALE_CAPACITY_EXCEEDED" });
    expect(capacity.conflicts[0].message).toContain("3 kinderen");
    expect(capacity.conflicts[0].message).toContain("maximaal 2");
  });

});
