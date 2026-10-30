import { describe, expect, it } from "vitest";
import { JOINT_ROUTE_SEARCH_LIMITS, jointRouteProposalDigestText, measureJointRoutes, proposeJointRoutes, validateJointRoutes, type JointRouteInput, type JointRoutePortal } from "./joint-route-planner";

const time = (clock: string) => `2026-10-31T${clock.length === 5 ? `${clock}:00` : clock}.000Z`;
function fixture(groupCount = 1, houseCount = 1): JointRouteInput {
  const window = { opensAt: time("17:00"), arrivalClosesAt: time("22:00"), closesAt: time("22:00"), visitSeconds: 360, bufferSeconds: 0, maxGroups: 100, maxChildren: 30, maxTotalChildren: 1000, headwaySeconds: 300 };
  const portals: JointRoutePortal[] = Array.from({ length: houseCount }, (_, index) => ({ id: `house-${index}`, code: `P-${index}`, name: `Synthetic house ${index}`, nodeId: `portal:house-${index}`, worldSlug: "anders", finale: false, accessibilityStatus: "unknown", windows: [{ ...window }] }));
  portals.push({ id: "finale", code: "P-F", name: "Synthetic finale", nodeId: "portal:finale", worldSlug: "finale", finale: true, accessibilityStatus: "step_free", windows: [{ ...window, maxGroups: 1, maxConcurrentChildren: 30 }] });
  const groups = Array.from({ length: groupCount }, (_, index) => ({ id: `group-${index}`, code: `G-${index}`, childCount: 10, startNodeId: `start:group-${index}`, startsAt: time("17:00"), startConfirmed: true, ordinaryStopAt: time("21:00"), desiredEndAt: time("21:00"), maxOrdinaryVisits: null, requiresStepFree: false, accessibilityNeedsReview: false, fixedFirstPortalId: null, excludedPortalIds: [], finale: { portalId: "finale", reservedAt: new Date(Date.parse(time("19:00")) + index * 360_000).toISOString(), reservationValid: true, latestArrivalAt: time("21:30") } }));
  const nodes = [...groups.map(group => group.startNodeId), ...portals.map(portal => portal.nodeId)];
  return { eventId: "synthetic-event", sourceHash: "a".repeat(64), boardHash: "b".repeat(32), policyVersion: "synthetic-v1", maxGroupOverrunSeconds: 1800,
    maxLegWalkingSeconds: 900, maxTotalWalkingSeconds: 3600, needsAnders: false, groups, portals,
    legs: nodes.flatMap(from => portals.map(portal => ({ from, to: portal.nodeId, seconds: 0, meters: 0 }))), fixedVisits: [], before: [] };
}

