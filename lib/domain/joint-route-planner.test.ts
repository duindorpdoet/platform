import { describe, expect, it } from "vitest";
import { compareJointRouteProposals, JOINT_ROUTE_SEARCH_LIMITS, jointRouteProposalDigestText, measureJointRoutes, proposeJointRoutes, validateJointRoutes, type JointRouteInput, type JointRoutePortal } from "./joint-route-planner";

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
  }, 20_000);
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

function policy65(groupCount = 1, houseCount = 1): JointRouteInput {
  return { ...fixture(groupCount, houseCount), policyVersion: "joint-reception-v3", maxTotalWalkingSeconds: 3900,
    maxEarlyFinishSeconds: 1800, routePolicySettingsVersion: 1, organizerCoveragePortalIds: [] };
}

describe("65-minute walking, actual show completion and explicit physical coverage", () => {
  it("accepts exactly 3900 real walking seconds including a long final leg, and rejects 3901", () => {
    const input = policy65();
    input.legs.find(leg => leg.from === input.groups[0].startNodeId && leg.to === "portal:house-0")!.seconds = 900;
    input.legs.find(leg => leg.from === "portal:house-0" && leg.to === "portal:finale")!.seconds = 3000;
    const exact = proposeJointRoutes(input);
    expect(exact.valid, JSON.stringify(exact.conflicts)).toBe(true);
    expect(exact.metrics.after.byGroup[0].walkingSeconds).toBe(3900);
    expect(exact.groups[0].visits.at(-1)!.walkSeconds).toBe(3000);
    expect(validateJointRoutes(input, exact.groups)).toEqual([]);
    input.legs.find(leg => leg.from === "portal:house-0" && leg.to === "portal:finale")!.seconds = 3001;
    exact.groups[0].visits.at(-1)!.walkSeconds = 3001;
    expect(validateJointRoutes(input, exact.groups).map(item => item.code)).toContain("WALKING_BUDGET");
    expect(proposeJointRoutes(input).valid).toBe(false);
  });
  it("builds the hard early bound on the end of the real show, with turnover kept separate", () => {
    const input = policy65(); input.portals.at(-1)!.windows[0].bufferSeconds = 120;
    const result = proposeJointRoutes(input), plan = result.groups[0];
    expect(result.valid).toBe(true);
    expect(plan.earliestCompletionAt).toBe(time("20:30"));
    expect(plan.latestCompletionAt).toBe(time("21:30"));
    expect(plan.finaleArrivalAt).toBe(time("20:24"));
    expect(plan.expectedCompletionAt).toBe(time("20:30"));
    expect(plan.finaleChange?.proposedReservedAt).toBe(time("20:24"));
    expect(result.metrics.after.unallocatedBeforeFinaleSeconds).toBeGreaterThan(3600);
    expect(plan.diagnostics.filter(item => item.code === "UNALLOCATED_BEFORE_FINALE")).toHaveLength(1);
    const earlier = structuredClone(result.groups); earlier[0].visits.at(-1)!.startsAt = time("20:23:59");
    earlier[0].finaleArrivalAt = time("20:23:59"); earlier[0].expectedCompletionAt = time("20:29:59");
    earlier[0].finaleChange!.proposedReservedAt = time("20:23:59");
    expect(validateJointRoutes(input, earlier).map(item => item.code)).toContain("GROUP_COMPLETION_TOO_EARLY");
  });
  it("accepts the exact late show end and rejects one second beyond it", () => {
    const input = policy65(); input.portals.at(-1)!.windows[0].opensAt = time("21:24");
    const result = proposeJointRoutes(input), plan = result.groups[0];
    expect(result.valid).toBe(true); expect(plan.expectedCompletionAt).toBe(time("21:30"));
    plan.visits.at(-1)!.startsAt = time("21:24:01"); plan.finaleArrivalAt = time("21:24:01");
    plan.expectedCompletionAt = time("21:30:01"); plan.finaleChange!.proposedReservedAt = time("21:24:01");
    expect(validateJointRoutes(input, result.groups).map(item => item.code)).toContain("GROUP_COMPLETION_LIMIT");
  });
  it("does not invent a desired end or early lower bound and rejects incomplete v3 policy", () => {
    const input = policy65(); input.groups[0].desiredEndAt = null;
    input.groups[0].earliestCompletionAt = time("21:00");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(true); expect(result.groups[0].earliestCompletionAt).toBeNull();
    expect(result.groups[0].expectedCompletionAt).toBe(time("17:12"));
    delete input.maxEarlyFinishSeconds;
    expect(proposeJointRoutes(input).conflicts.map(item => item.code)).toContain("INVALID_ROUTE_POLICY_CONFIG");
  });
  it("diagnoses an empty intersection with the physical finale window during construction", () => {
    const input = policy65(); input.portals.at(-1)!.windows[0].closesAt = time("20:29:59");
    const result = proposeJointRoutes(input);
    expect(result.valid).toBe(false);
    expect(result.conflicts.some(item => item.code === "COMPLETION_WINDOW_UNAVAILABLE")).toBe(true);
    expect(result.metrics.after.byPortal[0].usableOpenSeconds).toBe(0);
  });
  it("allocates every finale inside the end window on one shared calendar", () => {
    const input = policy65(3); input.portals.at(-1)!.windows[0].maxGroups = 2;
    const result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    const finals = result.groups.map(plan => Date.parse(plan.finaleArrivalAt!)).sort((a, b) => a - b);
    expect(finals[0]).toBe(Date.parse(time("20:24")));
    expect(finals.slice(1).every((value, index) => value - finals[index] >= 300_000)).toBe(true);
    expect(result.groups.every(plan => Date.parse(plan.expectedCompletionAt!) >= Date.parse(time("20:30")))).toBe(true);
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
  });
  it("visits a short-window organization target in another order while preserving the linked first", () => {
    const input = policy65(2, 3); input.organizerCoveragePortalIds = ["house-2", "house-1"];
    input.groups.forEach(group => { group.fixedFirstPortalId = "house-0"; });
    input.portals[2].windows[0].arrivalClosesAt = time("17:13"); input.portals[2].windows[0].closesAt = time("17:19");
    const result = proposeJointRoutes(input, { mode: "organizer-coverage" });
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.groups.every(plan => plan.visits[0].portalId === "house-0")).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(6);
    expect(result.metrics.after.organizerCoverage.map(target => target.groups)).toEqual([2, 2]);
    expect(result.groups.every(plan => plan.visits.findIndex(visit => visit.portalId === "house-2") < plan.visits.findIndex(visit => visit.portalId === "house-1"))).toBe(true);
    const relabeled = structuredClone(input); relabeled.needsAnders = true;
    relabeled.portals.forEach(portal => { portal.worldSlug = "geen-routevoorkeur"; });
    expect(proposeJointRoutes(relabeled, { mode: "organizer-coverage" })).toEqual(result);
  });
  it("keeps active physical coverage ahead of optional organization targets", () => {
    const input = policy65(1, 3); input.groups[0].ordinaryStopAt = time("17:25");
    input.organizerCoveragePortalIds = ["house-0", "house-1"];
    for (const leg of input.legs) if (leg.to === "portal:house-0" && leg.from !== leg.to
      || leg.from === "portal:house-0" && leg.to !== "portal:finale" && leg.from !== leg.to) leg.seconds = 900;
    const general = proposeJointRoutes(input), coverage = proposeJointRoutes(input, { mode: "organizer-coverage" });
    expect(general.valid).toBe(true); expect(coverage.valid).toBe(true);
    expect(general.metrics.after.totalOrdinaryVisits).toBe(2);
    expect(general.metrics.after.organizerCoverage.map(target => target.groups)).toEqual([0, 1]);
    expect(coverage.metrics.after.totalOrdinaryVisits).toBe(2);
    expect(coverage.metrics.after.organizerCoverage.map(target => target.groups)).toEqual([0, 1]);
    expect(general.optimization.mode).toBe("general"); expect(coverage.optimization.mode).toBe("organizer-coverage");
    const omitted = general.groups[0].diagnostics.find(item => item.code === "OMITTED_PORTAL" && item.portalId === "house-0")!;
    expect(omitted.candidate?.totalWalkingSeconds).not.toBeNull();
    expect(omitted.candidate?.budgetSeconds).toBe(3900);
    expect(omitted.message).toContain(`${omitted.candidate!.totalWalkingSeconds} seconden`);
    expect(omitted.message).toContain(`${Math.ceil(omitted.candidate!.shortfallSeconds!)} seconden tijdtekort`);
  });
  it("treats an organization target absent from current suitable houses as missed coverage", () => {
    const input = policy65(); input.organizerCoveragePortalIds = ["temporarily-closed-physical-house"];
    const result = proposeJointRoutes(input, { mode: "organizer-coverage" });
    expect(result.valid).toBe(true);
    expect(result.metrics.after.organizerCoverage[0]).toMatchObject({ groups: 0, eligibleGroups: 0, missingGroupIds: ["group-0"] });
    expect(result.conflicts.filter(item => item.code === "ORGANIZER_TARGET_UNAVAILABLE")).toHaveLength(1);
  });
  it("does not combine a time-fitting over-budget insertion with a different short-walk insertion", () => {
    const input = policy65(1, 3); input.maxTotalWalkingSeconds = 1000;
    input.groups[0].fixedFirstPortalId = "house-0"; input.groups[0].ordinaryStopAt = time("17:15");
    input.organizerCoveragePortalIds = ["house-2"]; input.portals[2].windows[0].visitSeconds = 60;
    for (const leg of input.legs) {
      if (leg.from === "portal:house-0" && leg.to === "portal:house-2") leg.seconds = 300;
      if (leg.from === "portal:house-1" && leg.to === "portal:house-2") leg.seconds = 100;
      if (leg.from === "portal:house-2" && leg.to === "portal:finale") leg.seconds = 1900;
    }
    const result = proposeJointRoutes(input, { mode: "organizer-coverage" });
    expect(result.valid).toBe(true); expect(result.metrics.after.totalOrdinaryVisits).toBe(2);
    expect(result.metrics.after.organizerCoverage[0].groups).toBe(0);
    const diagnostic = result.groups[0].diagnostics.find(item => item.code === "OMITTED_PORTAL" && item.portalId === "house-2")!;
    expect(diagnostic.candidate).toMatchObject({ insertionIndex: 1, totalWalkingSeconds: 300, budgetSeconds: 1000,
      arrivalAt: time("17:11"), nextArrivalAt: time("17:06"), shortfallSeconds: 360, receptionAvailable: true });
    expect(diagnostic.message).toContain("300 seconden werkelijke totale looptijd");
    expect(diagnostic.message).toContain("360 seconden tijdtekort");
  });
  it.each([true, false])("inserts an unserved house and moves neighboring finale slots, explicit target %s", targeted => {
    const input = policy65(2, 3); input.maxTotalWalkingSeconds = 1000;
    input.organizerCoveragePortalIds = targeted ? ["house-2"] : [];
    input.groups.forEach(group => { group.fixedFirstPortalId = "house-0"; group.desiredEndAt = time("18:00"); group.ordinaryStopAt = time("17:50"); });
    input.groups[0].finale.latestArrivalAt = time("17:30"); input.groups[1].finale.latestArrivalAt = time("18:00");
    input.groups[1].excludedPortalIds = ["house-2"];
    Object.assign(input.portals.at(-1)!.windows[0], { opensAt: time("17:24"), arrivalClosesAt: time("18:00"), closesAt: time("18:10") });
    for (const leg of input.legs) {
      if (leg.from === "portal:house-0" && leg.to === "portal:house-2") leg.seconds = 300;
      if (leg.from === "portal:house-2" && leg.to === "portal:finale") leg.seconds = 1900;
      if (leg.from === "portal:house-1" && leg.to === "portal:finale") leg.seconds = 120;
    }
    const result = proposeJointRoutes(input, { mode: targeted ? "organizer-coverage" : "general" });
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(5);
    expect(result.groups[0].visits.map(visit => visit.portalId)).toEqual(["house-0", "house-2", "house-1", "finale"]);
    expect(result.groups.map(plan => plan.finaleArrivalAt)).toEqual([time("17:25"), time("17:31")]);
    expect(result.work.jointFinaleReplans).toBeGreaterThan(0);
    expect(result.work.jointFinaleReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.jointFinaleReplans);
    expect(result.groups.every(plan => plan.finaleChange?.proposedReservedAt === plan.finaleArrivalAt)).toBe(true);
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
  });
  it("keeps the coverage portfolio and both repair seeds within deterministic operation budgets", () => {
    const input = policy65(18, 20); input.organizerCoveragePortalIds = ["house-0", "house-1"];
    input.groups.forEach((group, index) => {
      group.startsAt = new Date(Date.parse(time("17:30")) + index % 3 * 600_000).toISOString();
      group.desiredEndAt = new Date(Date.parse(time("20:00")) + index % 3 * 1800_000).toISOString();
    });
    input.portals.forEach(portal => { portal.windows[0].maxGroups = 2; });
    input.portals.filter(portal => !portal.finale).forEach(portal => { portal.windows[0].bufferSeconds = 60; });
    input.legs.forEach(leg => { leg.seconds = leg.from === leg.to ? 0 : 60; leg.meters = leg.seconds; });
    const result = proposeJointRoutes(input, { mode: "organizer-coverage" });
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.zeroVisitGroups).toBe(0);
    expect(result.work.variants).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.variants);
    expect(result.work.candidateEvaluations).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations);
    expect(result.work.pairReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.pairReplans);
    expect(result.work.routeRepairs).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.routeRepairs);
    expect(result.work.jointFinaleReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.jointFinaleReplans);
    const small = policy65(3, 4); small.organizerCoveragePortalIds = ["house-0", "house-2"];
    const original = proposeJointRoutes(small, { mode: "organizer-coverage" });
    small.groups.reverse(); small.portals.reverse(); small.legs.reverse();
    expect(proposeJointRoutes(small, { mode: "organizer-coverage" })).toEqual(original);
  }, 20_000);
  it.each(["general", "organizer-coverage"] as const)("preserves a stronger established route when a new greedy candidate opens in %s mode", mode => {
    const input = fixture(1, 4), added = input.portals.splice(3, 1)[0];
    const shifted = (seconds: number) => new Date(Date.parse(time("17:00")) + seconds * 1000).toISOString();
    input.portals.filter(portal => !portal.finale).forEach((portal, index) => {
      Object.assign(portal.windows[0], { opensAt: shifted(index * 360), arrivalClosesAt: shifted((index + 1) * 360 + 2), closesAt: shifted((index + 1) * 360 + 2) });
    });
    input.legs.find(leg => leg.from === input.groups[0].startNodeId && leg.to === input.portals[0].nodeId)!.seconds = 2;
    const established = proposeJointRoutes(input, { mode });
    expect(established.metrics.after.totalOrdinaryVisits).toBe(3);
    input.before = established.groups;
    // Its short walk is attractive, but the real twenty-minute visit consumes
    // all three short openings. It cannot be inserted into the stronger route.
    Object.assign(added, { id: "added-house", nodeId: "portal:added-house" });
    Object.assign(added.windows[0], { visitSeconds: 1200, arrivalClosesAt: shifted(1200), closesAt: shifted(1200) });
    const oldNode = "portal:house-3";
    input.legs = input.legs.map(leg => ({ ...leg, from: leg.from === oldNode ? added.nodeId : leg.from, to: leg.to === oldNode ? added.nodeId : leg.to }));
    input.portals.push(added);
    const result = proposeJointRoutes(input, { mode });
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(3);
    expect(result.groups[0].visits.map(visit => visit.portalId)).toEqual(["house-0", "house-1", "house-2", "finale"]);
    input.groups.reverse(); input.portals.reverse(); input.legs.reverse();
    expect(proposeJointRoutes(input, { mode })).toEqual(result);
    // The established set remains a search seed, never an exclusion rule.
    for (const portal of input.portals.filter(portal => !portal.finale)) Object.assign(portal.windows[0], { opensAt: time("17:00"), arrivalClosesAt: time("22:00"), closesAt: time("22:00") });
    const expanded = proposeJointRoutes(input, { mode });
    expect(expanded.valid, JSON.stringify(expanded.conflicts)).toBe(true);
    expect(expanded.metrics.after.totalOrdinaryVisits).toBe(4);
    expect(expanded.groups[0].visits.some(visit => visit.portalId === added.id)).toBe(true);
  });
  it.each(["general", "portal-spread"] as const)("reserves full-candidate work under established-portfolio pressure in %s mode", mode => {
    const input = fixture(16, 101), added = input.portals.splice(100, 1)[0];
    const closes = "2026-11-01T06:00:00.000Z", ordinaryStopAt = "2026-11-01T05:00:00.000Z";
    input.groups.forEach(group => { group.desiredEndAt = null; group.ordinaryStopAt = ordinaryStopAt; group.finale.latestArrivalAt = closes; });
    [...input.portals, added].forEach((portal, index) => {
      portal.code = portal.finale ? "P-38" : `P-H${index}`;
      Object.assign(portal.windows[0], { arrivalClosesAt: closes, closesAt: closes });
    });
    const priorGroup = input.groups[1], ordinary = input.portals.filter(portal => !portal.finale).map((portal, index) => ({
      portalId: portal.id, kind: "ordinary" as const, sequence: index + 1, startsAt: new Date(Date.parse(priorGroup.startsAt) + index * 360_000).toISOString(),
      visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0,
    }));
    const priorFinale = new Date(Date.parse(priorGroup.startsAt) + ordinary.length * 360_000).toISOString();
    input.before = [{ groupId: priorGroup.id, startsAt: priorGroup.startsAt, finaleArrivalAt: priorFinale, expectedCompletionAt: new Date(Date.parse(priorFinale) + 360_000).toISOString(), diagnostics: [], visits: [...ordinary,
      { portalId: "finale", kind: "finale", sequence: ordinary.length + 1, startsAt: priorFinale, visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 }] }];
    input.groups[0].excludedPortalIds = ordinary.map(visit => visit.portalId);
    input.portals.push(added);
    const result = proposeJointRoutes(input, { mode });
    expect(result.valid, JSON.stringify(result.conflicts.filter(diagnostic => diagnostic.severity === "block"))).toBe(true);
    const historyGroup = result.groups.find(plan => plan.groupId === input.groups[0].id)!;
    expect(historyGroup.visits.filter(visit => visit.kind === "ordinary").map(visit => visit.portalId)).toEqual([added.id]);
    expect(result.groups.every(plan => plan.visits.filter(visit => visit.kind === "finale").length === 1)).toBe(true);
    expect(result.work.exhausted).toBe(true);
    expect(result.work.candidateEvaluations).toBeGreaterThan(JOINT_ROUTE_SEARCH_LIMITS.historicalCandidateEvaluations);
    expect(result.work.candidateEvaluations).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations);
    expect(result.work.variants).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.variants);
    expect(result.work.pairReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.pairReplans);
    expect(result.work.routeRepairs).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.routeRepairs);
    expect(result.work.jointFinaleReplans).toBeLessThanOrEqual(JOINT_ROUTE_SEARCH_LIMITS.jointFinaleReplans);
  }, 20_000);
});

