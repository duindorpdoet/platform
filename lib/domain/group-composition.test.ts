import { describe, expect, it } from "vitest";
import {
  canMoveCompositionItem,
  compositionItems,
  dividedPartyIds,
  groupMatches,
  itemChildren,
  itemMatches,
  itemMatchesPreference,
  itemRepresentative,
  preferenceSummary,
} from "./group-composition";
const registration = (
  id: string,
  partyId: string | null,
  childCount = 1,
  extra = {},
) => ({
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
  ...extra,
});
describe("group composition clusters", () => {
  it("filters preferences without splitting confirmed parties", () => {
    const mixed = compositionItems([
      registration("a", "party", 1, {
        preferredStartAt: "2026-10-31T18:00:00Z",
      }),
      registration("b", "party", 1, {
        preferredStartAt: "2026-10-31T19:00:00Z",
      }),
    ])[0];
    const none = compositionItems([registration("c", null)])[0];
    expect(itemMatchesPreference(mixed, "mixed")).toBe(true);
    expect(itemMatchesPreference(mixed, "2026-10-31T19:00:00Z")).toBe(true);
    expect(itemMatchesPreference(mixed, "2026-10-31T20:00:00Z")).toBe(false);
    expect(itemMatchesPreference(mixed, "none")).toBe(false);
    expect(itemMatchesPreference(none, "none")).toBe(true);
    expect(itemMatchesPreference(none, "all")).toBe(true);
  });
  it("clusters only authoritative party ids, counts children once, and searches each member", () => {
    const items = compositionItems([
      registration("1", "confirmed", 2),
      registration("2", "confirmed", 3),
      registration("3", null),
    ]);
    expect(items).toHaveLength(2);
    expect(items[0].registrations).toHaveLength(2);
    expect(itemChildren(items[0])).toBe(5);
    expect(itemMatches(items[0], "kind 2")).toBe(true);
  });
  it("uses a stable representative regardless of server order", () => {
    const first = compositionItems([
      registration("b", "party"),
      registration("a", "party"),
    ])[0];
    const second = compositionItems([
      registration("a", "party"),
      registration("b", "party"),
    ])[0];
    expect(itemRepresentative(first).id).toBe("a");
    expect(itemRepresentative(second).id).toBe("a");
  });
  it("summarizes equal, absent, and differing party preferences", () => {
    expect(
      preferenceSummary(
        compositionItems([
          registration("1", "p", 1, {
            preferredStartAt: "2026-10-31T18:00:00Z",
          }),
          registration("2", "p", 1, {
            preferredStartAt: "2026-10-31T18:00:00Z",
          }),
        ])[0],
      ),
    ).toEqual({ kind: "same", value: "2026-10-31T18:00:00Z" });
    expect(
      preferenceSummary(
        compositionItems([registration("1", "p"), registration("2", "p")])[0],
      ),
    ).toEqual({ kind: "none" });
    expect(
      preferenceSummary(
        compositionItems([
          registration("1", "p", 1, { preferredStartAt: "a" }),
          registration("2", "p", 1, { preferredStartAt: "b" }),
        ])[0],
      ),
    ).toEqual({ kind: "mixed" });
  });
  it("blocks a whole cluster for published, locked, inconsistent, and full destinations", () => {
    const item = compositionItems([
      registration("1", "p"),
      registration("2", "p", 1, { assignmentPublished: true }),
    ])[0];
    expect(
      canMoveCompositionItem(item, {
        editable: true,
        sourceLocked: false,
        targetLocked: false,
        targetValid: true,
        targetChildCount: 1,
        maxGroupSize: 9,
      }).canMove,
    ).toBe(false);
    const single = compositionItems([registration("3", null, 5)])[0];
    expect(
      canMoveCompositionItem(single, {
        editable: true,
        sourceLocked: false,
        targetLocked: false,
        targetValid: true,
        targetChildCount: 17,
        maxGroupSize: 20,
      }).reason,
    ).toBe("Vol · 17/20 + 5 kinderen");
    expect(
      canMoveCompositionItem(single, {
        editable: true,
        sourceLocked: true,
        targetLocked: false,
        targetValid: true,
        targetChildCount: 0,
        maxGroupSize: 20,
      }).canMove,
    ).toBe(false);
  });
  it("detects split parties and group-code/name matches", () => {
    expect(
      dividedPartyIds([
        { id: "a", registrations: [registration("1", "p")] },
        { id: "b", registrations: [registration("2", "p")] },
      ]).has("p"),
    ).toBe(true);
    expect(groupMatches("G-02", "Maanwandelaars", "maan")).toBe(true);
    expect(groupMatches("G-02", "Maanwandelaars", "g-02")).toBe(true);
  });
});