describe("one physical calendar", () => {
  it("spreads four groups by five minutes even when overlap capacity is 100", () => {
    const input = fixture(4);
    const result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    const arrivals = result.groups.flatMap(group => group.visits.filter(visit => visit.kind === "ordinary").map(visit => Date.parse(visit.startsAt))).sort((a, b) => a - b);
    expect(arrivals).toHaveLength(4);
    expect(arrivals.slice(1).every((value, index) => value - arrivals[index] >= 300_000)).toBe(true);
    const changed = structuredClone(result.groups);
    changed[1].visits[0].startsAt = new Date(Date.parse(changed[0].visits[0].startsAt) + 299_000).toISOString();
    expect(validateJointRoutes(input, changed).some(item => item.code === "ARRIVAL_OR_CAPACITY_CONFLICT")).toBe(true);
    changed[1].visits[0].startsAt = new Date(Date.parse(changed[0].visits[0].startsAt) + 300_000).toISOString();
    expect(validateJointRoutes(input, changed)).toEqual([]);
  });
  it("allows overlap only with enough simultaneous groups, and honors the service time", () => {
    const input = fixture(4);
    input.portals[0].windows[0].maxGroups = 1;
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    const arrivals = result.groups.map(group => Date.parse(group.visits[0].startsAt)).sort((a, b) => a - b);
    expect(arrivals.slice(1).every((value, index) => value - arrivals[index] >= 360_000)).toBe(true);
    input.portals[0].windows[0].headwaySeconds = 600;
    const tenMinutes = proposeJointRoutes(input).groups.map(group => Date.parse(group.visits[0].startsAt)).sort((a, b) => a - b);
    expect(tenMinutes.slice(1).every((value, index) => value - tenMinutes[index] >= 600_000)).toBe(true);
  });
  it("keeps per-group, cumulative children and concurrent finale children separate", () => {
    const input = fixture(2);
    input.groups[1].finale.reservedAt = new Date(Date.parse(input.groups[0].finale.reservedAt!) + 300_000).toISOString();
    input.portals.at(-1)!.windows[0].maxGroups = 2;
    input.portals.at(-1)!.windows[0].maxConcurrentChildren = 15;
    const separated = proposeJointRoutes(input);
    expect(separated.valid).toBe(true);
    const finals = separated.groups.map(group => Date.parse(group.finaleArrivalAt!)).sort((a, b) => a - b);
    expect(finals[1] - finals[0]).toBeGreaterThanOrEqual(360_000);
    input.portals.at(-1)!.windows[0].maxConcurrentChildren = 20;
    expect(proposeJointRoutes(input).valid).toBe(true);
    input.portals[0].windows[0].maxTotalChildren = 15;
    expect(proposeJointRoutes(input).conflicts.some(item => item.code === "NO_FEASIBLE_ORDINARY_VISIT")).toBe(true);
    input.portals[0].windows[0].maxTotalChildren = 1000;
    input.portals[0].windows[0].maxChildren = 9;
    expect(proposeJointRoutes(input).metrics.after.totalOrdinaryVisits).toBe(0);
  });
  it("uses the same physical calendar and unique visit identity for proven aliases", () => {
    const input = fixture(2, 2);
    input.portals[0].physicalId = "same-physical-house";
    input.portals[1].physicalId = "same-physical-house";
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(2);
    expect(result.metrics.after.byPortal).toHaveLength(1);
    const arrivals = result.groups.map(group => Date.parse(group.visits[0].startsAt)).sort((a, b) => a - b);
    expect(arrivals[1] - arrivals[0]).toBeGreaterThanOrEqual(300_000);
    input.groups[0].excludedPortalIds = ["same-physical-house"];
    expect(proposeJointRoutes(input).groups[0].visits.filter(visit => visit.kind === "ordinary")).toHaveLength(0);
  });
  it("ignores administrative starts as physical visits and preserves their count", () => {
    const input = fixture();
    input.fixedVisits.push({ id: "admin-start", groupId: "other", children: 1000, portalId: "house-0", kind: "start", sequence: 1, startsAt: time("17:00"), visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 });
    input.before = [{ groupId: input.groups[0].id, startsAt: input.groups[0].startsAt, finaleArrivalAt: null, expectedCompletionAt: null, diagnostics: [], visits: [input.fixedVisits[0]] }];
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.metrics.before.administrativeStarts).toBe(1);
    expect(result.metrics.after.administrativeStarts).toBe(1);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(1);
  });
});

