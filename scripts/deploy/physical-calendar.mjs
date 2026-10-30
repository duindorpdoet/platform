// Pure diagnostics. Inputs and outputs use group/portal codes, never participant
// details. Service, physical changeover and arrival spacing remain independent.
const millis = value => typeof value === "string" ? Date.parse(value) : NaN;
const unique = values => [...new Set(values)];
const code = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,50}$/.test(value) ? value : "UNKNOWN_CODE";
const numeric = value => typeof value === "number" && Number.isFinite(value) ? value : null;
const stamp = value => Number.isFinite(millis(value)) ? value : null;
const readableDiagnostic = {
  OPENING_WINDOW: "Aankomst, bezoek of wisseltijd past niet binnen de effectieve poortopening.",
  ARRIVAL_OR_CAPACITY_CONFLICT: "Aankomstafstand of fysieke groeps-/kindercapaciteit is overschreden.",
  ACCESSIBILITY_UNSUITABLE: "De ingang is niet aantoonbaar geschikt voor de gecontroleerde routebehoefte.",
  ACCESSIBILITY_REVIEW_REQUIRED: "De bedoelde kindbehoefte of de toegankelijkheid moet worden geverifieerd.",
  NO_FEASIBLE_ORDINARY_VISIT: "Geen geschikt gewoon bezoek past binnen de gecontroleerde vaste afspraken en gedeelde kalender.",
  FINALE_APPOINTMENT_CHANGED: "De finale wijkt af van de opgeslagen gereserveerde afspraak.",
  FINALE_CHANGE_REVIEW_REQUIRED: "Een ander tijdslot bij dezelfde finalepoort moet expliciet worden beoordeeld.",
  FINALE_LOCATION_CHANGED: "P-38 blijft de enige fysieke finaleplaats.",
  FINALE_TIMING_MISMATCH: "Finale-aankomst en getoonde afronding gebruiken verschillende tijden.",
  GROUP_COMPLETION_LIMIT: "De show eindigt buiten de toegestane groepsafronding of het finalevenster.",
  DUPLICATE_PHYSICAL_VISIT: "Dit fysieke huis komt voor deze groep of bestaande kindhistorie meermaals voor.",
  TRAVEL_TIME: "Er is onvoldoende opgeslagen echte looptijd tussen bezoeken.",
  WALKING_BUDGET: "De route overschrijdt het vastgelegde loopbudget.",
  ORDINARY_LEG_LIMIT: "Een gewone etappe overschrijdt de afzonderlijke gewone etappelimiet; die limiet geldt niet voor de finale-etappe.",
  ORDINARY_STOP_LIMIT: "Een gewoon bezoek eindigt na de expliciete stopgrens.",
  START_APPOINTMENT_CHANGED: "Het voorstel wijzigt een opgeslagen startafspraak.",
  FINALE_REQUIRED: "Een route heeft niet precies de gereserveerde finale als laatste fysiek bezoek.",
};

