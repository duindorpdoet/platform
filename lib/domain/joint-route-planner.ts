import { createHash } from "node:crypto";

/** An explicit proposal shares one physical calendar. It never applies or publishes itself. */
export type JointRouteWindow = {
  opensAt: string; arrivalClosesAt: string; closesAt: string;
  visitSeconds: number; bufferSeconds: number; maxGroups: number;
  maxChildren: number; maxTotalChildren: number; headwaySeconds: number;
  maxConcurrentChildren?: number | null;
};
export type JointRoutePortal = {
  id: string; code: string; name: string; nodeId: string; worldSlug: string;
  physicalId?: string;
  finale: boolean; accessibilityStatus: "unknown" | "step_free" | "not_step_free";
  windows: JointRouteWindow[];
};
export type JointRouteGroup = {
  id: string; code: string; childCount: number; startNodeId: string; startsAt: string;
  startConfirmed: boolean; ordinaryStopAt: string; desiredEndAt: string | null;
  maxOrdinaryVisits: number | null; requiresStepFree: boolean; accessibilityNeedsReview: boolean;
  fixedFirstPortalId: string | null; excludedPortalIds: string[];
  finale: { portalId: string; reservedAt: string | null; reservationValid: boolean; latestArrivalAt: string };
};
export type JointRouteVisit = {
  id?: string; portalId: string; kind: "ordinary" | "finale" | "start"; sequence: number;
  startsAt: string; visitSeconds: number; bufferSeconds: number; walkSeconds: number; walkMeters: number;
  /** Actual opening/headway/capacity delay, never fabricated to fill an evening. */
  waitSeconds?: number;
};
export type JointRouteDiagnostic = {
  code: string; severity: "block" | "warning"; message: string; groupId?: string; portalId?: string;
};
export type JointRouteGroupPlan = {
  groupId: string; startsAt: string; desiredEndAt?: string | null; finaleArrivalAt: string | null;
  expectedCompletionAt: string | null; visits: JointRouteVisit[]; diagnostics: JointRouteDiagnostic[];
};
export type JointRouteInput = {
  eventId: string; sourceHash: string; boardHash: string; policyVersion: string;
  maxGroupOverrunSeconds: number; maxLegWalkingSeconds: number; maxTotalWalkingSeconds: number;
  needsAnders: boolean; groups: JointRouteGroup[]; portals: JointRoutePortal[];
  legs: Array<{ from: string; to: string; seconds: number; meters: number }>;
  fixedVisits: Array<JointRouteVisit & { groupId: string; children: number; physicalId?: string }>;
  before: JointRouteGroupPlan[];
  diagnostics?: JointRouteDiagnostic[];
};
export type JointRouteMetrics = {
  groups: number; totalOrdinaryVisits: number; minOrdinaryVisits: number; meanOrdinaryVisits: number;
  maxOrdinaryVisits: number; zeroVisitGroups: number; walkingSeconds: number; waitingSeconds: number;
  absoluteEndDeviationSeconds: number; overrunSeconds: number; administrativeStarts: number;
  byGroup: Array<{ groupId: string; ordinaryVisits: number; walkingSeconds: number; waitingSeconds: number;
    endDeviationSeconds: number | null; finaleArrivalAt: string | null; unallocatedBeforeFinaleSeconds: number }>;
  byPortal: Array<{ portalId: string; visits: number; usableOpenSeconds: number; visitsPerOpenHour: number;
    firstArrivalAt: string | null; firstDelaySeconds: number | null; largestGapSeconds: number;
    quarterHourBuckets: Array<{ startsAt: string; visits: number }>; explanation: string | null }>;
};
export type JointRouteProposal = {
  sourceHash: string; boardHash: string; proposalHash: string; policyVersion: string; valid: boolean;
  groups: JointRouteGroupPlan[]; conflicts: JointRouteDiagnostic[];
  metrics: { before: JointRouteMetrics; after: JointRouteMetrics };
  work: { candidateEvaluations: number; variants: number; pairReplans: number; exhausted: boolean };
};

export const JOINT_ROUTE_SEARCH_LIMITS = { variants: 6, pairReplans: 24, candidateEvaluations: 200_000 } as const;
// PostgreSQL keeps microseconds; Date.parse alone discards the final three
// digits and can move a fixed appointment or put an arrival before opening.
const at = (value: string) => {
  const fraction = /\.(\d+)(?:Z|[+-]\d{2}(?::?\d{2})?)$/i.exec(value)?.[1] ?? "";
  const micros = Date.parse(value) * 1000 + Number(fraction.slice(3, 6).padEnd(3, "0"));
  return Number.isSafeInteger(micros) ? micros / 1_000_000 : NaN;
};
const iso = (value: number) => {
  const micros = Math.round(value * 1_000_000), millis = Math.floor(micros / 1000);
  const remainder = micros - millis * 1000, formatted = new Date(millis).toISOString();
  return remainder ? `${formatted.slice(0, -1)}${String(remainder).padStart(3, "0")}Z` : formatted;
};
const compareId = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
type Occupancy = { groupId: string; portalId: string; start: number; end: number; children: number };
type Candidate = { portal: JointRoutePortal; window: JointRouteWindow; start: number; walk: { seconds: number; meters: number }; wait: number; cost: number };
type State = { group: JointRouteGroup; node: string; cursor: number; walking: number; visits: JointRouteVisit[]; chosen: Set<string>; done: boolean };