describe("actual openings, reserved finales and group completion", () => {
  it("preserves a PostgreSQL microsecond finale, its show completion and the original start offset", () => {
    const input = fixture();
    input.groups[0].startsAt = "2026-10-31T18:00:00+01:00";
    input.groups[0].desiredEndAt = "2026-10-31T21:00:00+01:00";
    input.groups[0].finale.reservedAt = "2026-10-31T20:09:17.123456+01:00";
    input.portals.at(-1)!.windows[0].opensAt = input.groups[0].finale.reservedAt;
    const result = proposeJointRoutes(input), plan = result.groups[0];
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(plan.startsAt).toBe(input.groups[0].startsAt);
    expect(plan.visits.at(-1)?.startsAt).toBe(input.groups[0].finale.reservedAt);
    expect(plan.finaleArrivalAt).toBe(input.groups[0].finale.reservedAt);
    expect(plan.expectedCompletionAt).toBe("2026-10-31T19:15:17.123456Z");
    expect(plan.desiredEndAt).toBe(input.groups[0].desiredEndAt);
    expect(new Date(plan.desiredEndAt!).toLocaleTimeString("nl-NL", { timeZone: "Europe/Amsterdam", hour: "2-digit", minute: "2-digit" })).toBe("21:00");
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
  });
  it("rejects submitted completion one microsecond beyond the per-group limit", () => {
    const input = fixture();
    input.groups[0].finale.reservedAt = "2026-10-31T21:24:00.000000Z";
    input.portals.at(-1)!.windows[0].opensAt = input.groups[0].finale.reservedAt;
    const exact = proposeJointRoutes(input);
    expect(exact.valid).toBe(true);
    const plan = exact.groups[0];
    plan.visits.at(-1)!.startsAt = "2026-10-31T21:24:00.000001Z";
    plan.finaleArrivalAt = plan.visits.at(-1)!.startsAt;
    plan.expectedCompletionAt = "2026-10-31T21:30:00.000001Z";
    plan.finaleChange = { portalId: "finale", previousReservedAt: input.groups[0].finale.reservedAt, proposedReservedAt: plan.finaleArrivalAt };
    expect(validateJointRoutes(input, exact.groups).some(item => item.code === "GROUP_COMPLETION_LIMIT")).toBe(true);
    input.groups[0].desiredEndAt = "2026-10-31T21:00:00.000001Z";
    expect(validateJointRoutes(input, exact.groups)).toEqual([]);
  });
  it("keeps a microsecond opening and exact physical close without rounding an arrival earlier", () => {
    const input = fixture();
    Object.assign(input.portals[0].windows[0], { opensAt: "2026-10-31T17:00:00.123456Z", arrivalClosesAt: time("17:01"), closesAt: "2026-10-31T17:06:00.123456Z" });
    const exact = proposeJointRoutes(input);
    expect(exact.valid, JSON.stringify(exact.conflicts)).toBe(true);
    expect(exact.groups[0].visits[0].startsAt).toBe("2026-10-31T17:00:00.123456Z");
    input.portals[0].windows[0].closesAt = "2026-10-31T17:06:00.123455Z";
    expect(proposeJointRoutes(input).valid).toBe(false);
  });
  it.each([false, true])("preserves microsecond headway and touching buffers (physical buffer bound: %s)", bufferBound => {
    const input = fixture(2);
    input.portals[0].windows[0].opensAt = "2026-10-31T17:00:00.123456Z";
    if (bufferBound) Object.assign(input.portals[0].windows[0], { maxGroups: 1, bufferSeconds: 120 });
    const exact = proposeJointRoutes(input);
    expect(exact.valid).toBe(true);
    const ordered = exact.groups.map(group => group.visits[0]).sort((a,b) => a.startsAt.localeCompare(b.startsAt));
    const nextMinute = bufferBound ? "08" : "05";
    expect(ordered.map(visit => visit.startsAt)).toEqual(["2026-10-31T17:00:00.123456Z", `2026-10-31T17:${nextMinute}:00.123456Z`]);
    ordered[1].startsAt = `2026-10-31T17:${nextMinute}:00.123455Z`;
    expect(validateJointRoutes(input, exact.groups).some(item => item.code === "ARRIVAL_OR_CAPACITY_CONFLICT")).toBe(true);
  });
  it("proposes an explicit earlier time at the same finale to reduce the old gap", () => {
    const input = fixture();
    input.groups[0].finale.reservedAt = time("21:09");
    input.portals.at(-1)!.windows[0].opensAt = time("18:59");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.groups[0].finaleArrivalAt).toBe(time("18:59"));
    expect(result.groups[0].finaleChange).toEqual({ portalId: "finale", previousReservedAt: time("21:09"), proposedReservedAt: time("18:59") });
    expect(result.groups[0].diagnostics.some(item => item.code === "FINALE_TIME_CHANGE")).toBe(true);
    expect(result.groups[0].visits[0].visitSeconds).toBe(360);
    expect(result.groups[0].visits[0].waitSeconds).toBe(0);
    expect(result.metrics.after.byGroup[0].unallocatedBeforeFinaleSeconds).toBeLessThan(2 * 3600);
  });
  it("repairs an old early finale only through an explicitly reviewed time change", () => {
    const input = fixture();
    input.groups[0].finale.reservedAt = time("18:30");
    input.portals.at(-1)!.windows[0].opensAt = time("18:59");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.groups[0].finaleChange?.proposedReservedAt).toBe(time("18:59"));
    expect(result.groups[0].visits.some(visit => visit.kind === "finale" && Date.parse(visit.startsAt) < Date.parse(time("18:59")))).toBe(false);
  });
  it("allows completion exactly at target +30 minutes, with turnover only in physical closure", () => {
    const input = fixture();
    input.groups[0].finale.reservedAt = time("21:24");
    const finale = input.portals.at(-1)!.windows[0];
    finale.bufferSeconds = 120; finale.opensAt = time("21:24"); finale.closesAt = time("21:32");
    expect(proposeJointRoutes(input).valid).toBe(true);
    finale.closesAt = time("21:31:59");
    expect(proposeJointRoutes(input).valid).toBe(false);
    finale.closesAt = time("21:40");
    input.groups[0].finale.reservedAt = time("21:24:01");
    expect(proposeJointRoutes(input).groups[0].finaleChange?.proposedReservedAt).toBe(time("21:24"));
    input.groups[0].desiredEndAt = time("20:30"); input.groups[0].finale.reservedAt = time("20:54"); finale.opensAt = time("20:54");
    expect(proposeJointRoutes(input).valid).toBe(true);
    input.groups[0].finale.reservedAt = time("21:00"); finale.opensAt = time("21:00");
    expect(proposeJointRoutes(input).valid).toBe(false);
  });
  it("never permits a new arrival after ordinary close; small end grace differs from hard close", () => {
    const input = fixture();
    input.groups[0].startsAt = time("17:09");
    Object.assign(input.portals[0].windows[0], { arrivalClosesAt: time("17:10"), closesAt: time("17:15"), visitSeconds: 300, bufferSeconds: 60 });
    expect(proposeJointRoutes(input).valid).toBe(true);
    input.groups[0].startsAt = time("17:10");
    expect(proposeJointRoutes(input).valid).toBe(false);
    input.groups[0].startsAt = time("17:09"); input.portals[0].windows[0].closesAt = time("17:10");
    expect(proposeJointRoutes(input).valid).toBe(false);
  });
  it("does not transfer finale or group overrun allowance into a closed ordinary house", () => {
    const input = fixture();
    input.groups[0].startsAt = time("20:00"); input.groups[0].finale.reservedAt = time("21:24");
    input.portals[0].windows[0].arrivalClosesAt = time("19:00"); input.portals[0].windows[0].closesAt = time("19:05");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(false);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(0);
    expect(result.groups[0].visits.at(-1)?.startsAt).toBe(time("20:00"));
  });
  it("counts physical buffer separately from group walking/departure time", () => {
    const input = fixture(1, 2);
    input.portals[0].windows[0].bufferSeconds = 300;
    input.groups[0].fixedFirstPortalId = input.portals[0].id;
    const result = proposeJointRoutes(input), visits = result.groups[0].visits;
    expect(Date.parse(visits[1].startsAt) - Date.parse(visits[0].startsAt)).toBe(360_000);
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
  });
});

