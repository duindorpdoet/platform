import { describe, expect, it } from "vitest";
import { proposePlan, type PlanningInput, type PlanningParty, type PlanningStart } from "./route-planner";
const at = (time: string) => `2026-10-31T${time}:00+01:00`;
const iso = (time: string) => new Date(at(time)).toISOString();
const slot = (time: string, point = "poort-1", id = `${point}-${time}`): PlanningStart => ({ id, startPointId: point, startsAt: at(time), maxGroups: 12, maxChildren: 60 });
const family = (id: string, end = "21:00", start = "17:00", size = 2): PlanningParty => ({ id: `registration-${id}`, fixedGroupId: id, childCount: size, preferredStartAt: at(start), desiredEndAt: at(end) });
const base: PlanningInput = {
  parties: [], starts: [slot("17:00"), slot("17:10"), slot("17:20")], targetGroupSize: 50, maxGroupSize: 50,
  globalOrdinaryStopAt: at("20:30"), finaleOpensAt: at("19:00"), finaleLastArrivalAt: at("21:30"), finaleClosesAt: at("22:00"),
  finaleShowSeconds: 360, finaleTurnoverSeconds: 120, finalePlanningTransferSeconds: 600, finaleMaxGroups: 20, finaleMaxChildren: 200,
};
function departures(input: PlanningInput) {
  const result = proposePlan(input);
  return { result, byParty: Object.fromEntries(result.groups.flatMap(group => group.partyIds.map(id => [id, input.starts.find(start => start.id === group.startId)!.startsAt]))) };
}

describe("one physical departure per gate per ten minutes", () => {
  it.each([false, true])("gives B 17:00 and A 17:10 independently of IDs, children and row order (reverse=%s)", reverse => {
    for (const [aId, bId, aChildren, bChildren] of [["A", "B", 20, 1], ["z-A", "a-B", 1, 20]] as const) {
      const a = family(aId, "21:00", "17:00", aChildren);
      const b = family(bId, "20:00", "17:00", bChildren);
      const input = { ...base, parties: reverse ? [b, a] : [a, b], starts: reverse ? [...base.starts].reverse() : base.starts };
      const { result, byParty } = departures(input);
      expect(result.conflicts).toEqual([]);
      expect(byParty[a.id]).toBe(at("17:10"));
      expect(byParty[b.id]).toBe(at("17:00"));
      expect(result.groups.find(group => group.key === bId)).toMatchObject({ dominantStartAt: iso("17:00"), dominantEndAt: iso("20:00") });
    }
  });
  it("uses 17:00, 17:10 and 17:20 instead of gathering capacity as simultaneous departures", () => {
    const input = { ...base, parties: [family("c"), family("a"), family("b")] };
    const { result, byParty } = departures(input);
    expect(result.conflicts).toEqual([]);
    expect(Object.values(byParty)).toEqual([at("17:00"), at("17:10"), at("17:20")]);
    expect(proposePlan({ ...input, parties: [...input.parties].reverse(), starts: [...input.starts].reverse() })).toEqual(result);
  });
  it("allows simultaneous departures at different physical gates", () => {
    const input = { ...base, starts: [slot("17:00", "poort-1"), slot("17:00", "poort-2")], parties: [family("a"), family("b")] };
    const { result, byParty } = departures(input);
    expect(result.conflicts).toEqual([]);
    expect(Object.values(byParty)).toEqual([at("17:00"), at("17:00")]);
    expect(new Set(result.groups.map(group => group.startId)).size).toBe(2);
  });
  it("prefers a later equidistant slot and does not let a later preference consume early departures", () => {
    const later = family("later-with-early-end", "20:00", "17:10");
    const earlier = family("earlier-with-later-end", "21:00", "17:00");
    const { result, byParty } = departures({ ...base, starts: [slot("17:00"), slot("17:20")], parties: [later, earlier] });
    expect(result.conflicts).toEqual([]);
    expect(byParty[earlier.id]).toBe(at("17:00"));
    expect(byParty[later.id]).toBe(at("17:20"));
    const tie = departures({ ...base, starts: [slot("17:00"), slot("17:20")], parties: [later] });
    expect(tie.byParty[later.id]).toBe(at("17:20"));
  });
  it("does not create departure capacity through two slot IDs for one physical gate and instant", () => {
    const input = { ...base, starts: [slot("17:00", "poort-1", "alias-a"), slot("17:00", "poort-1", "alias-b"), slot("17:10")], parties: [family("a"), family("b")] };
    const { result, byParty } = departures(input);
    expect(result.conflicts).toEqual([]);
    expect(Object.values(byParty)).toEqual([at("17:00"), at("17:10")]);
  });
  it("reserves an existing published physical departure even when its slot ID is hidden or aliased", () => {
    const saved = { id: "published", groupId: "locked", startId: "hidden-old-slot", startPointId: "poort-1", startsAt: at("17:00"), childCount: 8, expectedFinaleArrivalAt: at("20:40"), partyIds: ["already-assigned"] };
    const input = { ...base, starts: [slot("17:00", "poort-1", "new-alias"), slot("17:10")], parties: [family("new"), { id: "already-assigned", childCount: 8 }], existingSchedules: [saved, { ...saved }] };
    const { result, byParty } = departures(input);
    expect(result.conflicts).toEqual([]);
    expect(result.groups).toHaveLength(1);
    expect(byParty["registration-new"]).toBe(at("17:10"));
    expect(result.groups[0].partyIds).toEqual(["registration-new"]);
    expect(saved.startsAt).toBe(at("17:00"));
  });
  it("refuses to move a reserved fixed group even when its household IDs are absent", () => {
    const result = proposePlan({ ...base, parties: [family("locked")], existingSchedules: [{ id: "published", groupId: "locked", startId: base.starts[0].id, childCount: 2, expectedFinaleArrivalAt: at("20:40") }] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "GROUP_ALREADY_SCHEDULED", subjectId: "locked" }));
  });
  it("reports insufficient departures and never uses an off-grid or unavailable start", () => {
    const result = proposePlan({ ...base, starts: [slot("17:00"), slot("17:05"), { ...slot("17:10"), portalOpensAt: at("17:20") }], parties: [family("a"), family("b")] });
    expect(result.groups).toHaveLength(1);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "START_CAPACITY_EXCEEDED" }));
  });
  it("keeps start child capacity independent from the one-group departure limit", () => {
    const result = proposePlan({ ...base, starts: [{ ...slot("17:00"), maxChildren: 1 }, slot("17:10")], parties: [family("a")] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0].startId).toBe(slot("17:10").id);
  });
});