function physical(visit: JointRouteVisit) { return visit.kind !== "start"; }
function occupancy(visit: JointRouteVisit, groupId: string, children: number, physicalId = visit.portalId): Occupancy {
  return { groupId, children, portalId: physicalId, start: at(visit.startsAt), end: at(visit.startsAt) + visit.visitSeconds + visit.bufferSeconds };
}
function matchingWindow(portal: JointRoutePortal, start: number, seconds: number, buffer: number, children: number) {
  return portal.windows.find(window => start >= at(window.opensAt)
    && (portal.finale ? start <= at(window.arrivalClosesAt) : start < at(window.arrivalClosesAt))
    && start + seconds + buffer <= at(window.closesAt)
    && seconds >= window.visitSeconds && buffer >= window.bufferSeconds && children <= window.maxChildren);
}

/** Capacity is checked at every half-open occupancy boundary, independently of headway. */
function fits(calendar: Occupancy[], portal: JointRoutePortal, group: JointRouteGroup, start: number, window: JointRouteWindow) {
  const other = calendar.filter(visit => visit.portalId === (portal.physicalId ?? portal.id) && visit.groupId !== group.id);
  if (other.some(visit => Math.abs(visit.start - start) < window.headwaySeconds)) return false;
  const received = new Map<string, number>();
  for (const visit of other) received.set(visit.groupId, Math.max(received.get(visit.groupId) ?? 0, visit.children));
  if ([...received.values()].reduce((sum, children) => sum + children, group.childCount) > window.maxTotalChildren) return false;
  const end = start + window.visitSeconds + window.bufferSeconds;
  for (const tick of [start, ...other.filter(visit => visit.start >= start && visit.start < end).map(visit => visit.start)]) {
    const simultaneous = new Map<string, number>();
    for (const visit of other.filter(visit => visit.start <= tick && visit.end > tick)) simultaneous.set(visit.groupId, Math.max(simultaneous.get(visit.groupId) ?? 0, visit.children));
    if (simultaneous.size >= window.maxGroups || window.maxConcurrentChildren != null
      && [...simultaneous.values()].reduce((sum, children) => sum + children, group.childCount) > window.maxConcurrentChildren) return false;
  }
  return group.childCount <= window.maxChildren;
}

function earliest(calendar: Occupancy[], portal: JointRoutePortal, group: JointRouteGroup, reachable: number, latest: number) {
  const other = calendar.filter(visit => visit.portalId === (portal.physicalId ?? portal.id) && visit.groupId !== group.id);
  for (const window of [...portal.windows].sort((a, b) => at(a.opensAt) - at(b.opensAt))) {
    let start = Math.max(reachable, at(window.opensAt));
    for (let tries = 0; tries <= other.length * 2 + 2; tries++) {
      if (start > latest || (portal.finale ? start > at(window.arrivalClosesAt) : start >= at(window.arrivalClosesAt))
        || start + window.visitSeconds + window.bufferSeconds > at(window.closesAt) || group.childCount > window.maxChildren) break;
      if (fits(calendar, portal, group, start, window)) return { start, window };
      const future = other.flatMap(visit => [visit.start + window.headwaySeconds, visit.end]).filter(tick => tick > start);
      if (!future.length) break;
      start = Math.min(...future);
    }
  }
  return null;
}

