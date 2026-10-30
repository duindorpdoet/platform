import { describe, expect, it } from "vitest";
import { jointRouteReviewDiagnostics } from "./joint-route-review";
import type { JointRouteDiagnostic, JointRouteGroupPlan } from "./joint-route-planner";

const diagnostic: JointRouteDiagnostic = { code: "LIMIT", severity: "warning", message: "Opening te kort", groupId: "a", portalId: "house" };
const group = (groupId: string, diagnostics: JointRouteDiagnostic[]): JointRouteGroupPlan => ({ groupId, startsAt: "2026-10-31T17:00:00Z", finaleArrivalAt: null, expectedCompletionAt: null, visits: [], diagnostics });

describe("joint route review findings", () => {
  it("shows a group finding once when conflicts also contains it", () => {
    expect(jointRouteReviewDiagnostics({ groups: [group("a", [{ ...diagnostic, groupId: undefined }])], conflicts: [diagnostic] })).toEqual({ blocks: [], advice: [diagnostic] });
  });

  it("keeps distinct group and house constraints and separates hard conflicts", () => {
    const hard = { ...diagnostic, severity: "block" as const };
    const other = { ...diagnostic, groupId: "b" }, otherHouse = { ...diagnostic, portalId: "another-house" };
    expect(jointRouteReviewDiagnostics({ groups: [group("a", [diagnostic, otherHouse]), group("b", [other])], conflicts: [hard] })).toEqual({ blocks: [hard], advice: [otherHouse, other] });
  });

  it("keeps the canonical conflict when the group repeats it with different wording", () => {
    expect(jointRouteReviewDiagnostics({ groups: [group("a", [{ ...diagnostic, message: "Andere uitleg voor dezelfde opening" }])], conflicts: [diagnostic] })).toEqual({ blocks: [], advice: [diagnostic] });
  });
});
