import { describe, expect, it } from "vitest";
import { groupLabel, matchingMembers, partyIdentity, partyPreference, togetherError, type TogetherParty } from "./together-management";
const party: TogetherParty = {
  partyId: "confirmed", clusterReference: "SL-2026-K7M4PQ", memberCount: 2, childCount: 3,
  members: ["a", "b"].map((id) => ({ id, reference: `DPH-2026-${id}`, togetherCode: id === "a" ? "X7K9" : "M4R8", status: "submitted", householdLabel: `Familie ${id}`, parentName: `Ouder ${id}`, parentEmail: `${id}@example.invalid`, childCount: id === "a" ? 2 : 1, children: [{ name: `Kind ${id}`, age: 8 }], preferredStartAt: "2026-10-31T17:00:00Z", desiredEndAt: "2026-10-31T19:30:00Z", walkingGroup: null, assignmentPublished: false })),
  walkingGroup: null, walkingGroups: [], locked: false, published: false, problems: [], stateToken: "state",
};
describe("together organizer view", () => {
  it("uses cluster identity and explains missing identity without generating a code", () => {
    expect(partyIdentity(party)).toBe("SL-2026-K7M4PQ");
    expect(partyIdentity({ ...party, clusterReference: null })).toBe("Samenloop · reference ontbreekt");
    expect(partyIdentity({ ...party, clusterReference: null, memberCount: 1 })).toBe("DPH-2026-a");
  });
  it("reports the matching member for each supported household query", () => {
    for (const query of ["dph-2026-b", "m4r8", "ouder b", "b@example.invalid", "kind b"]) {
      expect(matchingMembers(party, query)).toEqual(["DPH-2026-b"]);
      expect(party.members).toHaveLength(2);
    }
    expect(matchingMembers(party, "")).toEqual([]);
  });
  it("summarizes the entire preference window including differing end times", () => {
    expect(partyPreference(party)).toBe("Voorkeur: 18:00–20:30");
    expect(partyPreference({ ...party, members: party.members.map((m, i) => ({ ...m, desiredEndAt: i ? null : m.desiredEndAt })) })).toBe("Verschillende voorkeurstijden");
    expect(partyPreference({ ...party, members: party.members.map((m) => ({ ...m, preferredStartAt: null, desiredEndAt: null })) })).toBe("Geen voorkeur");
  });
  it("shows group conflicts and asks for renewed preview on stale data", () => {
    expect(groupLabel(party)).toBe("Nog niet ingedeeld");
    expect(groupLabel({ ...party, walkingGroups: [{ id: "g", systemCode: "G-02", displayName: "Nachtlopers", status: "draft", locked: false }] })).toBe("G-02 · Nachtlopers");
    expect(togetherError("STALE_VERSION")).toContain("opnieuw");
  });
});
