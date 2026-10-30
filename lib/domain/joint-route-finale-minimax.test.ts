import { describe, expect, it } from "vitest";
import { JOINT_FINALE_MINIMAX_LIMITS, optimizeJointFinaleMinimax } from "./joint-route-finale-minimax";
import { jointIso, jointTime } from "./joint-route-time";
import { validateJointRoutes, type JointRouteGroupPlan, type JointRouteInput } from "./joint-route-planner";

const time = (seconds: number) => new Date(Date.parse("2026-10-31T17:00:00Z") + seconds * 1000).toISOString();
function fixture(count = 2): { input: JointRouteInput; plans: JointRouteGroupPlan[] } {
  const ordinaryWindow = { opensAt: time(0), arrivalClosesAt: time(14_400), closesAt: time(14_400), visitSeconds: 300,
    bufferSeconds: 0, maxGroups: 100, maxChildren: 100, maxTotalChildren: 10_000, headwaySeconds: 0 };
  const groups = Array.from({ length: count }, (_, index) => ({ id: `g${index}`, code: `G${index}`, childCount: 10,
    startNodeId: `start:g${index}`, startsAt: time(0), startConfirmed: true, ordinaryStopAt: time(10_000), desiredEndAt: null,
    maxOrdinaryVisits: null, requiresStepFree: false, accessibilityNeedsReview: false, fixedFirstPortalId: "house", excludedPortalIds: [],
    finale: { portalId: "finale", reservedAt: time(1800 + index * 600), reservationValid: true, latestArrivalAt: time(12_000) } }));
  const portals = [{ id: "house", code: "P-house", name: "Ordinary house", nodeId: "portal:house", worldSlug: "anders",
    finale: false, accessibilityStatus: "step_free" as const, windows: [ordinaryWindow] },
  { id: "finale", code: "P-38", name: "Finale", nodeId: "portal:finale", worldSlug: "finale", finale: true,
    accessibilityStatus: "step_free" as const, windows: [{ ...ordinaryWindow, visitSeconds: 360, bufferSeconds: 120,
      maxGroups: 2, maxConcurrentChildren: 200, headwaySeconds: 300 }] }];
  const nodes = [...groups.map(group => group.startNodeId), ...portals.map(portal => portal.nodeId)];
  const input: JointRouteInput = { eventId: "synthetic", policyVersion: "joint-reception-v3", sourceHash: "a".repeat(64), boardHash: "b".repeat(32),
    maxGroupOverrunSeconds: 1800, maxEarlyFinishSeconds: 1800, routePolicySettingsVersion: 1, organizerCoveragePortalIds: [],
    maxLegWalkingSeconds: 900, maxTotalWalkingSeconds: 4500, needsAnders: false, groups, portals,
    legs: nodes.flatMap(from => portals.map(portal => ({ from, to: portal.nodeId, seconds: 0, meters: 0 }))), fixedVisits: [], before: [] };
  const plans = groups.map((group): JointRouteGroupPlan => ({ groupId: group.id, startsAt: group.startsAt, desiredEndAt: null,
    finaleArrivalAt: group.finale.reservedAt, expectedCompletionAt: jointIso(jointTime(group.finale.reservedAt) + 360), diagnostics: [], visits: [
      { portalId: "house", kind: "ordinary", sequence: 1, startsAt: time(0), visitSeconds: 300, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 },
      { portalId: "finale", kind: "finale", sequence: 2, startsAt: group.finale.reservedAt, visitSeconds: 360, bufferSeconds: 120, walkSeconds: 0, walkMeters: 0 },
    ] }));
  return { input, plans };
}
function apply(input: JointRouteInput, plans: JointRouteGroupPlan[], arrivals: Array<{ groupId: string; startsAt: string }>) {
  return plans.map(plan => {
    const start = arrivals.find(arrival => arrival.groupId === plan.groupId)!.startsAt, group = input.groups.find(group => group.id === plan.groupId)!;
    const old = plan.visits.at(-1)!, next = { ...plan, finaleArrivalAt: start, expectedCompletionAt: jointIso(jointTime(start) + old.visitSeconds),
      visits: [...plan.visits.slice(0, -1), { ...old, startsAt: start }] };
    if (group.finale.reservedAt !== start) next.finaleChange = { portalId: group.finale.portalId, previousReservedAt: group.finale.reservedAt, proposedReservedAt: start };
    else delete next.finaleChange;
    return next;
  });
}

