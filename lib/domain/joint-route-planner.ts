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
  finaleChange?: { portalId: string; previousReservedAt: string | null; proposedReservedAt: string };
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
  receptionWaitingSeconds: number; unallocatedBeforeFinaleSeconds: number; longestWaitSeconds: number; unvisitedPortals: string[];
  byGroup: Array<{ groupId: string; ordinaryVisits: number; walkingSeconds: number; waitingSeconds: number;
    receptionWaitingSeconds: number; longestWaitSeconds: number;
    endDeviationSeconds: number | null; finaleArrivalAt: string | null; unallocatedBeforeFinaleSeconds: number }>;
  byPortal: Array<{ portalId: string; visits: number; usableOpenSeconds: number; visitsPerOpenHour: number;
    firstArrivalAt: string | null; firstDelaySeconds: number | null; largestGapSeconds: number;
    quarterHourBuckets: Array<{ startsAt: string; visits: number }>; explanation: string | null }>;
};
export type JointRouteProposal = {
  sourceHash: string; boardHash: string; proposalHash: string; policyVersion: string; valid: boolean;
  groups: JointRouteGroupPlan[]; conflicts: JointRouteDiagnostic[];
  metrics: { before: JointRouteMetrics; after: JointRouteMetrics };
  work: { candidateEvaluations: number; variants: number; pairReplans: number; routeRepairs: number; exhausted: boolean };
  walkingPolicy: { maxOrdinaryLegSeconds: number; maxTotalSeconds: number; finaleLegLimitSeconds: null };
};

export const JOINT_ROUTE_SEARCH_LIMITS = { variants: 8, pairReplans: 24, routeRepairs: 2400, repairsPerGroupPass: 48, candidateEvaluations: 200_000 } as const;
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
    && seconds === window.visitSeconds && buffer === window.bufferSeconds && children <= window.maxChildren);
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

function receptionWaiting(input: JointRouteInput, plan: JointRouteGroupPlan, legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]))) {
  const group = input.groups.find(group => group.id === plan.groupId);
  let node = group?.startNodeId, cursor = at(plan.startsAt), total = 0, longest = 0;
  for (const visit of [...plan.visits].filter(physical).sort((a, b) => a.sequence - b.sequence)) {
    const portalNode = `portal:${visit.portalId}`;
    const leg = legs.get(`${node}|${portalNode}`);
    const wait = leg ? Math.max(0, at(visit.startsAt) - cursor - leg.seconds) : visit.waitSeconds ?? 0;
    if (visit.kind === "ordinary") { total += wait; longest = Math.max(longest, wait); }
    node = portalNode; cursor = at(visit.startsAt) + visit.visitSeconds;
  }
  return { total, longest };
}