describe("dominant start and completion preferences remain separate from ordinary stops", () => {
  it("uses one vote per original household inside a fixed together group for both start and end", () => {
    const parties: PlanningParty[] = [
      { ...family("majority-1", "20:00", "17:00", 1), fixedGroupId: "fixed-together", togetherKey: "block" },
      { ...family("majority-2", "20:00", "17:00", 1), fixedGroupId: "fixed-together", togetherKey: "block" },
      { ...family("minority", "18:00", "18:00", 20), fixedGroupId: "fixed-together", togetherKey: "block" },
      { id: "neutral", fixedGroupId: "fixed-together", childCount: 2 },
    ];
    const result = proposePlan({ ...base, parties });
    expect(result.conflicts).toEqual([]);
    expect(result.groups).toHaveLength(1);
    expect(result.groups[0]).toMatchObject({ key: "fixed-together", dominantStartAt: iso("17:00"), dominantEndAt: iso("20:00"), startId: slot("17:00").id, effectiveStopAt: iso("19:44"), expectedFinaleArrivalAt: iso("19:54") });
    expect(proposePlan({ ...base, parties: [...parties].reverse() })).toEqual(result);
  });
  it("does not let a minority end copied into the legacy ordinary-stop column veto the majority", () => {
    const parties: PlanningParty[] = [
      { ...family("majority-1", "20:00", "17:00"), fixedGroupId: "fixed", requestedStopAt: at("20:00") },
      { ...family("majority-2", "20:00", "17:00"), fixedGroupId: "fixed", requestedStopAt: at("20:00") },
      { ...family("minority", "16:30", "18:00"), fixedGroupId: "fixed", requestedStopAt: at("16:30") },
    ];
    const result = proposePlan({ ...base, parties });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ startId: slot("17:00").id, dominantStartAt: iso("17:00"), dominantEndAt: iso("20:00"), effectiveStopAt: iso("19:44") });
    expect(proposePlan({ ...base, parties: [...parties].reverse() })).toEqual(result);
  });
  it("retains an earlier explicit ordinary stop independently of the dominant desired end", () => {
    const result = proposePlan({ ...base, parties: [{ ...family("a", "21:00"), requestedStopAt: at("18:00") }] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ dominantEndAt: iso("21:00"), effectiveStopAt: iso("18:00"), expectedFinaleArrivalAt: iso("19:00") });
  });
  it("reports an impossible desired completion instead of overruling opening or finale duration", () => {
    const result = proposePlan({ ...base, parties: [family("too-early", "18:50")] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "DESIRED_END_UNREACHABLE" }));
  });
  it("shortens ordinary walking only when no usual or later finale gap fits the shared end deadline", () => {
    const input = { ...base, parties: [family("a", "20:00"), family("b", "20:00")], finaleMaxGroups: 1 };
    const result = proposePlan(input);
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ expectedFinaleArrivalAt: iso("19:54"), effectiveStopAt: iso("19:44") });
    expect(result.groups[1]).toMatchObject({ expectedFinaleArrivalAt: iso("19:46"), effectiveStopAt: iso("19:36") });
    expect(result.groups[1].warnings).toContain("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
    expect(result.groups[1].explanation).toContain("Stop 8 minuten eerder bij gewone poorten");
    expect(proposePlan({ ...input, parties: [...input.parties].reverse() })).toEqual(result);
  });
  it("uses a later finale gap before shortening the ordinary route", () => {
    const result = proposePlan({ ...base, parties: [family("a", "21:00"), family("b", "21:00")], finaleMaxGroups: 1 });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[1]).toMatchObject({ expectedFinaleArrivalAt: iso("20:48"), effectiveStopAt: iso("20:30") });
    expect(result.groups[1].warnings).not.toContain("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
  });
  it("respects finale capacity and desired completion even when start capacity remains", () => {
    const result = proposePlan({ ...base, parties: [family("a", "20:00")], finaleMaxGroups: 1, existingSchedules: [{ id: "other-published", startId: "other-slot", startPointId: "poort-2", startsAt: at("17:00"), childCount: 2, expectedFinaleArrivalAt: at("19:00"), finaleEndsAt: at("20:10") }] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "FINALE_CAPACITY_EXCEEDED" }));
  });
  it("uses actual concurrent capacity when two existing groups succeed each other during a show", () => {
    const result = proposePlan({ ...base, parties: [family("new", "19:09")], finaleMaxGroups: 2, finaleTurnoverSeconds: 0,
      existingSchedules: [
        { id: "existing-a", groupId: "a", startId: "other-a", startPointId: "poort-2", startsAt: at("17:00"), childCount: 2, expectedFinaleArrivalAt: at("19:00") },
        { id: "existing-b", groupId: "b", startId: "other-b", startPointId: "poort-2", startsAt: at("17:10"), childCount: 2, expectedFinaleArrivalAt: at("19:06") },
      ] });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0]).toMatchObject({ expectedFinaleArrivalAt: iso("19:03"), effectiveStopAt: iso("18:53") });
    expect(result.groups[0].warnings).not.toContain("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
  });
  it("rejects three genuinely concurrent finale groups when no earlier or later gap fits", () => {
    const result = proposePlan({ ...base, parties: [family("new", "19:09")], finaleMaxGroups: 2, finaleTurnoverSeconds: 0,
      existingSchedules: [
        { id: "existing-a", groupId: "a", startId: "other-a", startPointId: "poort-2", startsAt: at("17:00"), childCount: 2, expectedFinaleArrivalAt: at("19:00") },
        { id: "existing-b", groupId: "b", startId: "other-b", startPointId: "poort-2", startsAt: at("17:10"), childCount: 2, expectedFinaleArrivalAt: at("19:03") },
      ] });
    expect(result.groups).toEqual([]);
    expect(result.conflicts).toContainEqual(expect.objectContaining({ code: "FINALE_CAPACITY_EXCEEDED" }));
  });
  it("does not count finale turnover as the household's desired show completion", () => {
    const result = proposePlan({ ...base, parties: [family("a", "20:00")], finaleTurnoverSeconds: 900 });
    expect(result.conflicts).toEqual([]);
    expect(result.groups[0].expectedFinaleArrivalAt).toBe(iso("19:54"));
  });
});
