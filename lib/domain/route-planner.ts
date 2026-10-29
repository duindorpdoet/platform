import { dominantEndPreference, dominantStartPreference, explicitOrdinaryStopPreference } from "./start-preference";
export type StartTimePreference = "early" | "indifferent" | "later";

export type PlanningParty = {
  id: string;
  childCount: number;
  startPreference?: StartTimePreference;
  requestedStopAt?: string | null;
  paymentEligible?: boolean;
  preferredStartAt?: string | null;
  desiredEndAt?: string | null;
  togetherKey?: string;
  togetherOverride?: boolean;
  /** Preserve a route group when only distributing existing groups over slots. */
  fixedGroupId?: string;
};

export type PlanningStart = {
  id: string;
  startPointId: string;
  startsAt: string;
  maxGroups: number;
  maxChildren: number;
  pointName?: string;
  availableFrom?: string | null;
  availableUntil?: string | null;
  portalOpensAt?: string | null;
  portalClosesAt?: string | null;
  markerValid?: boolean;
};

export type PlanningConflict = { code: string; subjectId?: string; message: string };
export type PreferenceMatch = "good" | "small_deviation" | "large_deviation" | "neutral";
export type PartyPreferenceDetail = {
  partyId: string;
  preferredStartAt: string | null;
  startPreference: StartTimePreference;
  deviationMinutes: number | null;
  match: PreferenceMatch;
};
export type ExistingPlanningSchedule = {
  /** Stable schedule ID: a duplicate snapshot row must not consume capacity twice. */
  id: string;
  /** Current draft and still-published revision can reserve two starts for the same physical group. */
  groupId?: string;
  startId: string;
  /** Physical reservation survives hidden slots and aliases of the same departure. */
  startPointId?: string;
  startsAt?: string;
  childCount: number;
  expectedFinaleArrivalAt: string;
  finaleEndsAt?: string | null;
  /** Already assigned households are excluded from a later proposal. */
  partyIds?: string[];
};
export type PlannedGroup = {
  key: string;
  partyIds: string[];
  childCount: number;
  startId: string;
  dominantStartAt: string | null;
  dominantEndAt: string | null;
  effectiveStopAt: string;
  expectedFinaleArrivalAt: string;
  expectedCompletionAt: string;
  physicalFinaleEndsAt: string;
  /** Signed minutes: negative is early, positive is overrun. */
  endDeviationMinutes: number | null;
  ordinaryRouteLostMinutes: number;
  ordinaryStopShortenedMinutes: number;
  endAssessment: "on_target" | "early" | "overrun" | "no_preference";
  preferenceMatch: PreferenceMatch;
  preferenceDetails: PartyPreferenceDetail[];
  maxPreferenceDeviationMinutes: number | null;
  warnings: string[];
  explanation: string;
};

export type PlanningInput = {
  parties: PlanningParty[];
  starts: PlanningStart[];
  targetGroupSize: number;
  maxGroupSize: number;
  globalOrdinaryStopAt: string;
  finaleOpensAt: string;
  finaleLastArrivalAt: string;
  finaleClosesAt: string;
  /** Supplied by the server policy in the planning snapshot. */
  maxGroupOverrunSeconds: number;
  finaleShowSeconds: number;
  finaleTurnoverSeconds: number;
  finalePlanningTransferSeconds: number;
  finaleWindows?: Array<{ opensAt: string; closesAt: string; maxGroups: number; maxChildren: number; maxTotalChildren: number }>;
  finaleMaxGroups: number;
  finaleMaxChildren: number;
  earlyPreferenceLatestAt?: string | null;
  laterPreferenceEarliestAt?: string | null;
  preferenceGreenMinutes?: number;
  preferenceAmberMinutes?: number;
  /** Existing active draft/published reservations, once per schedule ID. Never pass reduced slot maxima too. */
  existingSchedules?: ExistingPlanningSchedule[];
};

function stable<T extends { id: string }>(items: T[]) {
  return [...items].sort((a, b) => a.id.localeCompare(b.id));
}

function millis(value: string | null | undefined) {
  const parsed = value ? Date.parse(value) : Number.NaN;
  return Number.isFinite(parsed) ? parsed : null;
}

function groupPreference(parties: PlanningParty[]): StartTimePreference {
  const values = new Set(parties.map((party) => party.startPreference ?? "indifferent").filter((value) => value !== "indifferent"));
  if (values.size > 1) return "indifferent";
  return values.values().next().value ?? "indifferent";
}