export function measureJointRoutes(input: JointRouteInput, plans: JointRouteGroupPlan[]): JointRouteMetrics {
  const groupById = new Map(input.groups.map(group => [group.id, group]));
  const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
  const portalById = new Map(input.portals.map(portal => [portal.id, portal]));
  const physicalId = (id: string) => portalById.get(id)?.physicalId ?? id;
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
    const waiting = receptionWaiting(input, plan, legs);
    return { groupId: plan.groupId, ordinaryVisits: new Set(ordinary.map(visit => physicalId(visit.portalId))).size,
      walkingSeconds,
      // Reconstruct real waits for old planboard rows too; they have no waitSeconds.
      waitingSeconds: waiting.total,
      receptionWaitingSeconds: waiting.total,
      longestWaitSeconds: Math.max(waiting.longest, plan.finaleArrivalAt ? Math.max(0, at(plan.finaleArrivalAt) - reachable) : 0),
      endDeviationSeconds: group?.desiredEndAt && plan.expectedCompletionAt ? at(plan.expectedCompletionAt) - at(group.desiredEndAt) : null,
      finaleArrivalAt: plan.finaleArrivalAt,
      unallocatedBeforeFinaleSeconds: plan.finaleArrivalAt ? Math.max(0, at(plan.finaleArrivalAt) - reachable) : 0 };
  }).sort((a, b) => compareId(a.groupId, b.groupId));
  const physicalPortals = [...new Map([...input.portals].sort((a, b) => compareId(b.id, a.id)).map(portal => [physicalId(portal.id), portal])).values()];
  const byPortal = physicalPortals.filter(portal => !portal.finale).map(portal => {
    const visits = plans.flatMap(plan => [...plan.visits].filter(visit => visit.kind === "ordinary" && physicalId(visit.portalId) === physicalId(portal.id))
      .sort((a, b) => at(a.startsAt) - at(b.startsAt)).slice(0, 1)).sort((a, b) => at(a.startsAt) - at(b.startsAt));
    // A real final journey has no leg limit. The separate total walking budget
    // and the actual final window/group deadline still apply.
    const possible = input.groups.filter(group => !group.excludedPortalIds.some(id => physicalId(id) === physicalId(portal.id))
      && (!(group.requiresStepFree || group.accessibilityNeedsReview) || portal.accessibilityStatus === "step_free"));
    const rawSpans = possible.flatMap(group => portal.windows.flatMap(window => {
      const incoming = legs.get(`${group.startNodeId}|${portal.nodeId}`), outgoing = legs.get(`${portal.nodeId}|portal:${group.finale.portalId}`);
      if (!incoming || !outgoing || group.childCount > window.maxChildren
        || incoming.seconds > input.maxLegWalkingSeconds
        || incoming.seconds + outgoing.seconds > input.maxTotalWalkingSeconds) return [];
      const finalPortal = portalById.get(group.finale.portalId);
      const finalEnds = finalPortal?.windows.filter(finalWindow => group.childCount <= finalWindow.maxChildren).map(finalWindow => Math.min(
        at(finalWindow.arrivalClosesAt), at(finalWindow.closesAt) - finalWindow.visitSeconds - finalWindow.bufferSeconds,
        at(group.finale.latestArrivalAt), group.desiredEndAt ? at(group.desiredEndAt) + input.maxGroupOverrunSeconds - finalWindow.visitSeconds : Infinity));
      const latestFinal = Math.max(-Infinity, ...(finalEnds ?? []));
      const start = Math.max(at(window.opensAt), at(group.startsAt) + incoming.seconds);
      const end = Math.min(at(window.arrivalClosesAt), at(window.closesAt) - window.visitSeconds - window.bufferSeconds,
        at(group.ordinaryStopAt) - window.visitSeconds, latestFinal - outgoing.seconds - window.visitSeconds);
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
      explanation: visits.length ? null : usableOpenSeconds ? `Geen bezoek in dit begrensde voorstel; ${possible.length} groepen hebben mogelijk passende toegankelijkheid. Geen beter gezamenlijk alternatief gevonden; onmogelijkheid is niet bewezen.` : "Geen rechtstreeks bereikbaar ontvangstmoment binnen start, gewone stop, toegankelijkheid, het aparte totale loopbudget en het effectieve finalevenster. Een route via andere huizen is hiermee niet uitgesloten." };
  }).sort((a, b) => compareId(a.portalId, b.portalId));
  const counts = byGroup.map(group => group.ordinaryVisits);
  return { groups: plans.length, totalOrdinaryVisits: counts.reduce((sum, count) => sum + count, 0),
    minOrdinaryVisits: counts.length ? Math.min(...counts) : 0,
    meanOrdinaryVisits: counts.length ? counts.reduce((sum, count) => sum + count, 0) / counts.length : 0,
    maxOrdinaryVisits: Math.max(0, ...counts), zeroVisitGroups: counts.filter(count => !count).length,
    walkingSeconds: byGroup.reduce((sum, group) => sum + group.walkingSeconds, 0),
    waitingSeconds: byGroup.reduce((sum, group) => sum + group.waitingSeconds + group.unallocatedBeforeFinaleSeconds, 0),
    receptionWaitingSeconds: byGroup.reduce((sum, group) => sum + group.waitingSeconds, 0),
    unallocatedBeforeFinaleSeconds: byGroup.reduce((sum, group) => sum + group.unallocatedBeforeFinaleSeconds, 0),
    longestWaitSeconds: Math.max(0, ...byGroup.map(group => group.longestWaitSeconds)),
    unvisitedPortals: byPortal.filter(portal => !portal.visits).map(portal => portal.portalId),
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
  const canonicalFinale = input.portals.find(portal => portal.code === "P-38");
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
    if (plan.visits.some(visit => visit.kind === "start") || ordered.some((visit, index) => visit.sequence !== index + 1 || !["ordinary", "finale"].includes(visit.kind)))
      problem("INVALID_ROUTE_SEQUENCE", "Het voorstel bevat uitsluitend echte bezoeken met een aaneengesloten volgorde vanaf één; administratief verzamelen wordt afzonderlijk bewaard.");
    if (group.fixedFirstPortalId && ordered[0]?.portalId !== group.fixedFirstPortalId) {
      const first = portals.get(group.fixedFirstPortalId), incoming = first && legs.get(`${node}|${first.nodeId}`);
      const outgoing = first && legs.get(`${first.nodeId}|portal:${group.finale.portalId}`);
      const allowed = first && !first.finale && !visited.has(physicalId(first.id))
        && (!(group.requiresStepFree || group.accessibilityNeedsReview) || first.accessibilityStatus === "step_free")
        && incoming && outgoing && incoming.seconds <= input.maxLegWalkingSeconds && incoming.seconds + outgoing.seconds <= input.maxTotalWalkingSeconds;
      const limit = allowed && plan.finaleArrivalAt ? Math.min(at(group.ordinaryStopAt), at(plan.finaleArrivalAt) - outgoing.seconds) : -Infinity;
      const feasible = allowed && earliest(calendar, first, group, cursor + incoming.seconds, limit);
      if (feasible && feasible.start + feasible.window.visitSeconds <= limit)
        problem("FEASIBLE_FIRST_PORTAL_MUST_BE_PRESERVED", "Het gekoppelde eerste huis heeft een gecontroleerd haalbaar ontvangstmoment en moet als eerste fysiek bezoek behouden blijven.", first.id);
      else if (!plan.diagnostics.some(diagnostic => ["FIRST_PORTAL_ALTERNATIVE", "FIXED_FIRST_PORTAL_REPLACED"].includes(diagnostic.code)))
        problem("FIRST_PORTAL_ALTERNATIVE_REVIEW_REQUIRED", "Een alternatief voor het gekoppelde eerste bezoek vereist een concrete diagnose ter beoordeling.", group.fixedFirstPortalId);
    }
    for (const visit of ordered) {
      const portal = portals.get(visit.portalId);
      if (!portal) { problem("PORTAL_UNAVAILABLE", "Deze poort is niet beschikbaar in de actuele planning.", visit.portalId); continue; }
      const start = at(visit.startsAt), leg = legs.get(`${node}|${portal.nodeId}`);
      if (!leg || start < cursor + leg.seconds) problem("TRAVEL_TIME", "Tussen de bezoeken is onvoldoende echte looptijd.", portal.id);
      if (leg && (visit.walkSeconds !== leg.seconds || visit.walkMeters !== leg.meters)) problem("TRAVEL_ESTIMATE_MISMATCH", "De getoonde loopduur en afstand moeten overeenkomen met het opgeslagen werkelijke traject.", portal.id);
      walking += leg?.seconds ?? 0;
      if (leg && !portal.finale && leg.seconds > input.maxLegWalkingSeconds) problem("ORDINARY_LEG_LIMIT", `De gewone etappe duurt ${leg.seconds} seconden; de aparte etappelimiet is ${input.maxLegWalkingSeconds} seconden.`, portal.id);
      if (walking > input.maxTotalWalkingSeconds) problem("WALKING_BUDGET", `De werkelijke totale looptijd is ${walking} seconden; het afzonderlijke totale loopbudget is ${input.maxTotalWalkingSeconds} seconden. De finale-etappe heeft geen eigen tijdlimiet.`, portal.id);
      if (portal.finale !== (visit.kind === "finale")) problem("FINALE_PORTAL_KIND", "De fysieke finalepoort kan uitsluitend als laatste finale worden bezocht.", portal.id);
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
        if (portal.id !== group.finale.portalId || !portal.finale || canonicalFinale && portal.id !== canonicalFinale.id) problem("FINALE_LOCATION_CHANGED", "P-38 blijft de enige fysieke finaleplaats.", portal.id);
        if (!group.finale.reservedAt || start !== at(group.finale.reservedAt)) {
          const change = plan.finaleChange;
          const previousMatches = change && (change.previousReservedAt === null ? group.finale.reservedAt === null
            : group.finale.reservedAt !== null && at(change.previousReservedAt) === at(group.finale.reservedAt));
          if (!change || change.portalId !== group.finale.portalId || !previousMatches || at(change.proposedReservedAt) !== start)
            problem("FINALE_CHANGE_REVIEW_REQUIRED", "Een ander tijdslot bij P-38 moet met de oude en voorgestelde afspraak expliciet worden beoordeeld.", portal.id);
        } else if (plan.finaleChange) problem("FINALE_CHANGE_MISMATCH", "De gemarkeerde finale-tijdswijziging moet overeenkomen met een werkelijk gewijzigd tijdstip bij P-38.", portal.id);
        if (start > at(group.finale.latestArrivalAt) || group.desiredEndAt && start + visit.visitSeconds > at(group.desiredEndAt) + input.maxGroupOverrunSeconds) problem("GROUP_COMPLETION_LIMIT", "De show moet binnen de uiterste groepsafronding en het finalevenster eindigen.", portal.id);
        if (!plan.finaleArrivalAt || at(plan.finaleArrivalAt) !== start || !plan.expectedCompletionAt || at(plan.expectedCompletionAt) !== start + visit.visitSeconds) problem("FINALE_TIMING_MISMATCH", "Finale-afspraak en getoonde afronding moeten dezelfde werkelijke tijden gebruiken.", portal.id);
      }
      cursor = start + visit.visitSeconds; node = portal.nodeId;
    }
    if (ordered.filter(visit => visit.kind === "finale").length !== 1 || ordered.at(-1)?.kind !== "finale") problem("FINALE_REQUIRED", "Een geldige route eindigt met precies de gereserveerde finale.");
    if (!ordered.some(visit => visit.kind === "ordinary") && input.portals.some(portal => !portal.finale && !visited.has(physicalId(portal.id)))) {
      const accessible = input.portals.filter(portal => !portal.finale && (!(group.requiresStepFree || group.accessibilityNeedsReview) || portal.accessibilityStatus === "step_free"));
      const reachable = accessible.filter(portal => legs.has(`${group.startNodeId}|${portal.nodeId}`));
      problem("NO_FEASIBLE_ORDINARY_VISIT", group.accessibilityNeedsReview ? "De behoefte moet nog worden gecontroleerd. Dit voorstel bevat geen bevestigd drempelvrij gewoon bezoek; de begrensde zoektocht bewijst geen onmogelijkheid. Controleer de ontvangstkalender en de expliciete toegankelijkheidsgegevens."
        : !accessible.length && group.requiresStepFree ? "Er is geen bevestigd drempelvrij gewoon huis beschikbaar; controleer de eigen toegankelijkheidsgegevens van de poorten."
          : !reachable.length ? "Er is geen opgeslagen bruikbaar looptraject naar een geschikte gewone poort; controleer de ingangspinnen."
            : `Dit voorstel bevat geen gewoon bezoek. Er zijn ${reachable.length} geschikte huizen met opgeslagen looptrajecten; de begrensde zoektocht vond geen bruikbare route binnen start, ontvangstkalender, het aparte loopbudget, gewone stopgrens en finalevenster. Onmogelijkheid is niet bewezen.`);
    }
  }
  return conflicts;
}