export function measureJointRoutes(input: JointRouteInput, plans: JointRouteGroupPlan[]): JointRouteMetrics {
  const groupById = new Map(input.groups.map(group => [group.id, group]));
  const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
  const byGroup = plans.map(plan => {
    const group = groupById.get(plan.groupId);
    const ordinary = plan.visits.filter(visit => visit.kind === "ordinary");
    const last = ordinary.at(-1);
    const from = last ? `portal:${last.portalId}` : group?.startNodeId;
    const finaleLeg = group && from ? legs.get(`${from}|portal:${group.finale.portalId}`) : undefined;
    const reachable = last ? at(last.startsAt) + last.visitSeconds + (finaleLeg?.seconds ?? 0) : at(plan.startsAt) + (finaleLeg?.seconds ?? 0);
    let node = group?.startNodeId, walkingSeconds = 0;
    for (const visit of [...plan.visits].filter(physical).sort((a, b) => a.sequence - b.sequence)) {
      walkingSeconds += node ? legs.get(`${node}|portal:${visit.portalId}`)?.seconds ?? visit.walkSeconds : visit.walkSeconds;
      node = `portal:${visit.portalId}`;
    }
    return { groupId: plan.groupId, ordinaryVisits: ordinary.length,
      walkingSeconds,
      waitingSeconds: plan.visits.reduce((sum, visit) => sum + (visit.waitSeconds ?? 0), 0),
      endDeviationSeconds: group?.desiredEndAt && plan.expectedCompletionAt ? at(plan.expectedCompletionAt) - at(group.desiredEndAt) : null,
      finaleArrivalAt: plan.finaleArrivalAt,
      unallocatedBeforeFinaleSeconds: plan.finaleArrivalAt ? Math.max(0, at(plan.finaleArrivalAt) - reachable) : 0 };
  }).sort((a, b) => compareId(a.groupId, b.groupId));
  const portalById = new Map(input.portals.map(portal => [portal.id, portal]));
  const physicalId = (id: string) => portalById.get(id)?.physicalId ?? id;
  const physicalPortals = [...new Map([...input.portals].sort((a, b) => compareId(b.id, a.id)).map(portal => [physicalId(portal.id), portal])).values()];
  const byPortal = physicalPortals.filter(portal => !portal.finale).map(portal => {
    const visits = plans.flatMap(plan => plan.visits.filter(visit => visit.kind === "ordinary" && physicalId(visit.portalId) === physicalId(portal.id))).sort((a, b) => at(a.startsAt) - at(b.startsAt));
    // Only demand that can still reach the reserved finale defines a usable evening.
    const possible = input.groups.filter(group => !group.excludedPortalIds.some(id => physicalId(id) === physicalId(portal.id))
      && (!(group.requiresStepFree || group.accessibilityNeedsReview) || portal.accessibilityStatus === "step_free"));
    const rawSpans = possible.flatMap(group => portal.windows.flatMap(window => {
      const incoming = legs.get(`${group.startNodeId}|${portal.nodeId}`), outgoing = legs.get(`${portal.nodeId}|portal:${group.finale.portalId}`);
      if (!incoming || !outgoing || !group.finale.reservedAt || group.childCount > window.maxChildren
        || incoming.seconds > input.maxLegWalkingSeconds || outgoing.seconds > input.maxLegWalkingSeconds
        || incoming.seconds + outgoing.seconds > input.maxTotalWalkingSeconds) return [];
      const start = Math.max(at(window.opensAt), at(group.startsAt) + incoming.seconds);
      const end = Math.min(at(window.arrivalClosesAt), at(window.closesAt) - window.visitSeconds - window.bufferSeconds,
        at(group.ordinaryStopAt) - window.visitSeconds, at(group.finale.reservedAt) - outgoing.seconds - window.visitSeconds);
      return end > start ? [{ start, end }] : [];
    })).sort((a, b) => a.start - b.start || a.end - b.end);
    const spans: Array<{ start: number; end: number }> = [];
    for (const span of rawSpans) { const prior = spans.at(-1); if (prior && span.start <= prior.end) prior.end = Math.max(prior.end, span.end); else spans.push({ ...span }); }
    const usableOpenSeconds = spans.reduce((sum, span) => sum + span.end - span.start, 0);
    const bins = new Map<number, number>();
    for (const visit of visits) { const key = Math.floor(at(visit.startsAt) / 900) * 900; bins.set(key, (bins.get(key) ?? 0) + 1); }
    const gaps = spans.map(span => {
      let cursor = span.start, largest = 0;
      for (const visit of visits) {
        const start = Math.min(span.end, at(visit.startsAt)), end = at(visit.startsAt) + visit.visitSeconds + visit.bufferSeconds;
        if (end <= span.start || start >= span.end) continue;
        largest = Math.max(largest, start - cursor); cursor = Math.max(cursor, Math.min(span.end, end));
      }
      return Math.max(largest, span.end - cursor);
    });
    return { portalId: portal.id, visits: visits.length, usableOpenSeconds,
      visitsPerOpenHour: usableOpenSeconds ? visits.length * 3600 / usableOpenSeconds : 0,
      firstArrivalAt: visits[0]?.startsAt ?? null,
      firstDelaySeconds: visits[0] && spans.length ? Math.max(0, at(visits[0].startsAt) - Math.min(...spans.map(span => span.start))) : null,
      largestGapSeconds: Math.max(0, ...gaps),
      quarterHourBuckets: [...bins].sort(([a], [b]) => a - b).map(([startsAt, count]) => ({ startsAt: iso(startsAt), visits: count })),
      explanation: visits.length ? null : usableOpenSeconds ? `Geen bezoek in dit begrensde voorstel; ${possible.length} groepen hebben mogelijk passende toegankelijkheid. Controleer herverdeling binnen de vaste afspraken en kalendercapaciteit.` : "Geen bereikbaar ontvangstmoment binnen start, gewone stop, toegankelijkheid, loopbudget en vaste finaleafspraken." };
  }).sort((a, b) => compareId(a.portalId, b.portalId));
  const counts = byGroup.map(group => group.ordinaryVisits);
  return { groups: plans.length, totalOrdinaryVisits: counts.reduce((sum, count) => sum + count, 0),
    minOrdinaryVisits: counts.length ? Math.min(...counts) : 0,
    meanOrdinaryVisits: counts.length ? counts.reduce((sum, count) => sum + count, 0) / counts.length : 0,
    maxOrdinaryVisits: Math.max(0, ...counts), zeroVisitGroups: counts.filter(count => !count).length,
    walkingSeconds: byGroup.reduce((sum, group) => sum + group.walkingSeconds, 0),
    waitingSeconds: byGroup.reduce((sum, group) => sum + group.waitingSeconds + group.unallocatedBeforeFinaleSeconds, 0),
    absoluteEndDeviationSeconds: byGroup.reduce((sum, group) => sum + Math.abs(group.endDeviationSeconds ?? 0), 0),
    overrunSeconds: byGroup.reduce((sum, group) => sum + Math.max(0, group.endDeviationSeconds ?? 0), 0),
    administrativeStarts: plans.reduce((sum, plan) => sum + plan.visits.filter(visit => visit.kind === "start").length, 0), byGroup, byPortal };
}