function preferenceScore(preference: StartTimePreference, startAt: number, input: PlanningInput, preferredStartAt?: number | null) {
  if (preferredStartAt !== null && preferredStartAt !== undefined) return Math.abs(startAt - preferredStartAt);
  if (preference === "indifferent") return 0;
  const earlyLimit = millis(input.earlyPreferenceLatestAt);
  const laterLimit = millis(input.laterPreferenceEarliestAt);
  if (preference === "early") {
    if (earlyLimit === null) return startAt;
    return startAt <= earlyLimit ? 0 : startAt - earlyLimit;
  }
  if (laterLimit === null) return -startAt;
  return startAt >= laterLimit ? 0 : laterLimit - startAt;
}

function matchFor(preference: StartTimePreference, startAt: number, input: Pick<PlanningInput,
  "earlyPreferenceLatestAt" | "laterPreferenceEarliestAt" | "preferenceGreenMinutes" | "preferenceAmberMinutes"
>, preferredStartAt?: number | null): PreferenceMatch {
  if (preferredStartAt !== null && preferredStartAt !== undefined) {
    const deviation = Math.abs(startAt - preferredStartAt) / 60_000;
    if (deviation <= (input.preferenceGreenMinutes ?? 15)) return "good";
    if (deviation <= (input.preferenceAmberMinutes ?? 30)) return "small_deviation";
    return "large_deviation";
  }
  if (preference === "indifferent") return "neutral";
  const earlyLimit = millis(input.earlyPreferenceLatestAt);
  const laterLimit = millis(input.laterPreferenceEarliestAt);
  if (preference === "early") {
    if (earlyLimit === null || startAt <= earlyLimit) return "good";
    if (laterLimit === null || startAt < laterLimit) return "small_deviation";
    return "large_deviation";
  }
  if (laterLimit === null || startAt >= laterLimit) return "good";
  if (earlyLimit === null || startAt > earlyLimit) return "small_deviation";
  return "large_deviation";
}

/** Report the least satisfied household, while slot selection uses the dominant registration preference. */
export function evaluatePartyPreferences(parties: PlanningParty[], startsAt: string | number, input: Pick<PlanningInput,
  "earlyPreferenceLatestAt" | "laterPreferenceEarliestAt" | "preferenceGreenMinutes" | "preferenceAmberMinutes"
>): { preferenceMatch: PreferenceMatch; preferenceDetails: PartyPreferenceDetail[]; maxPreferenceDeviationMinutes: number | null } {
  const startAt = typeof startsAt === "number" ? startsAt : Date.parse(startsAt);
  const preferenceDetails = stable(parties).map((party): PartyPreferenceDetail => {
    const preferred = millis(party.preferredStartAt);
    const preference = party.startPreference ?? "indifferent";
    const boundary = preference === "early" ? millis(input.earlyPreferenceLatestAt) : preference === "later" ? millis(input.laterPreferenceEarliestAt) : null;
    const deviation = preferred !== null ? Math.abs(startAt - preferred)
      : boundary === null ? null : preference === "early" ? Math.max(0, startAt - boundary) : Math.max(0, boundary - startAt);
    return {
      partyId: party.id, preferredStartAt: party.preferredStartAt ?? null, startPreference: preference,
      deviationMinutes: deviation === null ? null : Math.ceil(deviation / 60_000),
      match: matchFor(preference, startAt, input, preferred),
    };
  });
  const ranks: Record<PreferenceMatch, number> = { neutral: 0, good: 1, small_deviation: 2, large_deviation: 3 };
  const preferenceMatch = preferenceDetails.reduce<PreferenceMatch>((worst, detail) => ranks[detail.match] > ranks[worst] ? detail.match : worst, "neutral");
  const deviations = preferenceDetails.flatMap((detail) => detail.deviationMinutes === null ? [] : [detail.deviationMinutes]);
  return { preferenceMatch, preferenceDetails, maxPreferenceDeviationMinutes: deviations.length ? Math.max(...deviations) : null };
}