/**
 * Deterministic shared-calendar constructions, pair removal/reinsertion and
 * bounded route insertion/reordering. Labels/preferences never enter the search.
 * A zero-visit group is protected before maximizing total real unique visits;
 * equal counts are only a tie-break, never a cap on another group's route.
 */
export function proposeJointRoutes(input: JointRouteInput): JointRouteProposal {
  if (input.groups.length > 60 || input.portals.length > 120 || input.legs.length > 32_400
    || !input.sourceHash || !input.boardHash || new Set(input.groups.map(group => group.id)).size !== input.groups.length
    || input.groups.some(group => !Number.isFinite(at(group.startsAt)) || !Number.isFinite(at(group.ordinaryStopAt)))
    || input.legs.some(leg => !Number.isFinite(leg.seconds) || leg.seconds < 0 || !Number.isFinite(leg.meters) || leg.meters < 0)) throw new Error("INVALID_JOINT_PLANNING_INPUT");
  const groups = [...input.groups].sort((a, b) => compareId(a.id, b.id));
  const portals = [...input.portals].sort((a, b) => compareId(a.id, b.id)).map(portal => ({ ...portal,
    windows: [...portal.windows].sort((a, b) => at(a.opensAt) - at(b.opensAt) || at(a.closesAt) - at(b.closesAt)) }));
  const portalById = new Map(portals.map(portal => [portal.id, portal]));
  const physicalId = (id: string) => portalById.get(id)?.physicalId ?? id;
  const legs = new Map(input.legs.map(leg => [`${leg.from}|${leg.to}`, leg]));
  const work = { candidateEvaluations: 0, variants: 0, pairReplans: 0, routeRepairs: 0, exhausted: false };
  const base = input.fixedVisits.filter(physical).map(visit => occupancy(visit, visit.groupId, visit.children, visit.physicalId ?? physicalId(visit.portalId)));
  function budget() {
    if (work.candidateEvaluations >= JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations) { work.exhausted = true; return false; }
    work.candidateEvaluations++; return true;
  }
  const finalLimit = (group: JointRouteGroup, window: JointRouteWindow) => Math.min(at(group.finale.latestArrivalAt),
    at(window.arrivalClosesAt), at(window.closesAt) - window.visitSeconds - window.bufferSeconds,
    group.desiredEndAt ? at(group.desiredEndAt) + input.maxGroupOverrunSeconds - window.visitSeconds : Infinity);
  function finalVisit(group: JointRouteGroup, start: number, window: JointRouteWindow): JointRouteVisit {
    return { portalId: group.finale.portalId, kind: "finale", sequence: 1,
      startsAt: group.finale.reservedAt && start === at(group.finale.reservedAt) ? group.finale.reservedAt : iso(start),
      visitSeconds: window.visitSeconds, bufferSeconds: window.bufferSeconds, walkSeconds: 0, walkMeters: 0 };
  }
  function latestFinal(calendar: Occupancy[], group: JointRouteGroup) {
    const portal = portalById.get(group.finale.portalId);
    if (!portal?.finale) return null;
    for (const window of [...portal.windows].reverse()) {
      const end = finalLimit(group, window), service = window.visitSeconds + window.bufferSeconds;
      const others = calendar.filter(visit => visit.portalId === physicalId(portal.id) && visit.groupId !== group.id);
      const ticks = [end, ...others.flatMap(visit => [visit.start - window.headwaySeconds, visit.start - service, visit.end - service])]
        .filter(tick => tick <= end && tick >= Math.max(at(group.startsAt), at(window.opensAt))).sort((a, b) => b - a);
      for (const tick of ticks) if (fits(calendar, portal, group, tick, window)) return finalVisit(group, tick, window);
    }
    return null;
  }
  function build(subset: JointRouteGroup[], variant: number, reserved: Occupancy[]) {
    const calendar = [...reserved], anchors = new Map<string, JointRouteVisit>();
    const anchorOrder = [...subset].sort((a, b) => (variant % 2 ? -1 : 1) * (at(a.finale.latestArrivalAt) - at(b.finale.latestArrivalAt)) || compareId(a.id, b.id));
    for (const group of anchorOrder) {
      const portal = portalById.get(group.finale.portalId), saved = group.finale.reservedAt ? at(group.finale.reservedAt) : NaN;
      const window = portal && matchingWindow(portal, saved, Math.min(...portal.windows.map(window => window.visitSeconds)), Math.min(...portal.windows.map(window => window.bufferSeconds)), group.childCount);
      // Keeping old times is one search variant, never the only endpoint anchor.
      const keep = variant < 2 && portal?.finale && window && saved <= finalLimit(group, window) && fits(calendar, portal, group, saved, window);
      const anchor = keep ? finalVisit(group, saved, window) : latestFinal(calendar, group);
      if (anchor) { anchors.set(group.id, anchor); calendar.push(occupancy(anchor, group.id, group.childCount, physicalId(anchor.portalId))); }
    }
    const states: State[] = subset.map(group => ({ group, node: group.startNodeId, cursor: at(group.startsAt), walking: 0,
      visits: [], chosen: new Set(group.excludedPortalIds.map(physicalId)), done: !anchors.has(group.id) }));
    function candidate(state: State, portal: JointRoutePortal): Candidate | null {
      const group = state.group, anchor = anchors.get(group.id);
      if (!anchor || portal.finale || physicalId(portal.id) === physicalId(group.finale.portalId) || state.chosen.has(physicalId(portal.id))
        || (group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free" || !budget()) return null;
      const walk = legs.get(`${state.node}|${portal.nodeId}`), exit = legs.get(`${portal.nodeId}|portal:${group.finale.portalId}`);
      if (!walk || !exit || walk.seconds > input.maxLegWalkingSeconds || state.walking + walk.seconds + exit.seconds > input.maxTotalWalkingSeconds) return null;
      const reachable = state.cursor + walk.seconds, limit = Math.min(at(group.ordinaryStopAt), at(anchor.startsAt) - exit.seconds);
      const feasible = earliest(calendar, portal, group, reachable, limit);
      if (!feasible || feasible.start + feasible.window.visitSeconds > limit) return null;
      const wait = feasible.start - reachable, received = calendar.filter(visit => visit.portalId === physicalId(portal.id));
      const unique = new Set(received.map(visit => visit.groupId)).size;
      const prior = input.before.find(plan => plan.groupId === group.id)?.visits.some(visit => physicalId(visit.portalId) === physicalId(portal.id));
      const slack = Math.max(0, Math.min(at(feasible.window.arrivalClosesAt), at(feasible.window.closesAt) - feasible.window.visitSeconds - feasible.window.bufferSeconds, limit - feasible.window.visitSeconds) - feasible.start);
      // Seconds lost dominate small load changes. Some variants inspect short
      // openings early; others favor the next completion or route preservation.
      const cost = walk.seconds + wait * (variant % 4 === 1 ? 3 : 1.5)
        + (variant % 4 >= 2 ? Math.min(900, slack) * 0.35 : 0)
        + unique * 8 + (prior ? 0 : 1) + (variant % 4 === 3 ? exit.seconds * 0.15 : 0);
      return { portal, ...feasible, walk, wait, cost };
    }
    function append(state: State, best: Candidate) {
      const visit: JointRouteVisit = { portalId: best.portal.id, kind: "ordinary", sequence: state.visits.length + 1, startsAt: iso(best.start),
        visitSeconds: best.window.visitSeconds, bufferSeconds: best.window.bufferSeconds, walkSeconds: best.walk.seconds, walkMeters: best.walk.meters, waitSeconds: best.wait };
      state.visits.push(visit); state.chosen.add(physicalId(best.portal.id)); state.walking += best.walk.seconds;
      state.cursor = best.start + best.window.visitSeconds; state.node = best.portal.nodeId;
      calendar.push(occupancy(visit, state.group.id, state.group.childCount, physicalId(visit.portalId)));
    }
    // Reserve useful linked first houses before unrelated route choices consume
    // their reception slots. A score can never replace a feasible linked first.
    for (const state of [...states].sort((a, b) => at(a.group.startsAt) - at(b.group.startsAt) || compareId(a.group.id, b.group.id))) {
      const portal = state.group.fixedFirstPortalId && portalById.get(state.group.fixedFirstPortalId);
      const first = portal && candidate(state, portal);
      if (first) append(state, first);
    }
    let turns = 0;
    while (states.some(state => !state.done) && turns++ < subset.length * (portals.length + 1) && !work.exhausted) {
      const state = states.filter(state => !state.done).sort((a, b) => Number(a.visits.length > 0) - Number(b.visits.length > 0)
        || (variant % 2 ? a.cursor - b.cursor : at(a.group.finale.latestArrivalAt) - at(b.group.finale.latestArrivalAt))
        || compareId(a.group.id, b.group.id))[0];
      let best: Candidate | null = null;
      for (const portal of portals) {
        const next = candidate(state, portal);
        if (next && (!best || next.cost < best.cost || next.cost === best.cost && compareId(next.portal.id, best.portal.id) < 0)) best = next;
      }
      if (best) append(state, best); else state.done = true;
    }
    return states.map(state => {
      const finale = anchors.get(state.group.id), exit = finale && legs.get(`${state.node}|portal:${finale.portalId}`), visits = [...state.visits];
      if (finale && exit && state.cursor + exit.seconds <= at(finale.startsAt) && state.walking + exit.seconds <= input.maxTotalWalkingSeconds)
        visits.push({ ...finale, sequence: visits.length + 1, walkSeconds: exit.seconds, walkMeters: exit.meters });
      return makePlan(state.group, visits);
    });
  }
  function makePlan(group: JointRouteGroup, visits: JointRouteVisit[]): JointRouteGroupPlan {
    const finale = visits.at(-1)?.kind === "finale" ? visits.at(-1)! : null;
    const changed = finale && (!group.finale.reservedAt || at(finale.startsAt) !== at(group.finale.reservedAt));
    return { groupId: group.id, startsAt: group.startsAt, desiredEndAt: group.desiredEndAt, visits, diagnostics: [],
      finaleArrivalAt: finale?.startsAt ?? null, expectedCompletionAt: finale ? iso(at(finale.startsAt) + finale.visitSeconds) : null,
      ...(changed ? { finaleChange: { portalId: group.finale.portalId, previousReservedAt: group.finale.reservedAt, proposedReservedAt: finale.startsAt } } : {}) };
  }
  const calendarOf = (plans: JointRouteGroupPlan[]) => [...base, ...plans.flatMap(plan => plan.visits.filter(physical)
    .map(visit => occupancy(visit, plan.groupId, groups.find(group => group.id === plan.groupId)!.childCount, physicalId(visit.portalId))))];
  function compactFinales(plans: JointRouteGroupPlan[]) {
    let result = plans;
    for (let pass = 0; pass < 2; pass++) {
      for (const plan of [...result].sort((a, b) => at(a.finaleArrivalAt ?? "") - at(b.finaleArrivalAt ?? "") || compareId(a.groupId, b.groupId))) {
        const group = groups.find(group => group.id === plan.groupId)!, portal = portalById.get(group.finale.portalId), previous = plan.visits.at(-1);
        if (!portal || previous?.kind !== "finale") continue;
        const ordinary = plan.visits.filter(visit => visit.kind === "ordinary"), last = ordinary.at(-1);
        const node = last ? portalById.get(last.portalId)!.nodeId : group.startNodeId, exit = legs.get(`${node}|${portal.nodeId}`);
        if (!exit) continue;
        const reachable = (last ? at(last.startsAt) + last.visitSeconds : at(group.startsAt)) + exit.seconds;
        const calendar = calendarOf(result).filter(visit => visit.groupId !== group.id);
        const next = earliest(calendar, portal, group, reachable, at(previous.startsAt));
        if (!next || next.start > finalLimit(group, next.window)) continue;
        const finale = { ...finalVisit(group, next.start, next.window), sequence: ordinary.length + 1, walkSeconds: exit.seconds, walkMeters: exit.meters };
        result = result.map(item => item.groupId === group.id ? makePlan(group, [...ordinary, finale]) : item);
      }
    }
    return result;
  }
  const scoreCache = new WeakMap<JointRouteGroupPlan[], number[]>();
  const score = (plans: JointRouteGroupPlan[]) => {
    const cached = scoreCache.get(plans); if (cached) return cached;
    const metrics = measureJointRoutes(input, plans);
    const value = [-validateJointRoutes(input, plans).length, -metrics.zeroVisitGroups, metrics.totalOrdinaryVisits,
      ...metrics.byGroup.map(group => group.ordinaryVisits).sort((a, b) => a - b),
      -metrics.receptionWaitingSeconds, -metrics.unallocatedBeforeFinaleSeconds, -metrics.walkingSeconds,
      -metrics.unvisitedPortals.length, -metrics.byPortal.reduce((sum, portal) => sum + portal.visitsPerOpenHour ** 2, 0),
      -metrics.absoluteEndDeviationSeconds];
    scoreCache.set(plans, value); return value;
  };
  function better(next: JointRouteGroupPlan[], prior: JointRouteGroupPlan[]) {
    const a = score(next), b = score(prior);
    for (let index = 0; index < a.length; index++) if (a[index] !== b[index]) return a[index] > b[index];
    return jointRouteProposalDigestText(input.sourceHash, input.boardHash, next) < jointRouteProposalDigestText(input.sourceHash, input.boardHash, prior);
  }
  let best: JointRouteGroupPlan[] = [];
  for (let variant = 0; variant < JOINT_ROUTE_SEARCH_LIMITS.variants; variant++) {
    const plans = compactFinales(build(groups, variant, base)); work.variants++;
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
      const replacement = build(pair, 2 + work.pairReplans % (JOINT_ROUTE_SEARCH_LIMITS.variants - 2), calendarOf(others));
      const candidate = compactFinales([...others, ...replacement].sort((a, b) => compareId(a.groupId, b.groupId))); work.pairReplans++;
      if (better(candidate, best)) best = candidate;
    }
  }

  // Reschedule a concrete order against other groups, using real travel and
  // every reception window. Used for inserting houses and for swaps/2-opt.
  function orderedRoute(group: JointRouteGroup, order: string[], others: JointRouteGroupPlan[]) {
    if (!budget()) return null;
    const calendar = calendarOf(others), visits: JointRouteVisit[] = [];
    let node = group.startNodeId, cursor = at(group.startsAt), walking = 0;
    const seen = new Set(group.excludedPortalIds.map(physicalId));
    for (const id of order) {
      const portal = portalById.get(id)!, walk = legs.get(`${node}|${portal.nodeId}`);
      if (portal.finale || seen.has(physicalId(id)) || !walk || walk.seconds > input.maxLegWalkingSeconds
        || (group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free") return null;
      walking += walk.seconds; if (walking > input.maxTotalWalkingSeconds) return null;
      const received = earliest(calendar, portal, group, cursor + walk.seconds, at(group.ordinaryStopAt));
      if (!received || received.start + received.window.visitSeconds > at(group.ordinaryStopAt)) return null;
      const visit: JointRouteVisit = { portalId: id, kind: "ordinary", sequence: visits.length + 1, startsAt: iso(received.start),
        visitSeconds: received.window.visitSeconds, bufferSeconds: received.window.bufferSeconds, walkSeconds: walk.seconds, walkMeters: walk.meters,
        waitSeconds: received.start - cursor - walk.seconds };
      visits.push(visit); seen.add(physicalId(id)); node = portal.nodeId; cursor = received.start + visit.visitSeconds;
    }
    const portal = portalById.get(group.finale.portalId), exit = portal && legs.get(`${node}|${portal.nodeId}`);
    if (!portal?.finale || !exit || walking + exit.seconds > input.maxTotalWalkingSeconds) return null;
    const received = earliest(calendar, portal, group, cursor + exit.seconds, at(group.finale.latestArrivalAt));
    if (!received || received.start > finalLimit(group, received.window)) return null;
    visits.push({ ...finalVisit(group, received.start, received.window), sequence: visits.length + 1, walkSeconds: exit.seconds, walkMeters: exit.meters });
    return makePlan(group, visits);
  }
  let repairs = 0;
  // Several passes allow a successful reorder to open an insertion that was
  // unavailable on the first pass. Counts are never equalized or truncated.
  for (let pass = 0; pass < 3 && !work.exhausted; pass++) {
    let changed = false;
    for (const group of [...groups].sort((a, b) => at(a.finale.latestArrivalAt) - at(b.finale.latestArrivalAt) || compareId(a.id, b.id))) {
      let plan = best.find(plan => plan.groupId === group.id)!;
      let groupRepairs = 0;
      const others = best.filter(plan => plan.groupId !== group.id);
      const order = () => plan.visits.filter(visit => visit.kind === "ordinary").map(visit => visit.portalId);
      const fixed = () => group.fixedFirstPortalId && physicalId(order()[0] ?? "") === physicalId(group.fixedFirstPortalId) ? 1 : 0;
      const attempt = (ids: string[]) => {
        if (repairs >= JOINT_ROUTE_SEARCH_LIMITS.routeRepairs || groupRepairs >= JOINT_ROUTE_SEARCH_LIMITS.repairsPerGroupPass || work.exhausted) return;
        repairs++; groupRepairs++;
        const replacement = orderedRoute(group, ids, others);
        if (!replacement) return;
        // The simulator checked every hard boundary against the unchanged other
        // groups. Compare the changed route directly, avoiding a full evening
        // measurement for each local permutation.
        const routeScore = (item: JointRouteGroupPlan) => {
          const ordinary = item.visits.filter(visit => visit.kind === "ordinary"), last = ordinary.at(-1);
          const exit = item.visits.at(-1)?.walkSeconds ?? 0;
          return [ordinary.length, -ordinary.reduce((sum, visit) => sum + (visit.waitSeconds ?? 0), 0),
            -(at(item.finaleArrivalAt!) - (last ? at(last.startsAt) + last.visitSeconds : at(group.startsAt)) - exit),
            -item.visits.reduce((sum, visit) => sum + visit.walkSeconds, 0)];
        };
        const a = routeScore(replacement), b = routeScore(plan), firstDifference = a.findIndex((value, index) => value !== b[index]);
        if (firstDifference >= 0 && a[firstDifference] > b[firstDifference]) {
          plan = replacement; best = [...others, replacement].sort((a, b) => compareId(a.groupId, b.groupId)); changed = true;
        }
      };
      for (const portal of portals) {
        if (portal.finale || order().some(id => physicalId(id) === physicalId(portal.id))) continue;
        for (let index = fixed(); index <= order().length; index++) { const ids = order(); ids.splice(index, 0, portal.id); attempt(ids); }
      }
      const ids = order();
      for (let first = fixed(); first < ids.length - 1; first++) {
        for (let second = first + 1; second < ids.length; second++) {
          const reordered = [...ids]; [reordered[first], reordered[second]] = [reordered[second], reordered[first]]; attempt(reordered);
        }
      }
    }
    if (!changed || repairs >= JOINT_ROUTE_SEARCH_LIMITS.routeRepairs) break;
  }
  work.routeRepairs = repairs;
  if (repairs >= JOINT_ROUTE_SEARCH_LIMITS.routeRepairs) work.exhausted = true;
  best = compactFinales(best).sort((a, b) => compareId(a.groupId, b.groupId));
  for (const plan of best) {
    const group = groups.find(group => group.id === plan.groupId)!, ordinary = plan.visits.filter(visit => visit.kind === "ordinary");
    const warning = (code: string, message: string, portalId?: string) => plan.diagnostics.push({ code, severity: "warning", groupId: group.id, portalId, message });
    if (!ordinary.length && portals.filter(portal => !portal.finale).every(portal => group.excludedPortalIds.some(id => physicalId(id) === physicalId(portal.id))))
      warning("ALL_HOUSES_ALREADY_VISITED", "Alle beschikbare fysieke huizen staan al in de bezoekhistorie. De groep krijgt een passende afronding bij P-38; er zijn geen dubbele of fictieve bezoeken toegevoegd.");
    if (group.accessibilityNeedsReview) warning("ACCESSIBILITY_NEEDS_REVIEW", "Controleer de expliciete toegankelijkheidsbehoefte. Dit voorstel gebruikt voorlopig alleen bevestigd drempelvrije huizen en wijzigt geen kindgegevens.");
    if (group.fixedFirstPortalId && physicalId(ordinary[0]?.portalId ?? "") !== physicalId(group.fixedFirstPortalId)) {
      const portal = portalById.get(group.fixedFirstPortalId), walk = portal && legs.get(`${group.startNodeId}|${portal.nodeId}`);
      const calendar = calendarOf(best).filter(visit => visit.groupId !== group.id);
      const reception = portal && walk && earliest(calendar, portal, group, at(group.startsAt) + walk.seconds, at(group.ordinaryStopAt));
      const exit = portal && legs.get(`${portal.nodeId}|portal:${group.finale.portalId}`);
      const cause = !portal ? "de gekoppelde poort is niet actief en locatiegereed in de actuele invoer"
        : group.excludedPortalIds.some(id => physicalId(id) === physicalId(portal.id)) ? "het fysieke huis staat al in de bezoekhistorie"
        : (group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free" ? "een benodigde drempelvrije ontvangst is niet bevestigd"
        : !walk || !exit ? "een opgeslagen werkelijk looptraject ontbreekt"
        : walk.seconds > input.maxLegWalkingSeconds ? `de gewone aanloop duurt ${walk.seconds} seconden, boven de gewone etappelimiet van ${input.maxLegWalkingSeconds} seconden`
        : walk.seconds + exit.seconds > input.maxTotalWalkingSeconds ? `aanloop plus finale vergt ${walk.seconds + exit.seconds} seconden, boven het aparte totale loopbudget van ${input.maxTotalWalkingSeconds} seconden`
        : !reception ? `geen vrij ontvangstmoment past vanaf ${iso(at(group.startsAt) + walk.seconds)} binnen de opening, aankomstafstand, capaciteit en gewone stopgrens ${group.ordinaryStopAt}`
        : `de begrensde gezamenlijke zoekroutine vond met dit eerste huis geen volledige route binnen de ontvangstkalender en het finalevenster tot ${group.finale.latestArrivalAt}; onmogelijkheid is niet bewezen`;
      warning("FIRST_PORTAL_ALTERNATIVE", `Gekoppeld eerste bezoek niet opgenomen: ${cause}. De administratieve verzamelplek en starttijd blijven behouden.`, group.fixedFirstPortalId);
    }
    if (plan.finaleChange) warning("FINALE_TIME_CHANGE", `Expliciet te beoordelen tijdslotwijziging bij dezelfde fysieke finale P-38: ${group.finale.reservedAt ?? "geen reservering"} → ${plan.finaleArrivalAt}.`, group.finale.portalId);
    const measured = measureJointRoutes(input, [plan]).byGroup[0];
    if (measured.receptionWaitingSeconds > 300) warning("RECEPTION_WAIT", `${Math.ceil(measured.receptionWaitingSeconds / 60)} minuten ontvangstwachttijd door echte opening, aankomstafstand of bezetting; apart geteld van vrije tijd vóór P-38.`);
    if (measured.unallocatedBeforeFinaleSeconds > 600) warning("UNALLOCATED_BEFORE_FINALE", `${Math.ceil(measured.unallocatedBeforeFinaleSeconds / 60)} minuten vrije tijd vóór P-38. Geen betere gezamenlijke combinatie gevonden binnen de begrensde zoekruimte; geen bewijs van onmogelijkheid.`);
    if (group.desiredEndAt && plan.expectedCompletionAt && at(plan.expectedCompletionAt) < at(group.desiredEndAt) - 600)
      warning("EVENING_DURATION_TRADEOFF", `De ${ordinary.length} echte bezoeken en de show ronden ${Math.ceil((at(group.desiredEndAt) - at(plan.expectedCompletionAt)) / 60)} minuten vóór de gewenste eindtijd af. Een langere avond vraagt vrije tijd; er zijn geen extra bezoeken, rondjes of langere shows verzonnen.`);
    const priorCount = input.before.find(before => before.groupId === group.id)?.visits.filter(visit => visit.kind === "ordinary").length ?? 0;
    if (ordinary.length < priorCount) warning("ORDINARY_VISITS_REDUCED", `${priorCount - ordinary.length} minder gewone bezoeken dan het opgeslagen bord. De begrensde gezamenlijke herverdeling vond geen beter geldig alternatief; controleer de concrete ontvangstvensters en het aparte totale loopbudget.`);
    for (const portal of portals.filter(portal => !portal.finale && !ordinary.some(visit => physicalId(visit.portalId) === physicalId(portal.id)))) {
      const history = group.excludedPortalIds.some(id => physicalId(id) === physicalId(portal.id));
      const inaccessible = (group.requiresStepFree || group.accessibilityNeedsReview) && portal.accessibilityStatus !== "step_free";
      const visits = ordinary.map(visit => visit.portalId), startIndex = group.fixedFirstPortalId && visits[0] === group.fixedFirstPortalId ? 1 : 0;
      const walkingOptions = Array.from({ length: visits.length + 1 - startIndex }, (_, offset) => {
        const ids = [...visits]; ids.splice(offset + startIndex, 0, portal.id);
        let node = group.startNodeId, seconds = 0;
        for (const id of [...ids, group.finale.portalId]) { const to = portalById.get(id)!.nodeId, leg = legs.get(`${node}|${to}`); if (!leg || id !== group.finale.portalId && leg.seconds > input.maxLegWalkingSeconds) return Infinity; seconds += leg.seconds; node = to; }
        return seconds;
      });
      const minimumWalking = Math.min(...walkingOptions);
      const otherCalendar = calendarOf(best).filter(visit => visit.groupId !== group.id);
      const ordered = plan.visits.filter(physical).sort((a, b) => a.sequence - b.sequence);
      const insertionLimits = Array.from({ length: ordinary.length + 1 - startIndex }, (_, offset) => {
        const index = offset + startIndex, previous = ordered[index - 1], next = ordered[index];
        if (!next) return null;
        const node = previous ? portalById.get(previous.portalId)!.nodeId : group.startNodeId;
        const incoming = legs.get(`${node}|${portal.nodeId}`), outgoing = legs.get(`${portal.nodeId}|${portalById.get(next.portalId)!.nodeId}`);
        if (!incoming || !outgoing || incoming.seconds > input.maxLegWalkingSeconds || next.kind !== "finale" && outgoing.seconds > input.maxLegWalkingSeconds) return null;
        const reachable = (previous ? at(previous.startsAt) + previous.visitSeconds : at(group.startsAt)) + incoming.seconds;
        const received = earliest(otherCalendar, portal, group, reachable, at(group.ordinaryStopAt));
        const latestEnd = Math.min(at(group.ordinaryStopAt), at(next.startsAt) - outgoing.seconds);
        if (!received) return { shortage: Infinity, message: `Geen vrij ontvangstmoment vanaf ${iso(reachable)} tot de gewone stop ${group.ordinaryStopAt}, binnen opening, aankomstafstand en bezetting.` };
        const shortage = received.start + received.window.visitSeconds - latestEnd;
        return { shortage, message: shortage > 0
          ? `Vóór ${portalById.get(next.portalId)!.code} is het vroegste vrije ontvangsttijdstip ${iso(received.start)}; bezoek plus ${outgoing.seconds} seconden werkelijk lopen mist de volgende aankomst ${next.startsAt} met ${Math.ceil(shortage)} seconden.`
          : `Een invoeging vóór ${portalById.get(next.portalId)!.code} heeft een vrij ontvangstmoment op ${iso(received.start)}; controleer het aparte totale loopbudget en de begrensde herverdeling.` };
      }).filter((value): value is { shortage: number; message: string } => value !== null).sort((a, b) => a.shortage - b.shortage);
      const reason = history ? "Reeds fysiek bezocht door de groep of een meeverhuisd kind; geen dubbel bezoek."
        : inaccessible ? "De vereiste drempelvrije ontvangst is niet bevestigd."
        : !Number.isFinite(minimumWalking) ? `Geen invoegpositie in de gevonden huisvolgorde met opgeslagen looptrajecten en gewone etappes van maximaal ${input.maxLegWalkingSeconds} seconden. De finale-etappe heeft geen vaste limiet.`
        : minimumWalking > input.maxTotalWalkingSeconds ? `Invoegen in de gevonden huisvolgorde vergt minstens ${minimumWalking} seconden lopen; het aparte totale loopbudget is ${input.maxTotalWalkingSeconds} seconden, inclusief de werkelijke wandeling naar P-38.`
        : `${insertionLimits[0]?.message ?? "Geen invoegpositie met passende echte gewone etappes gevonden."} Dit verklaart invoegen binnen de huidige aankomstafspraken. De begrensde herordening vond geen beter gezamenlijk alternatief; onmogelijkheid bij andere volgorden is niet bewezen.`;
      warning("OMITTED_PORTAL", reason, portal.id);
    }
  }
  const conflicts = [...new Map([...(input.diagnostics ?? []), ...best.flatMap(plan => plan.diagnostics), ...validateJointRoutes(input, best)]
    .map(diagnostic => [`${diagnostic.code}|${diagnostic.groupId ?? ""}|${diagnostic.portalId ?? ""}`, diagnostic])).values()];
  if (work.exhausted) conflicts.push({ code: "BOUNDED_SEARCH_LIMIT", severity: "warning", message: "Het deterministische zoekbudget is gebruikt. Dit is het beste gevonden gecontroleerde voorstel; een wereldwijd optimum is niet bewezen." });
  const before = measureJointRoutes(input, input.before), after = measureJointRoutes(input, best);
  after.administrativeStarts = before.administrativeStarts;
  return { sourceHash: input.sourceHash, boardHash: input.boardHash, policyVersion: input.policyVersion,
    proposalHash: createHash("sha256").update(jointRouteProposalDigestText(input.sourceHash, input.boardHash, best)).digest("hex"),
    valid: !conflicts.some(conflict => conflict.severity === "block"), groups: best, conflicts, metrics: { before, after }, work,
    walkingPolicy: { maxOrdinaryLegSeconds: input.maxLegWalkingSeconds, maxTotalSeconds: input.maxTotalWalkingSeconds, finaleLegLimitSeconds: null } };
}