describe("accessibility and honest useful evenings", () => {
  it("distinguishes an explicit ordinary comment from a real mobility need and manual portal metadata", () => {
    const input = fixture(1, 2);
    input.portals[1].accessibilityStatus = "step_free";
    expect(proposeJointRoutes(input).metrics.after.totalOrdinaryVisits).toBe(2);
    input.groups[0].requiresStepFree = true;
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.groups[0].visits.filter(visit => visit.kind === "ordinary").map(visit => visit.portalId)).toEqual(["house-1"]);
    input.portals[1].accessibilityStatus = "unknown";
    expect(proposeJointRoutes(input).conflicts.some(item => item.code === "NO_FEASIBLE_ORDINARY_VISIT")).toBe(true);
  });
  it("conservatively plans review-needed groups through verified houses without inventing a declaration", () => {
    const input = fixture(1, 2);
    input.groups[0].accessibilityNeedsReview = true; input.portals[1].accessibilityStatus = "step_free";
    input.groups[0].fixedFirstPortalId = input.portals[0].id;
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.groups[0].startsAt).toBe(input.groups[0].startsAt);
    expect(result.groups[0].visits[0].portalId).toBe("house-1");
    expect(result.groups[0].diagnostics.map(item => item.code)).toContain("ACCESSIBILITY_NEEDS_REVIEW");
    expect(result.groups[0].diagnostics.map(item => item.code)).toContain("FIRST_PORTAL_ALTERNATIVE");
    expect(input.groups[0].requiresStepFree).toBe(false);
    input.portals.at(-1)!.accessibilityStatus = "unknown";
    const blocked = proposeJointRoutes(input);
    expect(blocked.valid).toBe(false);
    expect(blocked.metrics.after.totalOrdinaryVisits).toBe(1);
    expect(blocked.conflicts.some(item => item.code === "ACCESSIBILITY_REVIEW_REQUIRED")).toBe(true);
  });
  it("is deterministic under input reorder and honors scarce child-capacity alternatives", () => {
    const input = fixture(2, 3);
    input.groups[0].childCount = 20; input.portals[0].windows[0].maxChildren = 10;
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.metrics.after.minOrdinaryVisits).toBe(2);
    expect(result.groups[1].visits.some(visit => visit.portalId === input.portals[0].id)).toBe(true);
    const reverse = structuredClone(input); reverse.groups.reverse(); reverse.portals.reverse(); reverse.legs.reverse();
    expect(proposeJointRoutes(reverse)).toEqual(result);
    expect(jointRouteProposalDigestText(result.sourceHash, result.boardHash, result.groups)).not.toMatch(/\n$/);
  });
  it("does not claim inaccessible late opening hours are usable demand", () => {
    const input = fixture();
    input.portals[0].windows[0].arrivalClosesAt = time("22:00");
    const result = proposeJointRoutes(input);
    expect(result.metrics.after.byPortal[0].usableOpenSeconds).toBe(3 * 3600 + 54 * 60);
    const before = measureJointRoutes(input, result.groups);
    expect(before.byGroup[0].walkingSeconds).toBe(0);
  });
  it("has a deterministic search budget at the actual 18-group /20-house scale", () => {
    const input = fixture(18, 20);
    for (const [index, group] of input.groups.entries()) {
      group.startsAt = new Date(Date.parse(time("17:30")) + index % 3 * 600_000).toISOString();
      group.finale.reservedAt = new Date(Date.parse(time("19:30")) + index * 360_000).toISOString();
    }
    for (const portal of input.portals.filter(portal => !portal.finale)) { portal.windows[0].maxGroups = 2; portal.windows[0].bufferSeconds = 60; }
    for (const leg of input.legs) { leg.seconds = leg.from === leg.to ? 0 : 60; leg.meters = leg.seconds; }
    const result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.zeroVisitGroups).toBe(0);
    expect(result.metrics.after.byPortal.every(portal => portal.visits > 0)).toBe(true);
    // Bound deterministic work, independent of parallel CI load or CPU speed.
    expect(result.work.candidateEvaluations).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations);
    expect(result.work.pairReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.pairReplans);
  });
});

