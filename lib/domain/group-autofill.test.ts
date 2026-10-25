import { describe, expect, it } from "vitest";
import { dominantStartPreference } from "./start-preference";
import { proposeGroupAutofill } from "./group-autofill";
import type { CompositionRegistration } from "./group-composition";
const time = (value: string) => `2026-10-31T${value}:00Z`;
function registration(id: string, children: number, preference: string | null = "18:00", partyId: string | null = null): CompositionRegistration {
  return { id, reference: id, childCount: children, preferredStartAt: preference ? time(preference) : null, partyId, householdLabel: id, parentEmail: null, children: [], clusterReference: null, desiredEndAt: null, assignmentPublished: false };
}
describe("dominant registration preference", () => {
  it("uses one vote per registration, neutral missing votes and the original votes of all blocks", () => {
    const members = [registration("a", 1),registration("b", 1),registration("c", 1),registration("d", 14,"17:30"),registration("e", 2,null)];
    expect(dominantStartPreference(members)).toBe(time("18:00").replace("Z", ".000Z"));
    expect(dominantStartPreference([...members, members[3]])).toBe(dominantStartPreference(members));
  });
  it("breaks mode ties by absolute deviation then earliest, independently of row order", () => {
    const members = [registration("a",1,"17:00"),registration("b",1,"18:00"),registration("c",1,"19:00")];
    expect(dominantStartPreference(members)).toContain("18:00");
    expect(dominantStartPreference(members.reverse())).toContain("18:00");
    expect(dominantStartPreference([registration("a",1,"17:00"),registration("b",1,"18:00")])).toContain("17:00");
    expect(dominantStartPreference([registration("a",1,null)])).toBeNull();
  });
});
describe("autofill without slots", () => {
  it("keeps seventeen children together above a target of fifteen", () => {
    const members = [registration("a",9,"18:00","party"),registration("b",8,"18:00","party")];
    const groups = proposeGroupAutofill(members,20);
    expect(groups).toHaveLength(1);expect(groups[0].childCount).toBe(17);expect(groups[0].warnings).toContain("INTACT_BLOCK_ABOVE_TARGET");
  });
  it("combines nine and eight, prefers matching times and is stable under shuffled rows", () => {
    const members=[registration("a",9),registration("b",8),registration("c",9,"19:00"),registration("d",6,"19:00")];
    const groups=proposeGroupAutofill(members,20);
    expect(groups.map(g=>g.childCount)).toEqual([17,15]);
    expect(proposeGroupAutofill([...members].reverse(),20)).toEqual(groups);
    expect(groups.flatMap(g=>g.registrationIds).sort()).toEqual(members.map(m=>m.id));
  });
  it("keeps an oversized block visible for a deliberate maximum policy decision", () => {
    const groups=proposeGroupAutofill([registration("a",17)],12);
    expect(groups[0]).toMatchObject({childCount:17,warnings:["EVENT_MAXIMUM_EXCEPTION_REQUIRED"]});
  });
});