describe("all active physical houses", () => {
  function activate(input: JointRouteInput, portal: JointRoutePortal) {
    const previous = portal.nodeId;
    Object.assign(portal, { id: "added-house", code: "P-new", nodeId: "portal:added-house" });
    input.legs = input.legs.map(leg => ({ ...leg, from: leg.from === previous ? portal.nodeId : leg.from, to: leg.to === previous ? portal.nodeId : leg.to }));
    input.portals.push(portal);
  }
  it("ranks wider physical coverage above more repeated visits and ignores claimed client metrics", () => {
    const input = fixture(2, 4), added = input.portals.splice(3, 1)[0];
    const shifted = (seconds: number) => new Date(Date.parse(time("17:00")) + seconds * 1000).toISOString();
    input.portals.filter(portal => !portal.finale).forEach((portal, index) => Object.assign(portal.windows[0], {
      opensAt: shifted(index * 360), arrivalClosesAt: shifted((index + 1) * 360 + 2), closesAt: shifted((index + 1) * 360 + 2), headwaySeconds: 0,
    }));
    input.legs.filter(leg => leg.from.startsWith("start:") && leg.to === "portal:house-0").forEach(leg => { leg.seconds = 2; });
    const repeated = proposeJointRoutes(input);
    expect(repeated.metrics.after.totalOrdinaryVisits).toBe(6);
    input.before = repeated.groups;
    activate(input, added);
    Object.assign(added.windows[0], { visitSeconds: 1200, arrivalClosesAt: shifted(1200), closesAt: shifted(1200) });
    const covered = proposeJointRoutes(input);
    expect(covered.valid, JSON.stringify(covered.conflicts)).toBe(true);
    expect(covered.metrics.after.unvisitedPortals).toEqual([]);
    expect(covered.metrics.after.totalOrdinaryVisits).toBe(4);
    expect(validateJointRoutes(input, repeated.groups)).toEqual([]);
    const misleading = structuredClone(repeated); misleading.metrics.after.totalOrdinaryVisits = 1000; misleading.metrics.after.unvisitedPortals = [];
    expect(compareJointRouteProposals(input, covered, misleading)).toBeGreaterThan(0);
    expect(compareJointRouteProposals(input, misleading, covered)).toBeLessThan(0);
    expect(compareJointRouteProposals(input, covered, structuredClone(covered))).toBe(0);
    const invalid = structuredClone(covered); invalid.groups[0].visits[0].startsAt = time("16:00");
    expect(compareJointRouteProposals(input, covered, invalid)).toBeGreaterThan(0);
  });
  it.each(["general", "organizer-coverage"] as const)("replaces a redundantly served house to cover a new active house in %s mode", mode => {
    const input = fixture(2, 4), added = input.portals.splice(3, 1)[0];
    const shifted = (seconds: number) => new Date(Date.parse(time("17:00")) + seconds * 1000).toISOString();
    input.groups.forEach(group => { group.fixedFirstPortalId = "house-0"; });
    const boundaries = [[0, 362], [362, 812], [722, 1142]];
    input.portals.filter(portal => !portal.finale).forEach((portal, index) => Object.assign(portal.windows[0], {
      opensAt: shifted(boundaries[index][0]), arrivalClosesAt: shifted(boundaries[index][1]), closesAt: shifted(boundaries[index][1]), headwaySeconds: 0,
    }));
    input.legs.filter(leg => leg.from.startsWith("start:") && leg.to === "portal:house-0").forEach(leg => { leg.seconds = 2; });
    const established = proposeJointRoutes(input, { mode });
    expect(established.metrics.after.totalOrdinaryVisits).toBe(6);
    input.before = established.groups;
    activate(input, added);
    Object.assign(added.windows[0], { opensAt: shifted(422), arrivalClosesAt: shifted(782), closesAt: shifted(782), headwaySeconds: 0 });
    input.legs.filter(leg => leg.to === added.nodeId && leg.from !== added.nodeId).forEach(leg => { leg.seconds = 60; });
    const result = proposeJointRoutes(input, { mode });
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(6);
    expect(result.metrics.after.unvisitedPortals).toEqual([]);
    expect(result.metrics.after.byPortal.find(portal => portal.portalId === added.id)?.visits).toBe(1);
    expect(result.groups.every(plan => plan.visits[0].portalId === "house-0")).toBe(true);
    expect(validateJointRoutes(input, result.groups)).toEqual([]);
    expect(compareJointRouteProposals(input, result, established, mode)).toBeGreaterThan(0);
  });
  it("continues adding genuine visits to a newly active house across multiple groups", () => {
    const input = fixture(3, 4), added = input.portals.splice(3, 1)[0];
    input.groups.forEach(group => { group.fixedFirstPortalId = "house-0"; });
    input.before = proposeJointRoutes(input).groups;
    activate(input, added);
    const result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(12);
    expect(result.metrics.after.byPortal.every(portal => portal.visits === 3)).toBe(true);
    expect(result.groups.every(plan => plan.visits[0].portalId === "house-0" && new Set(plan.visits.map(visit => visit.portalId)).size === 5)).toBe(true);
    const relabeled = structuredClone(input); relabeled.needsAnders = true;
    relabeled.groups.reverse(); relabeled.portals.reverse(); relabeled.legs.reverse();
    relabeled.portals.forEach(portal => { portal.worldSlug = "arbitrary-label"; });
    expect(proposeJointRoutes(relabeled)).toEqual(result);
  });
  it("reports a genuinely unavailable active house without inventing a visit", () => {
    const input = fixture(2, 3), blocked = input.portals[2];
    blocked.windows[0].opensAt = time("22:30"); blocked.windows[0].arrivalClosesAt = time("23:30"); blocked.windows[0].closesAt = time("23:30");
    const result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.unvisitedPortals).toEqual([blocked.id]);
    expect(result.groups.every(plan => !plan.visits.some(visit => visit.portalId === blocked.id))).toBe(true);
    expect(result.groups.every(plan => plan.diagnostics.some(diagnostic => diagnostic.code === "OMITTED_PORTAL" && diagnostic.portalId === blocked.id))).toBe(true);
  });
  it("counts protected ordinary physical visits once without treating history, aliases or finale as new coverage", () => {
    const input = fixture(1, 2);
    input.groups[0].excludedPortalIds = ["house-0"];
    input.fixedVisits = [
      { groupId: "begun-group", children: 10, portalId: "old-alias", physicalId: "house-0", kind: "ordinary", sequence: 1, startsAt: time("16:00"), visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 },
      { groupId: "begun-group", children: 10, portalId: "house-0", kind: "ordinary", sequence: 2, startsAt: time("16:10"), visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 },
      { groupId: "begun-group", children: 10, portalId: "finale-alias", physicalId: "finale", kind: "ordinary", sequence: 3, startsAt: time("16:20"), visitSeconds: 360, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 },
    ];
    const protectedVisits = structuredClone(input.fixedVisits), result = proposeJointRoutes(input);
    expect(result.valid, JSON.stringify(result.conflicts)).toBe(true);
    expect(result.metrics.after.unvisitedPortals).toEqual([]);
    expect(result.metrics.after.totalOrdinaryVisits).toBe(1);
    expect(result.metrics.after.byPortal.find(portal => portal.portalId === "house-0")?.visits).toBe(1);
    expect(result.metrics.after.byPortal).toHaveLength(2);
    expect(input.fixedVisits).toEqual(protectedVisits);
    const onlyHistory = structuredClone(input); onlyHistory.fixedVisits = [];
    expect(proposeJointRoutes(onlyHistory).metrics.after.unvisitedPortals).toEqual(["house-0"]);
  });
  it("offers a genuine visit-count tradeoff for a higher minimum house count, without capping that minimum", () => {
    const input = fixture(4, 4), added = input.portals.splice(3, 1)[0];
    input.groups.forEach((group, index) => {
      group.startsAt = new Date(Date.parse(time("17:00")) + index * 900_000).toISOString();
      group.ordinaryStopAt = new Date(Date.parse(group.startsAt) + 720_000).toISOString();
      group.desiredEndAt = null; group.fixedFirstPortalId = "house-0";
    });
    input.portals.filter(portal => !portal.finale).forEach(portal => { portal.windows[0].visitSeconds = 180; });
    input.before = proposeJointRoutes(input).groups;
    activate(input, added); added.windows[0].visitSeconds = 420;
    // A concrete feasible maximum-count reference: three short houses in three
    // groups; the fourth keeps its fixed first and visits the longer new house.
    const reference = structuredClone(input.before), first = reference[0].visits[0], previousFinale = reference[0].visits.at(-1)!;
    const addedAt = new Date(Date.parse(first.startsAt) + first.visitSeconds * 1000).toISOString();
    const finaleAt = new Date(Date.parse(addedAt) + added.windows[0].visitSeconds * 1000).toISOString();
    reference[0].visits = [first, { portalId: added.id, kind: "ordinary", sequence: 2, startsAt: addedAt,
      visitSeconds: 420, bufferSeconds: 0, walkSeconds: 0, walkMeters: 0 }, { ...previousFinale, sequence: 3, startsAt: finaleAt }];
    Object.assign(reference[0], { finaleArrivalAt: finaleAt,
      expectedCompletionAt: new Date(Date.parse(finaleAt) + previousFinale.visitSeconds * 1000).toISOString(),
      finaleChange: { portalId: "finale", previousReservedAt: input.groups[0].finale.reservedAt, proposedReservedAt: finaleAt } });
    expect(validateJointRoutes(input, reference)).toEqual([]);
    const general = { groups: reference, metrics: { after: measureJointRoutes(input, reference) } }, spread = proposeJointRoutes(input, { mode: "portal-spread" });
    expect(spread.valid, JSON.stringify(spread.conflicts)).toBe(true);
    expect(general.metrics.after.totalOrdinaryVisits).toBe(11);
    expect(Math.min(...general.metrics.after.byPortal.map(portal => portal.visits))).toBe(1);
    expect(spread.metrics.after.totalOrdinaryVisits).toBe(10);
    expect(Math.min(...spread.metrics.after.byPortal.map(portal => portal.visits))).toBe(2);
    expect(spread.groups.every(plan => plan.visits[0].portalId === "house-0")).toBe(true);
    expect(spread.optimization.mode).toBe("portal-spread");
    expect(compareJointRouteProposals(input, spread, general, "portal-spread")).toBeGreaterThan(0);
    expect(compareJointRouteProposals(input, general, spread, "general")).toBeGreaterThan(0);
    const relabeled = structuredClone(input); relabeled.needsAnders = true;
    relabeled.groups.reverse(); relabeled.portals.reverse(); relabeled.legs.reverse();
    relabeled.portals.forEach(portal => { portal.worldSlug = "arbitrary-preference"; });
    expect(proposeJointRoutes(relabeled, { mode: "portal-spread" })).toEqual(spread);
    input.groups.forEach(group => { group.ordinaryStopAt = new Date(Date.parse(group.startsAt) + 3600_000).toISOString(); });
    const expanded = proposeJointRoutes(input, { mode: "portal-spread" });
    expect(expanded.valid).toBe(true);
    expect(expanded.metrics.after.totalOrdinaryVisits).toBe(16);
    expect(expanded.metrics.after.byPortal.every(portal => portal.visits === 4)).toBe(true);
  });
  it("keeps actual65-minute walking and show-completion boundaries in the spread mode", () => {
    const input = policy65(1, 3); input.groups[0].fixedFirstPortalId = "house-0";
    for (const leg of input.legs) leg.seconds = leg.from === leg.to ? 0 : leg.to === "portal:finale" ? 1200 : 900;
    const spread = proposeJointRoutes(input, { mode: "portal-spread" });
    expect(spread.valid, JSON.stringify(spread.conflicts)).toBe(true);
    expect(spread.metrics.after.totalOrdinaryVisits).toBe(3);
    expect(spread.metrics.after.walkingSeconds).toBe(3900);
    expect(spread.groups[0].visits.at(-1)?.walkSeconds).toBe(1200);
    expect(spread.groups[0].expectedCompletionAt).toBe(time("20:30"));
    expect(validateJointRoutes(input, spread.groups)).toEqual([]);
    input.legs.filter(leg => leg.to === "portal:finale").forEach(leg => { leg.seconds = 1201; });
    const overBudget = structuredClone(spread.groups); overBudget[0].visits.at(-1)!.walkSeconds = 1201;
    expect(validateJointRoutes(input, overBudget).some(diagnostic => diagnostic.code === "WALKING_BUDGET")).toBe(true);
    const adjusted = proposeJointRoutes(input, { mode: "portal-spread" });
    expect(adjusted.valid, JSON.stringify(adjusted.conflicts)).toBe(true);
    expect(adjusted.metrics.after.totalOrdinaryVisits).toBe(2);
    expect(adjusted.metrics.after.walkingSeconds).toBeLessThanOrEqual(3900);
  });
});