describe("organization route policy of 30 October", () => {
  it.each([925, 932, 976, 1020, 1114, 1200])("allows the actual final journey of %i seconds, measured and independently validated", seconds => {
    const input = fixture();
    input.groups[0].fixedFirstPortalId = "house-0";
    input.legs.find(leg => leg.from === "portal:house-0" && leg.to === "portal:finale")!.seconds = seconds;
    const result = proposeJointRoutes(input), finale = result.groups[0].visits.at(-1)!;
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(1);
    expect(finale.walkSeconds).toBe(seconds);
    expect(finale.kind).toBe("finale");
    expect(Date.parse(finale.startsAt) - Date.parse(result.groups[0].visits[0].startsAt)).toBe((360 + seconds) * 1000);
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
    expect(result.metrics.after.byPortal[0].usableOpenSeconds).toBeGreaterThan(0);
  });
  it("also allows a direct start-to-finale walk without adding a fabricated ordinary stop", () => {
    const input = fixture();
    input.groups[0].excludedPortalIds = ["house-0"];
    input.legs.find(leg => leg.from === input.groups[0].startNodeId && leg.to === "portal:finale")!.seconds = 1200;
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.groups[0].visits).toHaveLength(1);
    expect(result.groups[0].visits[0].walkSeconds).toBe(1200);
    expect(result.groups[0].diagnostics.some(diagnostic => diagnostic.code === "ALL_HOUSES_ALREADY_VISITED")).toBe(true);
  });
  it("rejects a 20-minute final journey with only five minutes available, even if a browser calls it valid", () => {
    const input = fixture();
    input.legs.find(leg => leg.from === "portal:house-0" && leg.to === "portal:finale")!.seconds = 1200;
    const result = proposeJointRoutes(input), plan = result.groups[0], first = plan.visits[0];
    const tooEarly = new Date(Date.parse(first.startsAt) + (first.visitSeconds + 300) * 1000).toISOString();
    plan.visits.at(-1)!.startsAt = tooEarly; plan.finaleArrivalAt = tooEarly;
    plan.expectedCompletionAt = new Date(Date.parse(tooEarly) + 360_000).toISOString();
    plan.finaleChange!.proposedReservedAt = tooEarly;
    expect(validateJointRoutes(input, result.groups).some(diagnostic => diagnostic.code === "TRAVEL_TIME")).toBe(true);
    plan.visits.at(-1)!.walkSeconds = 0;
    expect(validateJointRoutes(input, result.groups).some(diagnostic => diagnostic.code === "TRAVEL_ESTIMATE_MISMATCH")).toBe(true);
  });
  it("retains the separate ordinary leg and visible total walking limits", () => {
    const input = fixture();
    input.legs.find(leg => leg.from === input.groups[0].startNodeId && leg.to === "portal:house-0")!.seconds = 901;
    expect(proposeJointRoutes(input).metrics.after.totalOrdinaryVisits).toBe(0);
    const changed = fixture();
    changed.legs.find(leg => leg.from === "portal:house-0" && leg.to === "portal:finale")!.seconds = 1200;
    changed.maxTotalWalkingSeconds = 1000;
    const result = proposeJointRoutes(changed);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(0);
    expect(result.walkingPolicy).toEqual({ maxOrdinaryLegSeconds: 900, maxTotalSeconds: 1000, finaleLegLimitSeconds: null });
  });
  it("makes identical choices for Anders flags and all world labels while preserving a useful linked first", () => {
    const input = fixture(2, 4);
    input.groups[0].fixedFirstPortalId = "house-3";
    const ordinary = input.portals.filter(portal => !portal.finale);
    ordinary.forEach((portal, index) => { portal.worldSlug = index % 2 ? "circuswereld" : "anders"; });
    input.needsAnders = true;
    const original = proposeJointRoutes(input);
    const changed = structuredClone(input); changed.needsAnders = false;
    changed.portals.forEach(portal => { portal.worldSlug = "ander-thema"; });
    expect(proposeJointRoutes(changed)).toEqual(original);
    expect(original.groups[0].visits[0].portalId).toBe("house-3");
    expect(original.groups[0].diagnostics.some(diagnostic => diagnostic.code === "FIRST_PORTAL_ALTERNATIVE")).toBe(false);
    const removed = structuredClone(original.groups); removed[0].visits.shift();
    removed[0].visits.forEach((visit, index) => { visit.sequence = index + 1; });
    expect(validateJointRoutes(input, removed).some(diagnostic => diagnostic.code === "FEASIBLE_FIRST_PORTAL_MUST_BE_PRESERVED")).toBe(true);
  });
  it("does not truncate real opportunities at historical desired/max visit counts or a common group count", () => {
    const input = fixture(2, 17);
    input.groups[0].maxOrdinaryVisits = 0;
    input.groups[1].maxOrdinaryVisits = 11;
    input.groups[1].ordinaryStopAt = time("18:00");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true);
    expect(result.metrics.after.byGroup[0].ordinaryVisits).toBe(17);
    expect(result.metrics.after.byGroup[1].ordinaryVisits).toBeGreaterThan(0);
    expect(result.metrics.after.byGroup[1].ordinaryVisits).toBeLessThan(17);
  });
  it("requires explicit finale time review and the same physical destination, with exact service duration", () => {
    const input = fixture(1, 2), result = proposeJointRoutes(input);
    delete result.groups[0].finaleChange;
    expect(validateJointRoutes(input, result.groups).some(diagnostic => diagnostic.code === "FINALE_CHANGE_REVIEW_REQUIRED")).toBe(true);
    const changed = proposeJointRoutes(input);
    changed.groups[0].visits.at(-1)!.portalId = "house-1";
    expect(validateJointRoutes(input, changed.groups).some(diagnostic => diagnostic.code === "FINALE_LOCATION_CHANGED")).toBe(true);
    const longerShow = proposeJointRoutes(input);
    longerShow.groups[0].visits.at(-1)!.visitSeconds += 60;
    expect(validateJointRoutes(input, longerShow.groups).some(diagnostic => diagnostic.code === "OPENING_WINDOW")).toBe(true);
  });
});