/** A language-independent digest payload; SQL uses the same sorted newline fields. */
export function jointRouteProposalDigestText(sourceHash: string, boardHash: string, plans: JointRouteGroupPlan[]) {
  return [sourceHash, boardHash, ...[...plans].sort((a, b) => compareId(a.groupId, b.groupId)).flatMap(plan => [
    plan.groupId, plan.startsAt, ...[...plan.visits].sort((a, b) => a.sequence - b.sequence).flatMap(visit => [
      visit.portalId, visit.kind, visit.startsAt, String(visit.visitSeconds), String(visit.bufferSeconds),
    ]),
  ])].join("\n");
}

/** Independently checks the finished plan, including every shared capacity boundary. */
export function validateJointRoutes(input: JointRouteInput, plans: JointRouteGroupPlan[]): JointRouteDiagnostic[] {
  const conflicts: JointRouteDiagnostic[] = [];
  const portals = new Map(input.portals.map(portal => [portal.id, portal]));
  const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
  const physicalId = (id: string) => portals.get(id)?.physicalId ?? id;
  const calendar = [...input.fixedVisits.filter(physical).map(visit => occupancy(visit, visit.groupId, visit.children, visit.physicalId ?? physicalId(visit.portalId))),
    ...plans.flatMap(plan => plan.visits.filter(physical).map(visit => occupancy(visit, plan.groupId, input.groups.find(group => group.id === plan.groupId)?.childCount ?? 0, physicalId(visit.portalId))))];
  for (const group of input.groups) if (plans.filter(plan => plan.groupId === group.id).length !== 1) conflicts.push({ code: "GROUP_PLAN_REQUIRED", severity: "block", groupId: group.id, message: "Iedere te plannen groep heeft precies één gezamenlijk gecontroleerde route nodig." });
  for (const plan of plans) {
    const group = input.groups.find(group => group.id === plan.groupId);
    if (!group) { conflicts.push({ code: "UNKNOWN_GROUP", severity: "block", groupId: plan.groupId, message: "Dit voorstel bevat een onbekende groep." }); continue; }
    const problem = (code: string, message: string, portalId?: string) => conflicts.push({ code, message, severity: "block", groupId: group.id, portalId });
    if (at(plan.startsAt) !== at(group.startsAt)) problem("START_APPOINTMENT_CHANGED", "De opgeslagen startafspraak moet behouden blijven.");
    let node = group.startNodeId, cursor = at(group.startsAt), walking = 0;
    const visited = new Set(group.excludedPortalIds.map(physicalId));
    const ordered = [...plan.visits].filter(physical).sort((a, b) => a.sequence - b.sequence);
    for (const visit of ordered) {
      const portal = portals.get(visit.portalId);
      if (!portal) { problem("PORTAL_UNAVAILABLE", "Deze poort is niet beschikbaar in de actuele planning.", visit.portalId); continue; }
      const start = at(visit.startsAt), leg = legs.get(`${node}|${portal.nodeId}`);
      if (!leg || start < cursor + leg.seconds) problem("TRAVEL_TIME", "Tussen de bezoeken is onvoldoende echte looptijd.", portal.id);
      walking += leg?.seconds ?? 0;
      if (leg && leg.seconds > input.maxLegWalkingSeconds || walking > input.maxTotalWalkingSeconds) problem("WALKING_BUDGET", "Deze route overschrijdt het loopbudget.", portal.id);
      if (visited.has(physicalId(portal.id))) problem("DUPLICATE_PHYSICAL_VISIT", "Een fysiek huis mag voor deze groep of bestaande kindhistorie niet opnieuw worden bezocht.", portal.id);
      visited.add(physicalId(portal.id));
      if ((group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free") problem(group.accessibilityNeedsReview && portal.finale ? "ACCESSIBILITY_REVIEW_REQUIRED" : "ACCESSIBILITY_UNSUITABLE",
        group.accessibilityNeedsReview && portal.finale ? "Controleer de kindbehoefte of bevestig de toegankelijkheid van de finale voordat dit voorstel wordt toegepast." : "De poort heeft geen bevestigde drempelvrije ontvangst.", portal.id);
      const window = matchingWindow(portal, start, visit.visitSeconds, visit.bufferSeconds, group.childCount);
      if (!window) problem("OPENING_WINDOW", "Aankomst, bezoek en buffer passen niet binnen de effectieve poortopening.", portal.id);
      else {
        // Validate exact proposed duration, not just a shorter default service.
        const proposedWindow = { ...window, visitSeconds: visit.visitSeconds, bufferSeconds: visit.bufferSeconds };
        if (!fits(calendar, portal, group, start, proposedWindow)) problem("ARRIVAL_OR_CAPACITY_CONFLICT", "Aankomstafstand of fysieke groeps-/kindercapaciteit is overschreden.", portal.id);
      }
      if (visit.kind === "ordinary" && start + visit.visitSeconds > at(group.ordinaryStopAt)) problem("ORDINARY_STOP_LIMIT", "Het gewone bezoek eindigt na de expliciete groeps- of avondgrens.", portal.id);
      if (visit.kind === "finale") {
        if (portal.id !== group.finale.portalId || !group.finale.reservedAt || start !== at(group.finale.reservedAt)) problem("FINALE_APPOINTMENT_CHANGED", "De finale moet op de opgeslagen gereserveerde afspraak blijven.", portal.id);
        if (start > at(group.finale.latestArrivalAt) || group.desiredEndAt && start + visit.visitSeconds > at(group.desiredEndAt) + input.maxGroupOverrunSeconds) problem("GROUP_COMPLETION_LIMIT", "De show moet binnen de uiterste groepsafronding en het finalevenster eindigen.", portal.id);
        if (!plan.finaleArrivalAt || at(plan.finaleArrivalAt) !== start || !plan.expectedCompletionAt || at(plan.expectedCompletionAt) !== start + visit.visitSeconds) problem("FINALE_TIMING_MISMATCH", "Finale-afspraak en getoonde afronding moeten dezelfde werkelijke tijden gebruiken.", portal.id);
      }
      cursor = start + visit.visitSeconds; node = portal.nodeId;
    }
    if (ordered.filter(visit => visit.kind === "finale").length !== 1 || ordered.at(-1)?.kind !== "finale") problem("FINALE_REQUIRED", "Een geldige route eindigt met precies de gereserveerde finale.");
    if (!ordered.some(visit => visit.kind === "ordinary") && group.maxOrdinaryVisits !== 0) {
      const accessible = input.portals.filter(portal => !portal.finale && (!(group.requiresStepFree || group.accessibilityNeedsReview) || portal.accessibilityStatus === "step_free"));
      const reachable = accessible.filter(portal => legs.has(`${group.startNodeId}|${portal.nodeId}`));
      problem("NO_FEASIBLE_ORDINARY_VISIT", group.accessibilityNeedsReview ? "De behoefte moet nog worden gecontroleerd; geen bevestigd drempelvrij bezoek past veilig binnen de vaste afspraken en gedeelde kalender."
        : !accessible.length && group.requiresStepFree ? "Er is geen bevestigd drempelvrij gewoon huis beschikbaar; controleer de eigen toegankelijkheidsgegevens van de poorten."
          : !reachable.length ? "Er is geen opgeslagen bruikbaar looptraject naar een geschikte gewone poort; controleer de ingangspinnen."
            : `Geen van ${reachable.length} bereikbare geschikte huizen heeft een vrij ontvangstmoment binnen de vaste start-/finaleafspraak en de gewone stopgrens.`);
    }
  }
  return conflicts;
}

/**
 * Six shared-calendar constructions plus bounded pair removal/reinsertion.
 * Comparison is lexicographic: validity, fair visit opportunities, end preferences,
 * house load/gaps, then walking and preservation of already useful concepts.
 */
export function proposeJointRoutes(input: JointRouteInput): JointRouteProposal {
  if (input.groups.length > 60 || input.portals.length > 120 || input.legs.length > 32_400
    || !input.sourceHash || !input.boardHash || new Set(input.groups.map(group => group.id)).size !== input.groups.length
    || input.groups.some(group => !Number.isFinite(at(group.startsAt)) || !Number.isFinite(at(group.ordinaryStopAt)))) throw new Error("INVALID_JOINT_PLANNING_INPUT");
  const groups = [...input.groups].sort((a, b) => compareId(a.id, b.id));
  const portals = [...input.portals].sort((a, b) => compareId(a.id, b.id));
  const portalById = new Map(portals.map(portal => [portal.id, portal]));
  const physicalId = (id: string) => portalById.get(id)?.physicalId ?? id;
  const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
  const work = { candidateEvaluations: 0, variants: 0, pairReplans: 0, exhausted: false };
  const base = input.fixedVisits.filter(physical).map(visit => occupancy(visit, visit.groupId, visit.children, visit.physicalId ?? physicalId(visit.portalId)));
  const finaleVisits = new Map<string, JointRouteVisit>();
  for (const group of groups) {
    const portal = portalById.get(group.finale.portalId), start = group.finale.reservedAt ? at(group.finale.reservedAt) : NaN;
    const window = portal?.windows.find(window => matchingWindow({ ...portal, windows: [window] }, start, window.visitSeconds, window.bufferSeconds, group.childCount));
    if (portal && window && group.finale.reservationValid && start <= at(group.finale.latestArrivalAt)) {
      const visit: JointRouteVisit = { portalId: portal.id, kind: "finale", sequence: 1, startsAt: group.finale.reservedAt!, visitSeconds: window.visitSeconds, bufferSeconds: window.bufferSeconds, walkSeconds: 0, walkMeters: 0 };
      finaleVisits.set(group.id, visit); base.push(occupancy(visit, group.id, group.childCount, physicalId(visit.portalId)));
    }
  }

  function build(subset: JointRouteGroup[], variant: number, reserved: Occupancy[]) {
    const calendar = [...reserved];
    const states: State[] = subset.map(group => ({ group, node: group.startNodeId, cursor: at(group.startsAt), walking: 0, visits: [], chosen: new Set(group.excludedPortalIds.map(physicalId)), done: !finaleVisits.has(group.id) }));
    const rank = (group: JointRouteGroup) => {
      const finaleAt = at(group.finale.reservedAt ?? group.finale.latestArrivalAt);
      const options = portals.filter(portal => !portal.finale && (!(group.requiresStepFree || group.accessibilityNeedsReview) || portal.accessibilityStatus === "step_free") && portal.windows.some(window => window.maxChildren >= group.childCount)).length;
      return variant % 3 === 0 ? finaleAt : variant % 3 === 1 ? options * 86_400 + finaleAt % 86_400 : at(group.startsAt);
    };
    let turns = 0;
    while (states.some(state => !state.done) && turns++ < subset.length * (portals.length + 1)) {
      const state = states.filter(state => !state.done).sort((a, b) => a.visits.length - b.visits.length || rank(a.group) - rank(b.group)
        || (variant % 2 ? compareId(b.group.id, a.group.id) : compareId(a.group.id, b.group.id)))[0];
      const group = state.group;
      if (state.visits.length >= (group.maxOrdinaryVisits ?? portals.length)) { state.done = true; continue; }
      let best: Candidate | null = null;
      for (const portal of portals) {
        if (portal.finale || physicalId(portal.id) === physicalId(group.finale.portalId) || state.chosen.has(physicalId(portal.id))
          || (group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free") continue;
        if (work.candidateEvaluations >= JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations) { work.exhausted = true; break; }
        work.candidateEvaluations++;
        const walk = legs.get(`${state.node}|${portal.nodeId}`), exit = legs.get(`${portal.nodeId}|portal:${group.finale.portalId}`);
        if (!walk || !exit || walk.seconds > input.maxLegWalkingSeconds || exit.seconds > input.maxLegWalkingSeconds
          || state.walking + walk.seconds + exit.seconds > input.maxTotalWalkingSeconds) continue;
        const reachable = state.cursor + walk.seconds;
        const limit = Math.min(at(group.ordinaryStopAt), at(group.finale.reservedAt!) - exit.seconds);
        // Every wait is justified by a real opening, reception interval or occupied service.
        const feasible = earliest(calendar, portal, group, reachable, limit);
        if (!feasible || feasible.start + feasible.window.visitSeconds > limit) continue;
        const wait = feasible.start - reachable;
        const received = calendar.filter(visit => visit.portalId === physicalId(portal.id));
        const unique = new Set(received.map(visit => visit.groupId)).size;
        const hours = Math.max(0.25, portal.windows.reduce((sum, window) => sum + at(window.arrivalClosesAt) - at(window.opensAt), 0) / 3600);
        const sameQuarter = received.filter(visit => Math.floor(visit.start / 900) === Math.floor(feasible.start / 900)).length;
        const anders = input.needsAnders && !state.visits.some(visit => portalById.get(visit.portalId)?.worldSlug === "anders") && portal.worldSlug === "anders";
        const prior = input.before.find(plan => plan.groupId === group.id)?.visits.some(visit => visit.portalId === portal.id);
        const firstChoice = !state.visits.length && group.fixedFirstPortalId === portal.id;
        const cost = walk.seconds * (variant >= 4 ? 1 : 0.5) + wait * 2 + unique / hours * (variant >= 2 ? 420 : 240)
          + sameQuarter * 180 - (!unique ? 600 : 0) - (anders ? 1200 : 0) + (prior ? 0 : 10) - (firstChoice ? 180 : 0);
        if (!best || cost < best.cost || cost === best.cost && compareId(portal.id, best.portal.id) < 0) best = { portal, ...feasible, walk, wait, cost };
      }
      if (!best || work.exhausted) { state.done = true; continue; }
      const visit: JointRouteVisit = { portalId: best.portal.id, kind: "ordinary", sequence: state.visits.length + 1, startsAt: iso(best.start),
        visitSeconds: best.window.visitSeconds, bufferSeconds: best.window.bufferSeconds, walkSeconds: best.walk.seconds, walkMeters: best.walk.meters, waitSeconds: best.wait };
      state.visits.push(visit); state.chosen.add(physicalId(best.portal.id)); state.walking += best.walk.seconds;
      state.cursor = best.start + best.window.visitSeconds; state.node = best.portal.nodeId;
      calendar.push(occupancy(visit, group.id, group.childCount, physicalId(visit.portalId)));
    }
    return states.map(state => {
      const finale = finaleVisits.get(state.group.id), exit = finale && legs.get(`${state.node}|portal:${finale.portalId}`);
      const visits = [...state.visits];
      if (finale && exit && state.cursor + exit.seconds <= at(finale.startsAt)) visits.push({ ...finale, sequence: visits.length + 1, walkSeconds: exit.seconds, walkMeters: exit.meters });
      const diagnostics: JointRouteDiagnostic[] = [];
      if (state.group.accessibilityNeedsReview) diagnostics.push({ code: "ACCESSIBILITY_NEEDS_REVIEW", severity: "warning", groupId: state.group.id,
        message: "Controleer de expliciete toegankelijkheidsbehoefte; een vrije opmerking is geen bewijs. Dit voorstel gebruikt voorlopig alleen bevestigd drempelvrije huizen en wijzigt geen kindgegevens." });
      if (state.group.accessibilityNeedsReview && portalById.get(state.group.finale.portalId)?.accessibilityStatus !== "step_free") diagnostics.push({ code: "ACCESSIBILITY_REVIEW_REQUIRED", severity: "block", groupId: state.group.id, portalId: state.group.finale.portalId,
        message: "Controleer de kindbehoefte of bevestig de toegankelijkheid van de gereserveerde finale. De gewone mogelijkheden zijn berekend, maar onbekende ontvangst is niet als drempelvrij goedgekeurd." });
      if (state.group.fixedFirstPortalId && state.visits[0]?.portalId !== state.group.fixedFirstPortalId && state.group.maxOrdinaryVisits !== 0) diagnostics.push({ code: state.visits.length ? "FIRST_PORTAL_ALTERNATIVE" : "FIXED_FIRST_PORTAL_UNSUITABLE", severity: state.visits.length ? "warning" : "block", groupId: state.group.id, portalId: state.group.fixedFirstPortalId,
        message: "Het gekoppelde eerste huis past niet veilig. De verzamelplek en starttijd blijven gelijk; controleer het voorgestelde passende eerste bezoek." });
      if (state.group.maxOrdinaryVisits === 0) diagnostics.push({ code: "ZERO_VISITS_EXPLICIT", severity: "warning", groupId: state.group.id,
        message: "De opgeslagen bezoeklimiet is nul. Er zijn geen gewone bezoeken verzonnen; controleer deze expliciete keuze als een gewone route gewenst is." });
      const receptionWait = state.visits.reduce((sum, visit) => sum + (visit.waitSeconds ?? 0), 0);
      if (receptionWait > 300) diagnostics.push({ code: "RECEPTION_WAIT", severity: "warning", groupId: state.group.id,
        message: `${Math.ceil(receptionWait / 60)} minuten echte wachttijd vóór ontvangst door poortopening, aankomstafstand of bezetting. Deze tijd is apart geteld en telt niet als bezoektijd.` });
      const priorOrdinary = input.before.find(plan => plan.groupId === state.group.id)?.visits.filter(visit => visit.kind === "ordinary") ?? [];
      if (state.visits.length < priorOrdinary.length) {
        const lostSeconds = Math.max(0, priorOrdinary.reduce((sum, visit) => sum + visit.visitSeconds, 0) - state.visits.reduce((sum, visit) => sum + visit.visitSeconds, 0));
        diagnostics.push({ code: "ORDINARY_VISITS_REDUCED", severity: "warning", groupId: state.group.id,
          message: `${priorOrdinary.length - state.visits.length} minder gewone bezoeken en ${Math.ceil(lostSeconds / 60)} minuten minder bezoektijd dan het oude bord. De vaste finale, echte poortvensters, toegankelijkheid en gedeelde ontvangstcapaciteit begrenzen de route. De begrensde herverdeling vond geen beter gezamenlijk geldig alternatief.` });
      }
      if (!finale) diagnostics.push({ code: "FINALE_RESERVATION_INVALID", severity: "block", groupId: state.group.id, portalId: state.group.finale.portalId,
        message: "De opgeslagen finaleafspraak past niet in de eigen poortopening, laatste aankomst of fysieke sluiting. Corrigeer deze afspraak via een apart beoordeeld voorstel." });
      const finaleGap = finale && exit ? at(finale.startsAt) - state.cursor - exit.seconds : 0;
      if (finaleGap > 600) diagnostics.push({ code: "UNALLOCATED_BEFORE_FINALE", severity: "warning", groupId: state.group.id,
        message: `${Math.ceil(finaleGap / 60)} minuten blijven over vóór de vaste finale. Er zijn geen fictieve bezoeken of verlengde bezoeken toegevoegd; beoordeel eventueel een andere finaleplek via de bestaande wijzigingsflow.` });
      return { groupId: state.group.id, startsAt: state.group.startsAt, desiredEndAt: state.group.desiredEndAt, finaleArrivalAt: finale && visits.at(-1)?.kind === "finale" ? finale.startsAt : null,
        expectedCompletionAt: finale && visits.at(-1)?.kind === "finale" ? iso(at(finale.startsAt) + finale.visitSeconds) : null, visits, diagnostics };
    });
  }

  const score = (plans: JointRouteGroupPlan[]) => {
    const metrics = measureJointRoutes(input, plans);
    return [-validateJointRoutes(input, plans).length, ...metrics.byGroup.map(group => group.ordinaryVisits).sort((a, b) => a - b),
      -(metrics.absoluteEndDeviationSeconds + metrics.overrunSeconds * 0.25),
      -metrics.byPortal.reduce((sum, portal) => sum + portal.largestGapSeconds, 0),
      -metrics.byPortal.reduce((sum, portal) => sum + portal.visitsPerOpenHour ** 2, 0),
      -metrics.waitingSeconds, -metrics.walkingSeconds];
  };
  function better(next: JointRouteGroupPlan[], prior: JointRouteGroupPlan[]) {
    const a = score(next), b = score(prior);
    for (let index = 0; index < a.length; index++) if (a[index] !== b[index]) return a[index] > b[index];
    return JSON.stringify(next) < JSON.stringify(prior);
  }
  let best: JointRouteGroupPlan[] = [];
  for (let variant = 0; variant < JOINT_ROUTE_SEARCH_LIMITS.variants; variant++) {
    const plans = build(groups, variant, base); work.variants++;
    if (!best.length || better(plans, best)) best = plans;
    if (work.exhausted) break;
  }
  const pairOrder = [...groups].sort((a, b) => {
    const visits = (id: string) => best.find(plan => plan.groupId === id)?.visits.filter(visit => visit.kind === "ordinary").length ?? 0;
    return visits(a.id) - visits(b.id) || compareId(a.id, b.id);
  });
  for (let first = 0; first < pairOrder.length && !work.exhausted; first++) {
    for (let second = pairOrder.length - 1; second > first && work.pairReplans < JOINT_ROUTE_SEARCH_LIMITS.pairReplans && !work.exhausted; second--) {
      const pair = [pairOrder[first], pairOrder[second]], ids = new Set(pair.map(group => group.id));
      const others = best.filter(plan => !ids.has(plan.groupId));
      const reserved = [...base, ...others.flatMap(plan => plan.visits.filter(visit => visit.kind === "ordinary").map(visit => occupancy(visit, plan.groupId, groups.find(group => group.id === plan.groupId)!.childCount, physicalId(visit.portalId))))];
      const replacement = build(pair, work.pairReplans % JOINT_ROUTE_SEARCH_LIMITS.variants, reserved);
      const candidate = [...others, ...replacement].sort((a, b) => compareId(a.groupId, b.groupId));
      work.pairReplans++;
      if (better(candidate, best)) best = candidate;
    }
  }
  best.sort((a, b) => compareId(a.groupId, b.groupId));
  const conflicts = [...new Map([...(input.diagnostics ?? []), ...best.flatMap(plan => plan.diagnostics), ...validateJointRoutes(input, best)]
    .map(diagnostic => [`${diagnostic.code}|${diagnostic.groupId ?? ""}|${diagnostic.portalId ?? ""}`, diagnostic])).values()];
  if (work.exhausted) conflicts.push({ code: "BOUNDED_SEARCH_LIMIT", severity: "warning", message: "De begrensde zoektocht is afgerond met het beste gevonden gecontroleerde voorstel." });
  const before = measureJointRoutes(input, input.before), after = measureJointRoutes(input, best);
  // Administrative gathering appointments are preserved separately by the apply command.
  after.administrativeStarts = before.administrativeStarts;
  return { sourceHash: input.sourceHash, boardHash: input.boardHash, policyVersion: input.policyVersion,
    proposalHash: createHash("sha256").update(jointRouteProposalDigestText(input.sourceHash, input.boardHash, best)).digest("hex"),
    valid: !conflicts.some(conflict => conflict.severity === "block"), groups: best, conflicts,
    metrics: { before, after }, work };
}
