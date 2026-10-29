import { describe, expect, it } from "vitest";
import { assignmentDraft, canonicalTimestamp, checkedRouteVisitLabel, reconcileAssignment, sameTimestamp, timestampChoices } from "./start-assignment";
import { mergeReadiness, readinessFromError } from "./start-publication-readiness";

const variants = ["2026-10-31T16:00:00+00:00", "2026-10-31T16:00:00Z", "2026-10-31T16:00:00.000Z", "2026-10-31T17:00:00+01:00"];
describe("stored start appointment presentation", () => {
  it("selects the saved instant for all PostgreSQL and browser timestamp spellings", () => {
    for (const saved of variants) {
      const value = canonicalTimestamp(saved);
      expect(timestampChoices([saved, ...variants])).toEqual([value]);
      expect(timestampChoices([saved, ...variants])).toContain(value);
      expect(sameTimestamp(saved, variants[0])).toBe(true);
    }
    expect(canonicalTimestamp("not-a-time")).toBe("");
  });
  it("retains a saved appointment outside regenerated standard slots", () => {
    expect(timestampChoices(["2026-10-31T16:15:00+00:00", variants[0]])).toEqual([variants[2], "2026-10-31T16:15:00.000Z"]);
  });
  it("updates pristine cards after concept saving and accepts its own saved change", () => {
    const original = assignmentDraft({ pointId: "a", startsAt: variants[0], revision: 1 });
    const incoming = { pointId: "b", startsAt: "2026-10-31T16:10:00Z", revision: 2 };
    expect(reconcileAssignment(original, incoming)).toMatchObject({ pointId: "b", startsAt: "2026-10-31T16:10:00.000Z", sourceChanged: false });
    expect(reconcileAssignment({ ...original, pointId: "b", startsAt: canonicalTimestamp(incoming.startsAt) }, incoming).sourceChanged).toBe(false);
  });
  it("keeps unsaved inputs across realtime/revision refresh and marks the concurrent change", () => {
    const dirty = { ...assignmentDraft({ pointId: "a", startsAt: variants[0], revision: 1 }), pointId: "local", startsAt: "2026-10-31T16:20:00.000Z" };
    const updated = reconcileAssignment(dirty, { pointId: "remote", startsAt: variants[1], revision: 2 });
    expect(updated).toMatchObject({ pointId: "local", startsAt: dirty.startsAt, sourceChanged: true, saved: { pointId: "remote", revision: 2 } });
    expect(reconcileAssignment(updated, { pointId: "remote", startsAt: variants[3], revision: 2 })).toBe(updated);
  });
});

describe("route visit count", () => {
  const expected = { groupId: "group", pointId: "start", startsAt: variants[0] };
  const route = { groupId: "group", revision: 7, start: { pointId: "start", startsAt: variants[3] }, stops: [{ portalId: "first", kind: "ordinary" }, { portalId: "other", kind: "ordinary" }, { portalId: "final", kind: "finale" }] };
  it("counts the checked route's unique houses and finale, including a linked first visit once", () => {
    expect(checkedRouteVisitLabel(route, 7, expected)).toBe("2 gewone huizen + 1 finale");
  });
  it("never converts time capacity, a different revision or a different appointment into visits", () => {
    for (const candidate of [undefined, { ...route, revision: 6 }, { ...route, start: { ...route.start, startsAt: "2026-10-31T16:10:00Z" } }]) {
      expect(checkedRouteVisitLabel(candidate, 7, expected)).toBe("Aantal bezoeken volgt na routecontrole");
    }
  });
  it("does not count a finale twice and makes malformed duplicate route rows explicit", () => {
    expect(checkedRouteVisitLabel({ ...route, stops: [...route.stops, { portalId: "final", kind: "ordinary" }] }, 7, expected)).toBe("2 gewone huizen + 1 finale · dubbele poort in route: controleer de route");
  });
});

it("shows the exact server readiness reason without inventing a replacement cause", () => {
  const reason = { code: "FINALE_NOT_CONFIRMED_AVAILABLE", message: "Bevestig Laatste poort veilig beschikbaar.", action: "settings" as const, field: "finaleAvailable" };
  const value = { ready: false, reasons: [reason], routeSettingsVersion: 7, eventSettingsVersion: 4 };
  expect(readinessFromError(JSON.stringify(value))).toEqual(value);
  expect(mergeReadiness(value, value)).toEqual([reason]);
  expect(readinessFromError("invalid details")).toBeNull();
});