export function proposePlan(input: PlanningInput): { groups: PlannedGroup[]; conflicts: PlanningConflict[] } {
  const conflicts: PlanningConflict[] = [];
  const globalStop = millis(input.globalOrdinaryStopAt);
  const finaleOpen = millis(input.finaleOpensAt);
  const finaleLast = millis(input.finaleLastArrivalAt);
  const finaleClose = millis(input.finaleClosesAt);
  if (!input.starts.length) conflicts.push({ code: "NO_START_SLOTS", message: "Voeg ten minste één bevestigd startpunt met een exact tijdstip toe." });
  if (![input.maxGroupSize,input.targetGroupSize].every(value=>Number.isSafeInteger(value)&&value>=1&&value<=2147483647) || input.targetGroupSize > input.maxGroupSize) conflicts.push({ code: "INVALID_GROUP_LIMIT", message: "De gewenste groepsgrootte valt buiten de grens." });
  const missingTimes = [
    { value: globalStop, label: "stoppen bij gewone huizen" },
    { value: finaleOpen, label: "opening laatste poort" },
    { value: finaleLast, label: "laatste aankomst bij de laatste poort" },
    { value: finaleClose, label: "sluiting laatste poort" },
  ].filter(({ value }) => value === null).map(({ label }) => label);
  if (missingTimes.length) conflicts.push({ code: "ROUTE_CONFIGURATION_INCOMPLETE", message: `Vul bij Kaders de ontbrekende tijden in en sla ze op: ${missingTimes.join(", ")}.` });
  if (!Number.isSafeInteger(input.maxGroupOverrunSeconds) || input.maxGroupOverrunSeconds < 0) conflicts.push({ code: "PLANNING_POLICY_MISSING", message: "Vernieuw de planning om het serverbeleid voor maximale groepsuitloop op te halen." });
  if (![input.finaleTurnoverSeconds,input.finalePlanningTransferSeconds,input.finaleShowSeconds,input.finaleMaxGroups,input.finaleMaxChildren].every(Number.isSafeInteger) || input.finaleTurnoverSeconds < 0 || input.finalePlanningTransferSeconds < 0 || input.finaleShowSeconds < 60 || input.finaleMaxGroups < 1 || input.finaleMaxChildren < 1) conflicts.push({ code: "INVALID_FINALE_CAPACITY", message: "De eindpoortcapaciteit is niet geldig." });
  const serviceMs = (input.finaleShowSeconds + input.finaleTurnoverSeconds) * 1_000;
  const existingSchedules = new Map<string, ExistingPlanningSchedule>();
  const physicalStart = (pointId: string, startsAt: number) => `${pointId}:${startsAt}`;
  const allStartsById = new Map(input.starts.map(start => [start.id, start]));
  const existingDeparture = (schedule: ExistingPlanningSchedule) => {
    const slot = allStartsById.get(schedule.startId);
    const pointId = schedule.startPointId ?? slot?.startPointId;
    const startsAt = millis(schedule.startsAt ?? slot?.startsAt);
    return pointId && startsAt !== null ? { key: physicalStart(pointId, startsAt), pointId, startsAt } : null;
  };
  for (const schedule of input.existingSchedules ?? []) {
    const arrival = millis(schedule.expectedFinaleArrivalAt);
    const end = schedule.finaleEndsAt ? millis(schedule.finaleEndsAt) : arrival === null ? null : arrival + serviceMs;
    if (!schedule.id || !schedule.startId || !existingDeparture(schedule) || !Number.isInteger(schedule.childCount) || schedule.childCount < 0 || arrival === null || end === null || end <= arrival) {
      conflicts.push({ code: "INVALID_EXISTING_RESERVATION", subjectId: schedule.id, message: "Een bestaande afspraak heeft ongeldige capaciteitsgegevens. Controleer de opgeslagen planning." });
      continue;
    }
    const previous = existingSchedules.get(schedule.id);
    if (previous && (previous.groupId !== schedule.groupId || previous.startId !== schedule.startId || existingDeparture(previous)?.key !== existingDeparture(schedule)?.key || previous.childCount !== schedule.childCount
      || millis(previous.expectedFinaleArrivalAt) !== arrival
      || (previous.finaleEndsAt ? millis(previous.finaleEndsAt) : millis(previous.expectedFinaleArrivalAt)! + serviceMs) !== end
      || JSON.stringify([...(previous.partyIds ?? [])].sort()) !== JSON.stringify([...(schedule.partyIds ?? [])].sort()))) {
      conflicts.push({ code: "EXISTING_SCHEDULE_CONFLICT", subjectId: schedule.id, message: "Dezelfde bestaande afspraak heeft verschillende revisiegegevens. Vernieuw de planning." });
      continue;
    }
    existingSchedules.set(schedule.id, schedule);
  }
  if (conflicts.length) return { groups: [], conflicts };

  const starts = input.starts.filter((start) => {
    const value = Date.parse(start.startsAt);
    const availableFrom = millis(start.availableFrom);
    const availableUntil = millis(start.availableUntil);
    const portalOpensAt = millis(start.portalOpensAt);
    const portalClosesAt = millis(start.portalClosesAt);
    return Number.isFinite(value) && value % 600_000 === 0 && start.maxGroups >= 1 && start.maxChildren >= 1 && start.markerValid !== false
      && (availableFrom === null || value >= availableFrom)
      && (availableUntil === null || value <= availableUntil)
      && (portalOpensAt === null || value >= portalOpensAt)
      && (portalClosesAt === null || value <= portalClosesAt);
  }).sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.id.localeCompare(b.id));
  const clusters = new Map<string, PlanningParty[]>();
  const reservedGroupIds = new Set([...existingSchedules.values()].flatMap(schedule => schedule.groupId ? [schedule.groupId] : []));
  const suppliedReservedGroups = new Set(input.parties.flatMap(party => party.fixedGroupId && reservedGroupIds.has(party.fixedGroupId) ? [party.fixedGroupId] : []));
  for (const groupId of [...suppliedReservedGroups].sort()) {
    conflicts.push({ code: "GROUP_ALREADY_SCHEDULED", subjectId: groupId, message: "Deze groep heeft al een bestaande startafspraak. Verwijder een bewerkbaar concept bewust uit de invoer voordat je opnieuw verdeelt; bevestigde en gepubliceerde afspraken blijven behouden." });
  }
  if (conflicts.length) return { groups: [], conflicts };
  const assignedPartyIds = new Set([...existingSchedules.values()].flatMap((schedule) => schedule.partyIds ?? []));
  for (const party of stable(input.parties).filter((party) => !assignedPartyIds.has(party.id))) {
    const key = party.fixedGroupId ? `fixed:${party.fixedGroupId}` : party.togetherKey ? `together:${party.togetherKey}` : `party:${party.id}`;
    clusters.set(key, [...(clusters.get(key) ?? []), party]);
  }
  const bundles = [...clusters.entries()].map(([key, parties]) => ({
    key,
    parties,
    size: parties.reduce((sum, party) => sum + party.childCount, 0),
    capacityOverride: parties.some((party) => party.togetherOverride),
    preference: groupPreference(parties),
  })).sort((a, b) => b.size - a.size || a.key.localeCompare(b.key));

  for (const bundle of bundles) {
    if (bundle.size > input.maxGroupSize) conflicts.push({ code: "TOGETHER_PARTY_TOO_LARGE", subjectId: bundle.key, message: `${bundle.key} bevat ${bundle.size} kinderen; maximaal ${input.maxGroupSize}.` });
  }
  if (conflicts.length) return { groups: [], conflicts };

  const draftGroups: Array<{ key: string; parties: PlanningParty[]; childCount: number; capacityOverride: boolean; preference: StartTimePreference }> = [];
  for (const bundle of bundles) {
    const preference = bundle.preference as StartTimePreference;
    const preferred = draftGroups
      .filter((group) => !bundle.parties.some(p => p.fixedGroupId) && !group.parties.some(p => p.fixedGroupId) && !bundle.capacityOverride && !group.capacityOverride
        && group.childCount + bundle.size <= input.maxGroupSize
        && (group.preference === "indifferent" || preference === "indifferent" || group.preference === preference))
      .sort((a, b) => a.childCount - b.childCount || a.key.localeCompare(b.key))[0];
    if (preferred && preferred.childCount < input.targetGroupSize) {
      preferred.parties.push(...bundle.parties);
      preferred.childCount += bundle.size;
      if (preferred.preference === "indifferent") preferred.preference = preference;
    } else {
      draftGroups.push({ key: bundle.parties[0].fixedGroupId ?? `group-${String(draftGroups.length + 1).padStart(3, "0")}`, parties: [...bundle.parties], childCount: bundle.size, capacityOverride: bundle.capacityOverride, preference });
    }
  }

  // Slot IDs and gathering capacity do not create additional physical departures.
  const physicalStarts = new Map<string, PlanningStart>();
  for (const start of starts) {
    const key = physicalStart(start.startPointId, Date.parse(start.startsAt));
    const previous = physicalStarts.get(key);
    physicalStarts.set(key, previous ? { ...previous, maxChildren: Math.min(previous.maxChildren, start.maxChildren) } : start);
  }
  const candidateStarts = [...physicalStarts.values()];
  const startLoads = new Map<string, { groups: number; children: number }>();
  const finaleReservations: Array<{ groupKey: string; startsAt: number; endsAt: number; children: number }> = [];
  const existingStartReservations = new Map<string, { physicalKey: string; children: number }>();
  for (const schedule of existingSchedules.values()) {
    const groupKey = `existing:${schedule.groupId ?? schedule.id}`;
    const physicalKey = existingDeparture(schedule)!.key;
    const reservationKey = `${groupKey}:${physicalKey}`;
    const previous = existingStartReservations.get(reservationKey);
    existingStartReservations.set(reservationKey, { physicalKey, children: Math.max(previous?.children ?? 0, schedule.childCount) });
    const startsAt = millis(schedule.expectedFinaleArrivalAt)!;
    finaleReservations.push({ groupKey, startsAt, endsAt: schedule.finaleEndsAt ? millis(schedule.finaleEndsAt)! : startsAt + serviceMs, children: schedule.childCount });
  }
  for (const reservation of existingStartReservations.values()) {
    const load = startLoads.get(reservation.physicalKey) ?? { groups: 0, children: 0 };
    load.groups += 1;
    load.children += reservation.children;
    startLoads.set(reservation.physicalKey, load);
  }
  const showMs = input.finaleShowSeconds * 1_000;
  const transferMs = input.finalePlanningTransferSeconds * 1_000;
  type Reservation = typeof finaleReservations[number];
  const earliestStart = Math.min(...candidateStarts.map(s => Date.parse(s.startsAt)));
  const lastStart = Math.max(...candidateStarts.map(s => Date.parse(s.startsAt)));
  const prepared = draftGroups.map(group => {
    const dominantStartAt = dominantStartPreference(group.parties);
    const dominantEndAt = dominantEndPreference(group.parties);
    const preferredStart = millis(dominantStartAt);
    const desiredEnd = millis(dominantEndAt);
    const hardStop = Math.min(globalStop!, ...group.parties.flatMap(party => {
      const stop = millis(explicitOrdinaryStopPreference(party));
      return stop === null ? [] : [stop];
    }));
    const idealStop = Math.min(hardStop, desiredEnd === null ? hardStop : desiredEnd - showMs - transferMs);
    const latestArrival = Math.min(finaleLast!, finaleClose! - serviceMs,
      desiredEnd === null ? Infinity : desiredEnd + input.maxGroupOverrunSeconds * 1_000 - showMs);
    const possibleStarts = candidateStarts.filter(start => !startLoads.has(physicalStart(start.startPointId, Date.parse(start.startsAt)))
      && group.childCount <= start.maxChildren);
    const preferenceCost = (start: PlanningStart) => {
      const time = Date.parse(start.startsAt);
      // Normalize the legacy early/later ordering into minutes relative to this evening.
      const raw = preferenceScore(group.preference, time, input, preferredStart);
      const anchor = earliestStart;
      return preferredStart !== null || group.preference === "indifferent" ? raw / 60_000
        : group.preference === "early" && !input.earlyPreferenceLatestAt ? (raw - anchor) / 60_000
        : group.preference === "later" && !input.laterPreferenceEarliestAt ? (lastStart - time) / 60_000
        : raw / 60_000;
    };
    possibleStarts.sort((a, b) => preferenceCost(a) - preferenceCost(b)
      || (preferredStart === null ? 0 : Number(Date.parse(a.startsAt) < preferredStart) - Number(Date.parse(b.startsAt) < preferredStart))
      || Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.startPointId.localeCompare(b.startPointId) || a.id.localeCompare(b.id));
    const idealStart = possibleStarts[0] ? Date.parse(possibleStarts[0].startsAt) : preferredStart ?? idealStop;
    return { ...group, dominantStartAt, dominantEndAt, preferredStart, desiredEnd, hardStop, idealStop, latestArrival, possibleStarts, preferenceCost,
      idealRouteMinutes: Math.max(0, (idealStop - idealStart) / 60_000) };
  });
  type Prepared = typeof prepared[number];
  type Choice = { group: Prepared; start: PlanningStart; arrival: number; stop: number; cost: number; routeLoss: number; waiting: number };
  const fitsFinale = (arrival: number, children: number, reservations: Reservation[]) => {
    const windows = input.finaleWindows?.filter(w => arrival >= Date.parse(w.opensAt) && arrival + serviceMs <= Date.parse(w.closesAt) && children <= w.maxChildren);
    if (windows && !windows.length) return false;
    const overlaps = reservations.filter(r => arrival < r.endsAt && arrival + serviceMs > r.startsAt);
    const ticks = new Set([arrival, ...overlaps.filter(r => r.startsAt > arrival).map(r => r.startsAt)]);
    return [...ticks].every(tick => {
      const occupied = new Map<string, number>();
      for (const r of overlaps) if (r.startsAt <= tick && r.endsAt > tick) occupied.set(r.groupKey, Math.max(occupied.get(r.groupKey) ?? 0, r.children));
      const totalChildren = [...occupied.values()].reduce((sum, n) => sum + n, 0) + children;
      return occupied.size < input.finaleMaxGroups && totalChildren <= input.finaleMaxChildren
        && (!windows || windows.some(w => occupied.size < w.maxGroups && totalChildren <= w.maxTotalChildren));
    });
  };
  const reservationFor = (c: Choice): Reservation => ({ groupKey: `proposal:${c.group.key}`, startsAt: c.arrival, endsAt: c.arrival + serviceMs, children: c.group.childCount });
  const choose = (group: Prepared, choices: Choice[]): Choice | null => {
    const reservations = [...finaleReservations, ...choices.map(reservationFor)];
    const occupiedStarts = new Set(choices.map(c => physicalStart(c.start.startPointId, Date.parse(c.start.startsAt))));
    // Costs are piecewise linear except for a convex route-loss penalty. Minima
    // occur at target, availability and reservation boundaries, including seconds.
    const arrivals = [...new Set([finaleOpen!, group.latestArrival, group.idealStop + transferMs, group.hardStop + transferMs,
      ...(group.desiredEnd === null ? [] : [group.desiredEnd - showMs]),
      ...reservations.flatMap(r => [r.endsAt, r.startsAt - serviceMs]),
      ...(input.finaleWindows ?? []).flatMap(w => [Date.parse(w.opensAt), Date.parse(w.closesAt) - serviceMs])])]
      .filter(a => a >= finaleOpen! && a <= group.latestArrival).sort((a, b) => a - b);
    const fits = new Map<number, boolean>();
    let best: Choice | null = null;
    for (const start of group.possibleStarts) {
      const startAt = Date.parse(start.startsAt);
      if (occupiedStarts.has(physicalStart(start.startPointId, startAt)) || startAt > group.hardStop) continue;
      const earliest = Math.max(finaleOpen!, startAt + transferMs);
      for (const arrival of new Set([...arrivals, earliest])) {
        if (arrival < earliest || arrival > group.latestArrival) continue;
        const stop = Math.min(group.hardStop, arrival - transferMs);
        const routeLoss = Math.max(0, group.idealRouteMinutes - (stop - startAt) / 60_000);
        const waiting = Math.max(0, (arrival - transferMs - group.hardStop) / 60_000);
        const rawDeviation = (arrival + showMs - (group.desiredEnd ?? group.idealStop + transferMs + showMs)) / 60_000;
        const deviation = group.desiredEnd === null ? Math.min(0, rawDeviation) : rawDeviation;
        const cost = eveningCandidateCost({ startDeviationMinutes: group.preferenceCost(start), routeLostMinutes: routeLoss, endDeviationMinutes: deviation, waitingMinutes: waiting });
        if (best && cost >= best.cost - 1e-7) continue;
        let available = fits.get(arrival);
        if (available === undefined) { available = fitsFinale(arrival, group.childCount, reservations); fits.set(arrival, available); }
        if (available) best = { group, start, arrival, stop, cost, routeLoss, waiting };
      }
    }
    return best;
  };
  const byStart = (a: Prepared, b: Prepared) => (a.preferredStart ?? Infinity) - (b.preferredStart ?? Infinity)
    || (a.desiredEnd ?? Infinity) - (b.desiredEnd ?? Infinity) || a.key.localeCompare(b.key);
  const byConstraint = (a: Prepared, b: Prepared) => a.latestArrival - b.latestArrival
    || a.possibleStarts.length - b.possibleStarts.length || byStart(a, b);
  const allocate = (order: Prepared[]) => {
    const choices: Choice[] = [];
    for (const group of order) { const choice = choose(group, choices); if (choice) choices.push(choice); }
    return choices;
  };
  const totalCost = (choices: Choice[]) => choices.reduce((sum, c) => sum + c.cost, 0);
  const better = (a: Choice[], b: Choice[]) => a.length > b.length || a.length === b.length && totalCost(a) < totalCost(b) - 1e-7;
  // Bounded multi-start allocation: deadline-constrained, start-constrained and
  // reversed distributions. No input-order dependence or random/time-based cutoff.
  const constrained = [...prepared].sort(byConstraint);
  let best = allocate(constrained);
  for (const order of [[...prepared].sort(byStart), [...constrained].reverse()]) {
    const attempt = allocate(order); if (better(attempt, best)) best = attempt;
  }
  // Reinsert the worst affected group with each nearby competitor. This can free
  // a valuable late finale slot without moving a protected/existing reservation.
  const affected = [...prepared].sort((a, b) => (best.find(c => c.group === b)?.cost ?? Infinity) - (best.find(c => c.group === a)?.cost ?? Infinity) || byConstraint(a, b)).slice(0, 8);
  for (const group of affected) {
    const neighbours = [...prepared].filter(g => g !== group).sort((a, b) => Math.abs(a.latestArrival - group.latestArrival) - Math.abs(b.latestArrival - group.latestArrival) || byConstraint(a, b)).slice(0, 4);
    for (const other of neighbours) for (const order of [[group, other], [other, group]]) {
      const attempt = best.filter(c => c.group !== group && c.group !== other);
      for (const g of order) { const c = choose(g, attempt); if (c) attempt.push(c); }
      if (better(attempt, best)) best = attempt;
    }
  }
  const groups: PlannedGroup[] = [];
  for (const group of prepared.filter(g => !best.some(c => c.group === g))) {
    const remainingStarts = group.possibleStarts.filter(s => !best.some(c => physicalStart(c.start.startPointId, Date.parse(c.start.startsAt)) === physicalStart(s.startPointId, Date.parse(s.startsAt))));
    const eligibleStarts = remainingStarts.filter(s => Date.parse(s.startsAt) <= group.hardStop);
    const earliestArrival = Math.min(...eligibleStarts.map(s => Math.max(finaleOpen!, Date.parse(s.startsAt) + transferMs)));
    const time = (value: number) => Number.isFinite(value) ? new Date(value).toLocaleTimeString("nl-NL", { timeZone: "Europe/Amsterdam", hour: "2-digit", minute: "2-digit" }) : "geen passend moment";
    const windowFits = input.finaleWindows?.filter(w => Math.max(earliestArrival, Date.parse(w.opensAt)) <= Math.min(group.latestArrival, Date.parse(w.closesAt) - serviceMs));
    const childCapacity = Math.min(input.finaleMaxChildren, windowFits ? Math.max(0, ...windowFits.map(w => Math.min(w.maxChildren, w.maxTotalChildren))) : Infinity);
    const targetReason = group.desiredEnd === null ? "" : ` Gewenst klaar ${time(group.desiredEnd)}; uiterste groepsafronding ${time(group.desiredEnd + input.maxGroupOverrunSeconds * 1_000)}.`;
    let code: string;
    let message: string;
    if (!remainingStarts.length) {
      code = "START_CAPACITY_EXCEEDED";
      message = `Geen vrij tienminutenvertrek met voldoende capaciteit voor ${group.key}.`;
    } else if (group.desiredEnd !== null && Number.isFinite(earliestArrival) && earliestArrival + showMs > group.desiredEnd + input.maxGroupOverrunSeconds * 1_000) {
      code = "DESIRED_END_UNREACHABLE";
      message = `Vroegst haalbare afronding ${time(earliestArrival + showMs)} is ${Math.ceil((earliestArrival + showMs - group.desiredEnd) / 60_000)} minuten na de eindwens. Vertrek, overdracht en finaleopening passen niet binnen de groepsgrens.${targetReason}`;
    } else if (!eligibleStarts.length) {
      code = "ROUTE_TIME_CONFLICT";
      message = `Alle vrije vertrekken vallen na de harde gewone stop ${time(group.hardStop)}. Kies een eerder beschikbaar vertrek; finale-uitloop verlengt deze gewone routegrens niet.${targetReason}`;
    } else if (earliestArrival > group.latestArrival || windowFits?.length === 0) {
      code = "FINALE_WINDOW_CONFLICT";
      message = `Show van ${input.finaleShowSeconds / 60} minuten plus ${input.finaleTurnoverSeconds / 60} minuten wisseltijd past niet binnen het toegestane fysieke finalevenster: opening ${time(finaleOpen!)}, laatste aankomst ${time(finaleLast!)} en definitieve sluiting ${time(finaleClose!)}. Controleer ook de afzonderlijke poortopening.${targetReason}`;
    } else {
      code = "FINALE_CAPACITY_EXCEEDED";
      message = group.childCount > childCapacity
        ? `De groep heeft ${group.childCount} kinderen; de beschikbare finaleopening ontvangt maximaal ${childCapacity} kinderen per groep.${targetReason}`
        : `Geen vrije finaleplek gevonden tussen ${time(earliestArrival)} en ${time(group.latestArrival)} voor ${group.childCount} kinderen. De limiet blijft ${input.finaleMaxGroups} groepen en ${input.finaleMaxChildren} kinderen tegelijk, binnen de fysieke poortcapaciteit. De onderzochte herverdelingen geven geen passende plek.${targetReason}`;
    }
    conflicts.push({ code, subjectId: group.key, message });
  }
  for (const choice of best.sort((a, b) => Date.parse(a.start.startsAt) - Date.parse(b.start.startsAt) || byConstraint(a.group, b.group))) {
    const { group, start, stop, arrival, routeLoss, waiting } = choice;
    const warnings: string[] = [];
    if (group.parties.some(p => p.paymentEligible === false)) warnings.push("PAYMENT_NOT_CONFIRMED");
    const shortened = Math.max(0, (group.idealStop - stop) / 60_000);
    if (shortened > 0) warnings.push("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
    if (routeLoss > shortened) warnings.push("ORDINARY_ROUTE_LOST_START");
    const completion = arrival + showMs;
    const endDeviationMinutes = group.desiredEnd === null ? null : (completion - group.desiredEnd) / 60_000;
    if (endDeviationMinutes !== null && endDeviationMinutes > 0) warnings.push("GROUP_END_OVERRUN");
    if (endDeviationMinutes !== null && endDeviationMinutes < -30) warnings.push("GROUP_END_SIGNIFICANTLY_EARLY");
    if (waiting > 0) warnings.push("FINALE_CAPACITY_WAIT");
    const preferenceResult = evaluatePartyPreferences(group.parties, start.startsAt, input);
    if (preferenceResult.preferenceMatch === "large_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_DEVIATION");
    else if (preferenceResult.preferenceMatch === "small_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_CHECK");
    const startDeviation = group.preferredStart === null ? null : Math.abs(Date.parse(start.startsAt) - group.preferredStart) / 60_000;
    const startReason = startDeviation === null ? "Er is geen exacte starttijd opgegeven"
      : startDeviation === 0 ? "Dit moment ligt exact op de dominante startvoorkeur"
      : `Dit vertrek wijkt ${startDeviation} minuten af van de dominante startvoorkeur voor een betere totale avond`;
    const firstFinaleOpening = Math.max(finaleOpen!, Math.min(...(input.finaleWindows ?? [{ opensAt: input.finaleOpensAt }]).map(w => Date.parse(w.opensAt))));
    const overrunReason = group.desiredEnd !== null && firstFinaleOpening + showMs > group.desiredEnd
      ? "De finaleopening is te laat om de show op de streeftijd af te ronden. Controleer dit afzonderlijke venster."
      : group.desiredEnd !== null && Date.parse(start.startsAt) + transferMs + showMs > group.desiredEnd
        ? "Het beschikbare vertrek, de overdracht en de show passen samen pas na de streeftijd."
        : "Zo blijft meer tijd over voor gewone poorten; eerdere vrije finaleplekken geven in de onderzochte verdelingen meer routeverlies of startafwijking.";
    const endReason = endDeviationMinutes === null ? "" : endDeviationMinutes > 0
      ? ` ${Math.ceil(endDeviationMinutes)} minuten uitloop. ${overrunReason}`
      : endDeviationMinutes === 0 ? " De finale is op de gewenste eindtijd afgerond." : ` De finale is ${Math.ceil(-endDeviationMinutes)} minuten vóór de gewenste eindtijd afgerond.`;
    groups.push({ key: group.key, partyIds: group.parties.map(p => p.id).sort(), childCount: group.childCount, startId: start.id,
      dominantStartAt: group.dominantStartAt, dominantEndAt: group.dominantEndAt, effectiveStopAt: new Date(stop).toISOString(),
      expectedFinaleArrivalAt: new Date(arrival).toISOString(), expectedCompletionAt: new Date(completion).toISOString(), physicalFinaleEndsAt: new Date(arrival + serviceMs).toISOString(),
      endDeviationMinutes, ordinaryRouteLostMinutes: routeLoss, ordinaryStopShortenedMinutes: shortened,
      endAssessment: endDeviationMinutes === null ? "no_preference" : endDeviationMinutes > 0 ? "overrun" : endDeviationMinutes < 0 ? "early" : "on_target",
      ...preferenceResult, warnings,
      explanation: `${startReason}; één vertrek bij ${start.pointName ?? "het startpunt"} is gereserveerd.${endReason}${shortened > 0 ? ` Stop ${Math.ceil(shortened)} minuten eerder bij gewone poorten.` : ""}${routeLoss > 0 ? ` Er gaat ${Math.ceil(routeLoss)} minuten bruikbare routetijd verloren door de beschikbare vertrekken, finaleplekken en harde tijdgrenzen. Een betere verdeling is binnen de begrensde zoekstappen niet gevonden.` : ""}${waiting > 0 ? ` Na de gewone sluiting is ${Math.ceil(waiting)} minuten wachttijd nodig voor een vrije finaleplek; dit is geen bezoektijd.` : ""}` });
  }
  return { groups, conflicts };
}

/** Lower is better. Penalize early completion, overrun and lost useful route time
 * separately; waiting never improves a score merely by displaying a later end.
 * The convex loss term discourages sacrificing one group's entire evening.
 */
export function eveningCandidateCost(candidate: { startDeviationMinutes: number; routeLostMinutes: number; endDeviationMinutes: number; waitingMinutes?: number }): number {
  const early = Math.max(0, -candidate.endDeviationMinutes);
  const late = Math.max(0, candidate.endDeviationMinutes);
  return candidate.startDeviationMinutes * 0.5 + early + late * 2 + (late > 0 ? 5 : 0)
    + candidate.routeLostMinutes * 2 + candidate.routeLostMinutes ** 2 / 30 + (candidate.waitingMinutes ?? 0) * 1.5;
}