export function auditPhysicalCalendar(calendar) {
  const groups = new Map((calendar.groups ?? []).map(group => [group.code, group]));
  const portals = new Map((calendar.portals ?? []).map(portal => [portal.code, portal]));
  const administrative = (calendar.visits ?? []).filter(visit => visit.kind === "start");
  const visits = (calendar.visits ?? []).filter(visit => visit.kind === "ordinary" || visit.kind === "finale").map(visit => {
    const start = millis(visit.startsAt), portal = portals.get(visit.portalCode);
    return { ...visit, portal, start, serviceEnd: start + visit.durationSeconds * 1000, end: start + (visit.durationSeconds + visit.bufferSeconds) * 1000,
      physicalCode: portal?.physicalCode ?? visit.physicalCode ?? visit.portalCode,
      children: visit.children ?? groups.get(visit.groupCode)?.children ?? null };
  });
  const conflicts = [], deduplicated = new Set();
  function add(name, involved, extra = {}) {
    const item = { code: name, groupCodes: unique(involved.map(visit => code(visit.groupCode))).sort(), portalCodes: unique(involved.map(visit => code(visit.portalCode))).sort(), ...extra };
    const key = JSON.stringify(item); if (!deduplicated.has(key)) { deduplicated.add(key); conflicts.push(item); }
  }
  for (const visit of visits) {
    if (!Number.isFinite(visit.start) || !Number.isFinite(visit.end)) { add("VISIT_TIME_UNKNOWN", [visit]); continue; }
    if (visit.timingEvidence === "reservation_occupation_only") add("SERVICE_TIMING_UNKNOWN", [visit]);
    const windows = visit.portal?.windows ?? [];
    const receiving = windows.filter(window => visit.start >= millis(window.opensAt) && (window.arrivalCloseInclusive ? visit.start <= millis(window.arrivalClosesAt) : visit.start < millis(window.arrivalClosesAt)));
    if (!windows.length) add("PORTAL_AVAILABILITY_MISSING", [visit]);
    else if (!receiving.length) add(visit.start < Math.min(...windows.map(window => millis(window.opensAt))) ? "EARLY_ARRIVAL" : "ARRIVAL_OUTSIDE_WINDOW", [visit], { at: stamp(visit.startsAt) });
    if (receiving.length && !receiving.some(window => visit.end <= millis(window.physicalClosesAt))) add("END_OUTSIDE_WINDOW", [visit]);
    if (visit.timingEvidence !== "reservation_occupation_only" && receiving.length && !receiving.some(window => visit.durationSeconds >= window.visitSeconds && visit.bufferSeconds >= window.bufferSeconds)) add("SERVICE_OR_BUFFER_TOO_SHORT", [visit]);
    if (receiving.length && visit.children !== null && !receiving.some(window => visit.children <= window.maxChildren)) add("CHILD_CAPACITY", [visit]);
    if (visit.kind === "ordinary" && Number.isFinite(millis(groups.get(visit.groupCode)?.ordinaryStopAt)) && visit.timingEvidence !== "reservation_occupation_only" && visit.serviceEnd > millis(groups.get(visit.groupCode).ordinaryStopAt)) add("ORDINARY_STOP_LIMIT", [visit]);
    if (visit.kind === "finale" && visit.source !== "actual") {
      const group = groups.get(visit.groupCode);
      if (Number.isFinite(millis(group?.scheduledFinaleAt)) && visit.start !== millis(group.scheduledFinaleAt)) add("FINALE_APPOINTMENT_MISMATCH", [visit]);
      if (Number.isFinite(millis(group?.latestCompletionAt)) && visit.serviceEnd > millis(group.latestCompletionAt)) add("GROUP_COMPLETION_LIMIT", [visit]);
    }
  }
  for (const groupCode of groups.keys()) {
    const own = visits.filter(visit => visit.groupCode === groupCode);
    for (const physical of unique(own.map(visit => visit.physicalCode))) { const repeated = own.filter(visit => visit.physicalCode === physical); if (repeated.length > 1) add("DUPLICATE_PHYSICAL_VISIT", repeated, { visits: repeated.length }); }
    for (let i = 0; i < own.length; i++) for (let j = i + 1; j < own.length; j++) {
      const a = own[i], b = own[j];
      if (a.timingEvidence !== "reservation_occupation_only" && b.timingEvidence !== "reservation_occupation_only" && a.start < b.serviceEnd && b.start < a.serviceEnd) add("GROUP_OVERLAP", [a,b]);
    }
  }
  for (const physical of unique(visits.map(visit => visit.physicalCode))) {
    const items = visits.filter(visit => visit.physicalCode === physical && Number.isFinite(visit.start)).sort((a,b) => a.start - b.start || a.groupCode.localeCompare(b.groupCode));
    for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) {
      const a = items[i], b = items[j], headway = Math.max(a.portal?.headwaySeconds ?? 300, b.portal?.headwaySeconds ?? 300);
      if (a.groupCode !== b.groupCode && b.start - a.start < headway * 1000) add("ARRIVAL_HEADWAY", [a,b], { earlierAt: stamp(a.startsAt), laterAt: stamp(b.startsAt), requiredSeconds: headway, actualSeconds: (b.start - a.start) / 1000 });
    }
    for (const at of unique(items.map(visit => visit.start))) {
      const active = items.filter(visit => visit.start <= at && visit.end > at), groupCodes = unique(active.map(visit => visit.groupCode));
      const capacities = active.flatMap(visit => (visit.portal?.windows ?? []).filter(window => at >= millis(window.opensAt) && at <= millis(window.physicalClosesAt)).map(window => window.maxGroups)).filter(Number.isFinite);
      if (capacities.length && groupCodes.length > Math.min(...capacities)) add("GROUP_CAPACITY", active, { at: new Date(at).toISOString(), actualGroups: groupCodes.length, allowedGroups: Math.min(...capacities) });
      const childCaps=active.flatMap(visit=>(visit.portal?.windows??[]).filter(window=>at>=millis(window.opensAt)&&at<=millis(window.physicalClosesAt)).map(window=>window.maxConcurrentChildren)).filter(value=>typeof value==="number"&&Number.isFinite(value));
      const children=groupCodes.map(group=>Math.max(...active.filter(visit=>visit.groupCode===group).map(visit=>visit.children??NaN)));
      if(childCaps.length&&children.every(Number.isFinite)&&children.reduce((sum,n)=>sum+n,0)>Math.min(...childCaps))add("CONCURRENT_CHILD_CAPACITY",active,{at:new Date(at).toISOString(),actualChildren:children.reduce((sum,n)=>sum+n,0),allowedChildren:Math.min(...childCaps)});
    }
    const counts = unique(items.map(visit => visit.groupCode)).map(group => Math.max(...items.filter(visit => visit.groupCode === group).map(visit => visit.children ?? NaN)));
    const totals = items.flatMap(visit => (visit.portal?.windows ?? []).filter(window=>visit.start>=millis(window.opensAt)&&(window.arrivalCloseInclusive?visit.start<=millis(window.arrivalClosesAt):visit.start<millis(window.arrivalClosesAt))).map(window => window.maxTotalChildren)).filter(Number.isFinite);
    if (totals.length && counts.every(Number.isFinite) && counts.reduce((sum,n)=>sum+n,0) > Math.min(...totals)) add("TOTAL_CHILD_CAPACITY", items, { actualChildren: counts.reduce((sum,n)=>sum+n,0), allowedChildren: Math.min(...totals) });
  }
  const byGroup = [...groups.values()].map(group => {
    const own = visits.filter(visit => visit.groupCode === group.code), ordinary = own.filter(visit => visit.kind === "ordinary");
    return { code: code(group.code), ordinaryVisits: own.length ? unique(ordinary.map(visit => visit.physicalCode)).length : null, computed: own.length>0, hasStoredSchedule: group.hasStoredSchedule===true, finales: own.filter(visit => visit.kind === "finale").length,
      administrativeStarts: administrative.filter(visit => visit.groupCode === group.code).length, requiresStepFree: group.requiresStepFree === true,
      accessibilityReviewChildren: group.accessibilityReviewChildren ?? 0, conflictCodes: unique(conflicts.filter(conflict => conflict.groupCodes.includes(group.code)).map(conflict => conflict.code)) };
  }).sort((a,b)=>a.code.localeCompare(b.code));
  const count = name => conflicts.filter(conflict => conflict.code === name).length;
  return { counts: { physicalVisits: visits.length, ordinaryVisits: visits.filter(visit => visit.kind === "ordinary").length, finaleVisits: visits.filter(visit => visit.kind === "finale").length,
    administrativeStarts: administrative.length, unknownVisitTimes: count("VISIT_TIME_UNKNOWN"), unknownServiceTiming: count("SERVICE_TIMING_UNKNOWN"), earlyVisits: count("EARLY_ARRIVAL"),
    lateOrClosedArrivals: count("ARRIVAL_OUTSIDE_WINDOW"), forbiddenEnds: count("END_OUTSIDE_WINDOW"), serviceOrBufferViolations: count("SERVICE_OR_BUFFER_TOO_SHORT"),
    headwayPairs: count("ARRIVAL_HEADWAY"), groupCapacityConflicts: count("GROUP_CAPACITY"), childCapacityConflicts: count("CHILD_CAPACITY"), concurrentChildCapacityConflicts: count("CONCURRENT_CHILD_CAPACITY"), totalChildCapacityConflicts: count("TOTAL_CHILD_CAPACITY"),
    duplicateGroupPhysicalVisits: count("DUPLICATE_PHYSICAL_VISIT"), finaleMismatches: count("FINALE_APPOINTMENT_MISMATCH"), completionOverruns: count("GROUP_COMPLETION_LIMIT"),
    groupOverlaps: count("GROUP_OVERLAP"), ordinaryStopViolations: count("ORDINARY_STOP_LIMIT"), zeroOrdinaryGroups: byGroup.filter(group => group.ordinaryVisits === 0).length, uncomputedGroups: byGroup.filter(group=>!group.computed).length, missingAvailability: count("PORTAL_AVAILABILITY_MISSING") }, byGroup, conflicts };
}

