import { describe, expect, it } from "vitest";
import {
  compositionItems,
  itemChildren,
  itemMatches,
} from "./group-composition";

const registration = (id: string, partyId: string | null, childCount = 1) => ({
  id,
  reference: `INS-${id}`,
  householdLabel: `Huis ${id}`,
  parentEmail: null,
  childCount,
  children: [{ name: `Kind ${id}`, age: 8 }],
  partyId,
  preferredStartAt: null,
  desiredEndAt: null,
  assignmentPublished: false,
});
describe("group composition clusters", () => {
  it("clusters only confirmed party ids and uses +N for additional registrations", () => {
    const items = compositionItems([
      registration("1", "confirmed"),
      registration("2", "confirmed"),
      registration("3", null),
    ]);
    expect(items).toHaveLength(2);
    expect(items[0].registrations).toHaveLength(2);
    expect(items[0].registrations.length - 1).toBe(1);
  });
  it("does not duplicate children and searches every cluster member", () => {
    const items = compositionItems([
      registration("1", "confirmed", 2),
      registration("2", "confirmed", 3),
    ]);
    expect(itemChildren(items[0])).toBe(5);
    expect(itemMatches(items[0], "kind 2")).toBe(true);
  });
  it("keeps registrations without an authoritative party separate", () =>
    expect(
      compositionItems([registration("1", null), registration("2", null)]),
    ).toHaveLength(2));
});