describe("bounded joint finale minimax", () => {
  it("finds the shared order when the first greedy order misses a real deadline", () => {
    const { input, plans } = fixture();
    plans[0].visits[1].startsAt = time(300); plans[1].visits[1].startsAt = time(600);
    input.groups[1].finale.latestArrivalAt = time(300);
    const before = structuredClone(plans), optimized = optimizeJointFinaleMinimax(input, plans);
    expect(optimized.optimal).toBe(true);
    expect(optimized.arrivals).toEqual([{ groupId: "g0", startsAt: time(600) }, { groupId: "g1", startsAt: time(300) }]);
    const after = apply(input, plans, optimized.arrivals);
    expect(validateJointRoutes(input, after)).toEqual([]);
    expect(after.map(plan => plan.visits.slice(0, -1))).toEqual(plans.map(plan => plan.visits.slice(0, -1)));
    expect(plans).toEqual(before);
  });
  it("preserves fixed physical finale occupancy and exact headway endpoints", () => {
    const { input, plans } = fixture();
    input.fixedVisits.push({ ...plans[0].visits[1], groupId: "protected", portalId: "finale-alias", physicalId: "finale", children: 10, startsAt: time(600) });
    const fixed = structuredClone(input.fixedVisits), result = optimizeJointFinaleMinimax(input, plans);
    expect(result.optimal).toBe(true);
    expect(result.arrivals.map(arrival => jointTime(arrival.startsAt) - jointTime(time(0))).sort((a, b) => a - b)).toEqual([300, 900]);
    expect(validateJointRoutes(input, apply(input, plans, result.arrivals))).toEqual([]);
    expect(input.fixedVisits).toEqual(fixed);
    input.fixedVisits[0].visitSeconds++;
    const unsupported = optimizeJointFinaleMinimax(input, plans);
    expect(unsupported.changed).toBe(false); expect(unsupported.reason).toBe("unsupported-fixed-service");
  });
  it("keeps protected finale groups and rejects capacity models without earliest-last dominance", () => {
    const { input, plans } = fixture();
    input.fixedVisits.push({ ...plans[0].visits[1], groupId: "g0", children: 10 });
    expect(optimizeJointFinaleMinimax(input, plans).reason).toBe("protected-finale-group");
    input.fixedVisits = [];
    input.portals[1].windows[0].maxConcurrentChildren = 15;
    expect(optimizeJointFinaleMinimax(input, plans)).toMatchObject({ changed: false, reason: "unsupported-concurrent-children" });
    input.portals[1].windows[0].maxConcurrentChildren = 200;
    input.portals[1].windows[0].visitSeconds = 600; input.portals[1].windows[0].bufferSeconds = 120;
    plans.forEach(plan => { plan.visits[1].visitSeconds = 600; });
    expect(optimizeJointFinaleMinimax(input, plans).reason).toBe("unsupported-capacity-dominance");
  });
  it("honors a single physical slot as well as the separate arrival headway", () => {
    const { input, plans } = fixture(); input.portals[1].windows[0].maxGroups = 1;
    const result = optimizeJointFinaleMinimax(input, plans), after = apply(input, plans, result.arrivals);
    expect(result.optimal).toBe(true);
    expect(result.arrivals.map(arrival => jointTime(arrival.startsAt) - jointTime(time(0))).sort((a, b) => a - b)).toEqual([300, 780]);
    expect(validateJointRoutes(input, after)).toEqual([]);
  });
  it("includes a long real finale walk, hard show completion, physical buffer and last arrival", () => {
    const { input, plans } = fixture(1), group = input.groups[0], window = input.portals[1].windows[0];
    group.desiredEndAt = time(3600); group.latestCompletionAt = time(1800);
    window.arrivalClosesAt = time(1440); window.closesAt = time(1920);
    input.legs.find(leg => leg.from === "portal:house" && leg.to === "portal:finale")!.seconds = 925;
    plans[0].visits[1].walkSeconds = 925;
    const result = optimizeJointFinaleMinimax(input, plans), after = apply(input, plans, result.arrivals);
    expect(result.arrivals[0].startsAt).toBe(time(1440));
    expect(after[0].expectedCompletionAt).toBe(time(1800));
    expect(result.maxFinaleWaitingSecondsAfter).toBe(215);
    expect(validateJointRoutes(input, after)).toEqual([]);
    input.legs.find(leg => leg.from === "portal:house" && leg.to === "portal:finale")!.seconds = 1200;
    plans[0].visits[1].walkSeconds = 1200;
    expect(optimizeJointFinaleMinimax(input, plans)).toMatchObject({ changed: false, reason: "infeasible-final-times" });
  });
  it("retains PostgreSQL microseconds at an exact reachable arrival and physical closing", () => {
    const { input, plans } = fixture(1), window = input.portals[1].windows[0];
    plans[0].visits[0].startsAt = "2026-10-31T17:00:00.000001Z";
    window.opensAt = "2026-10-31T17:05:00.000001Z";
    window.arrivalClosesAt = window.opensAt; window.closesAt = "2026-10-31T17:13:00.000001Z";
    input.groups[0].finale.latestArrivalAt = window.opensAt;
    const result = optimizeJointFinaleMinimax(input, plans);
    expect(jointTime(result.arrivals[0].startsAt)).toBe(jointTime(window.opensAt));
    expect(validateJointRoutes(input, apply(input, plans, result.arrivals))).toEqual([]);
    window.closesAt = "2026-10-31T17:13:00.000000Z";
    expect(optimizeJointFinaleMinimax(input, plans).reason).toBe("infeasible-final-times");
  });
  it("reports the immutable ordinary reception floor and obeys one shared deterministic work bound", () => {
    const { input, plans } = fixture(1); plans[0].visits[0].startsAt = time(600);
    const result = optimizeJointFinaleMinimax(input, plans);
    expect(result.ordinaryWaitingFloorSeconds).toBe(600);
    expect(result.maxFinaleWaitingSecondsAfter).toBe(0);
    expect(result.maxWaitingSecondsAfter).toBe(600);
    const bounded = optimizeJointFinaleMinimax(input, plans, { maxWork: 1 });
    expect(bounded).toMatchObject({ changed: false, optimal: false, reason: "work-limit", work: { exhausted: true, operations: 1 } });
    expect(result.work.operations).toBeLessThanOrEqual(JOINT_FINALE_MINIMAX_LIMITS.maxWork);
    const shuffled = structuredClone(input); shuffled.groups.reverse(); shuffled.portals.reverse(); shuffled.legs.reverse();
    expect(optimizeJointFinaleMinimax(shuffled, [...plans].reverse())).toEqual(result);
  });
  it("deduplicates protected physical receipts conservatively and declines repeated finale history", () => {
    const { input, plans } = fixture(1), fixed = { ...plans[0].visits[1], groupId: "protected", children: 10, startsAt: time(600) };
    input.fixedVisits = [fixed, { ...fixed, portalId: "old-alias", physicalId: "finale", children: 20 }];
    input.portals[1].windows[0].maxTotalChildren = 25;
    expect(optimizeJointFinaleMinimax(input, plans)).toMatchObject({ changed: false, reason: "infeasible-total-children" });
    input.fixedVisits[1].startsAt = time(1200);
    expect(optimizeJointFinaleMinimax(input, plans).reason).toBe("unsupported-fixed-group-repeat");
  });
  it("retains a valid twenty-group schedule if the exact shared DP work allowance expires", () => {
    const { input, plans } = fixture(20);
    input.groups.forEach(group => { group.finale.latestArrivalAt = time(14_000); });
    expect(validateJointRoutes(input, plans)).toEqual([]);
    const result = optimizeJointFinaleMinimax(input, plans, { maxWork: 9000 });
    expect(result).toMatchObject({ changed: false, optimal: false, reason: "work-limit", work: { operations: 9000, exhausted: true } });
    expect(result.work.feasibilityChecks).toBeGreaterThan(0);
    expect(result.work.states).toBeGreaterThan(0);
    expect(validateJointRoutes(input, apply(input, plans, result.arrivals))).toEqual([]);
    const reordered = structuredClone(input); reordered.groups.reverse(); reordered.portals.reverse(); reordered.legs.reverse();
    expect(optimizeJointFinaleMinimax(reordered, [...plans].reverse(), { maxWork: 9000 })).toEqual(result);
  });
});