// Whitelist each exported field. No original planner input, UUID, note, name,
// coordinate, address, email or opaque node identifier crosses this boundary.
export function codedJointProposal(input, proposal, beforeConflicts, readAt, codeMaps = {}) {
  const groupCodes = new Map(input.groups.map(group => [group.id, code(group.code)])), portalCodes = new Map(input.portals.map(portal => [portal.id, code(portal.code)]));
  for(const [id,value]of Object.entries(codeMaps.groups??{}))groupCodes.set(id,code(value));
  for(const [id,value]of Object.entries(codeMaps.portals??{}))portalCodes.set(id,code(value));
  const groupCode = id => groupCodes.get(id) ?? "UNKNOWN_GROUP", portalCode = id => portalCodes.get(id) ?? "UNKNOWN_PORTAL";
  const diagnostic = value => ({ code: code(value.code), severity: value.severity === "block" ? "block" : "warning", groupCode: value.groupId ? groupCode(value.groupId) : null,
    portalCode: value.portalId ? portalCode(value.portalId) : null, message: readableDiagnostic[value.code] ?? "Controleer dit gecodeerde planningsknelpunt in de beheeromgeving." });
  const metrics = value => ({ groups: numeric(value.groups), totalOrdinaryVisits: numeric(value.totalOrdinaryVisits), minOrdinaryVisits: numeric(value.minOrdinaryVisits), meanOrdinaryVisits: numeric(value.meanOrdinaryVisits),
    maxOrdinaryVisits: numeric(value.maxOrdinaryVisits), zeroVisitGroups: numeric(value.zeroVisitGroups), walkingSeconds: numeric(value.walkingSeconds), waitingSeconds: numeric(value.waitingSeconds),
    receptionWaitingSeconds: numeric(value.receptionWaitingSeconds), unallocatedBeforeFinaleSeconds: numeric(value.unallocatedBeforeFinaleSeconds),
    longestWaitSeconds: numeric(value.longestWaitSeconds), unvisitedPortals: (value.unvisitedPortals ?? []).map(portalCode),
    absoluteEndDeviationSeconds: numeric(value.absoluteEndDeviationSeconds), overrunSeconds: numeric(value.overrunSeconds), administrativeStarts: numeric(value.administrativeStarts),
    byGroup: value.byGroup.map(group => ({ code: groupCode(group.groupId), ordinaryVisits: numeric(group.ordinaryVisits), walkingSeconds: numeric(group.walkingSeconds), waitingSeconds: numeric(group.waitingSeconds),
      receptionWaitingSeconds: numeric(group.receptionWaitingSeconds), longestWaitSeconds: numeric(group.longestWaitSeconds),
      endDeviationSeconds: numeric(group.endDeviationSeconds), finaleArrivalAt: stamp(group.finaleArrivalAt), unallocatedBeforeFinaleSeconds: numeric(group.unallocatedBeforeFinaleSeconds) })),
    byPortal: value.byPortal.map(portal => ({ code: portalCode(portal.portalId), visits: numeric(portal.visits), usableOpenSeconds: numeric(portal.usableOpenSeconds), visitsPerOpenHour: numeric(portal.visitsPerOpenHour),
      firstArrivalAt: stamp(portal.firstArrivalAt), firstDelaySeconds: numeric(portal.firstDelaySeconds), largestGapSeconds: numeric(portal.largestGapSeconds),
      quarterHourBuckets: portal.quarterHourBuckets.map(bucket => ({ startsAt: stamp(bucket.startsAt), visits: numeric(bucket.visits) })),
      remainingGapReason: !portal.explanation ? null : portal.usableOpenSeconds > 0 ? "NO_BETTER_JOINT_ALTERNATIVE_FOUND_NOT_IMPOSSIBILITY_PROOF"
        : "NO_DIRECT_REACHABLE_RECEPTION_WITHIN_WINDOWS_ACCESSIBILITY_AND_WALKING_BUDGET_INDIRECT_ROUTE_NOT_RULED_OUT" })) });
  const plans = values => values.map(plan => {
    const source = input.groups.find(group => group.id === plan.groupId);
    const ordinary = plan.visits.filter(visit => visit.kind === "ordinary").sort((a,b)=>a.sequence-b.sequence), last = ordinary.at(-1);
    return { code: groupCode(plan.groupId), startsAt: stamp(plan.startsAt), storedStartsAt: stamp(source?.startsAt), startUnchanged: millis(plan.startsAt) === millis(source?.startsAt), desiredEndAt: stamp(source?.desiredEndAt),
      storedFinaleAt: stamp(source?.finale.reservedAt), finaleArrivalAt: stamp(plan.finaleArrivalAt), finaleUnchanged: millis(plan.finaleArrivalAt) === millis(source?.finale.reservedAt),
      finaleChange: plan.finaleChange ? { portalCode: portalCode(plan.finaleChange.portalId), previousReservedAt: stamp(plan.finaleChange.previousReservedAt), proposedReservedAt: stamp(plan.finaleChange.proposedReservedAt) } : null,
      ordinaryEndsAt: last&&Number.isFinite(millis(last.startsAt)) ? new Date(millis(last.startsAt)+last.visitSeconds*1000).toISOString() : null, expectedCompletionAt: stamp(plan.expectedCompletionAt),
      diagnostics: (plan.diagnostics ?? []).map(diagnostic), visits: plan.visits.map(visit => ({ portalCode: portalCode(visit.portalId), kind: ["ordinary","finale","start"].includes(visit.kind) ? visit.kind : "unknown",
        sequence: numeric(visit.sequence), startsAt: stamp(visit.startsAt), visitSeconds: numeric(visit.visitSeconds), bufferSeconds: numeric(visit.bufferSeconds), walkSeconds: numeric(visit.walkSeconds), walkMeters: numeric(visit.walkMeters), waitSeconds: numeric(visit.waitSeconds ?? 0) })) };
  });
  const fingerprint = value => typeof value === "string" && /^[a-f0-9]{16,128}$/i.test(value) ? value : null;
  return { code: "READ_ONLY_CODED_JOINT_ROUTE_PROPOSAL", available: true, readOnly: true, databaseReadOnly: true, authorizedExistingAdmin: true, inputFunctionStable: true, readAt: stamp(readAt),
    sourceHash: fingerprint(proposal.sourceHash), boardHash: fingerprint(proposal.boardHash), proposalHash: fingerprint(proposal.proposalHash),
    maxGroupOverrunSeconds: numeric(input.maxGroupOverrunSeconds),
    walkingPolicy: { maxOrdinaryLegSeconds: numeric(input.maxLegWalkingSeconds), maxTotalSeconds: numeric(input.maxTotalWalkingSeconds), finaleLegLimitSeconds: null },
    before: { valid: !beforeConflicts.some(conflict => conflict.severity === "block"), conflicts: beforeConflicts.map(diagnostic), metrics: metrics(proposal.metrics.before), groups: plans(input.before) },
    after: { valid: proposal.valid, conflicts: proposal.conflicts.map(diagnostic), metrics: metrics(proposal.metrics.after), groups: plans(proposal.groups) },
    work: { candidateEvaluations: numeric(proposal.work.candidateEvaluations), variants: numeric(proposal.work.variants), pairReplans: numeric(proposal.work.pairReplans), routeRepairs: numeric(proposal.work.routeRepairs), exhausted: proposal.work.exhausted === true },
    saved: false, applied: false, published: false, changedRows: 0, messagesSent: 0 };
}
