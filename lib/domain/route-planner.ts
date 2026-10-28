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
  finaleShowSeconds: number;
  finaleTurnoverSeconds: number;
  finalePlanningTransferSeconds: number;
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
  if (input.finaleShowSeconds < 60 || input.finaleMaxGroups < 1 || input.finaleMaxChildren < 1) conflicts.push({ code: "INVALID_FINALE_CAPACITY", message: "De eindpoortcapaciteit is niet geldig." });
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
  const orderedGroups = draftGroups.map(group => ({
    ...group,
    dominantStartAt: dominantStartPreference(group.parties),
    dominantEndAt: dominantEndPreference(group.parties),
  })).sort((a, b) => {
    const preferenceAt = (group: typeof a) => millis(group.dominantStartAt)
      ?? (group.preference === "early" ? millis(input.earlyPreferenceLatestAt) ?? Number.NEGATIVE_INFINITY
        : group.preference === "later" ? millis(input.laterPreferenceEarliestAt) ?? Number.POSITIVE_INFINITY : Number.POSITIVE_INFINITY);
    return preferenceAt(a) - preferenceAt(b)
      || (millis(a.dominantEndAt) ?? Number.POSITIVE_INFINITY) - (millis(b.dominantEndAt) ?? Number.POSITIVE_INFINITY)
      || a.key.localeCompare(b.key);
  });
  const groups: PlannedGroup[] = [];
  for (const group of orderedGroups) {
    const preferredStartAt = millis(group.dominantStartAt);
    const desiredEndAt = millis(group.dominantEndAt);
    const requestedStops = group.parties.map(party => millis(explicitOrdinaryStopPreference(party))).filter((value): value is number => value !== null);
    // Desired completion, ordinary-portal stopping and finale occupancy are distinct limits.
    const effectiveStop = Math.min(globalStop!, ...requestedStops,
      desiredEndAt === null ? Number.POSITIVE_INFINITY : desiredEndAt - (input.finaleShowSeconds + input.finalePlanningTransferSeconds) * 1_000);
    const availableStarts = candidateStarts.filter(start => {
      const load = startLoads.get(physicalStart(start.startPointId, Date.parse(start.startsAt))) ?? { groups: 0, children: 0 };
      return load.groups === 0 && group.childCount <= start.maxChildren;
    }).sort((a, b) => {
      const aTime = Date.parse(a.startsAt);
      const bTime = Date.parse(b.startsAt);
      return preferenceScore(group.preference, aTime, input, preferredStartAt) - preferenceScore(group.preference, bTime, input, preferredStartAt)
        // Equidistant departures prefer the next later slot over a previous one.
        || (preferredStartAt === null ? 0 : Number(aTime < preferredStartAt) - Number(bTime < preferredStartAt))
        || aTime - bTime || a.startPointId.localeCompare(b.startPointId) || a.id.localeCompare(b.id);
    });
    if (!availableStarts.length) {
      conflicts.push({ code: "START_CAPACITY_EXCEEDED", subjectId: group.key, message: `Geen vrij tienminutenvertrek met voldoende capaciteit voor ${group.key}.` });
      continue;
    }
    let selected: PlanningStart | null = null;
    let finaleArrival: number | null = null;
    let selectedEffectiveStop = effectiveStop;
    let timeFeasible = false;
    const finaleFits = new Map<number, boolean>();
    const fitsFinale = (arrival: number) => {
      const cached = finaleFits.get(arrival);
      if (cached !== undefined) return cached;
      const overlapping = finaleReservations.filter(reservation => arrival < reservation.endsAt && arrival + serviceMs > reservation.startsAt);
      // Check actual concurrency at each increasing occupancy boundary, not the
      // union of groups that pass through at different moments during our show.
      const ticks = new Set([arrival, ...overlapping.filter(reservation => reservation.startsAt > arrival).map(reservation => reservation.startsAt)]);
      const fits = [...ticks].every(tick => {
        // Draft and published revisions remain alternatives for one physical group.
        const occupiedGroups = new Map<string, number>();
        for (const reservation of overlapping) {
          if (reservation.startsAt <= tick && reservation.endsAt > tick) {
            occupiedGroups.set(reservation.groupKey, Math.max(occupiedGroups.get(reservation.groupKey) ?? 0, reservation.children));
          }
        }
        return occupiedGroups.size < input.finaleMaxGroups
          && [...occupiedGroups.values()].reduce((sum, children) => sum + children, 0) + group.childCount <= input.finaleMaxChildren;
      });
      finaleFits.set(arrival, fits);
      return fits;
    };
    const normalArrival = Math.max(finaleOpen!, effectiveStop + input.finalePlanningTransferSeconds * 1_000);
    const latestArrival = Math.min(finaleLast!, finaleClose! - serviceMs,
      desiredEndAt === null ? Number.POSITIVE_INFINITY : desiredEndAt - input.finaleShowSeconds * 1_000);
    // These boundaries and their occupancy are shared by every candidate departure.
    const forwardArrivals = [...new Set([normalArrival, ...finaleReservations.map(reservation => reservation.endsAt)])]
      .filter(arrival => arrival >= normalArrival && arrival <= latestArrival).sort((a, b) => a - b);
    const earlierArrivals = [...new Set([Math.min(normalArrival, latestArrival), ...finaleReservations.map(reservation => reservation.startsAt - serviceMs)])]
      .filter(arrival => arrival <= latestArrival && arrival <= normalArrival).sort((a, b) => b - a);
    for (const candidate of availableStarts) {
      const candidateStart = Date.parse(candidate.startsAt);
      if (candidateStart > effectiveStop) continue;
      const earliestArrival = Math.max(finaleOpen!, candidateStart + input.finalePlanningTransferSeconds * 1_000);
      if (earliestArrival > latestArrival) continue;
      timeFeasible = true;
      // Occupancy can improve forwards exactly when an existing reservation ends.
      // Boundary candidates avoid missing a gap when show durations include seconds.
      let arrival = forwardArrivals.find(fitsFinale);
      if (arrival === undefined) {
        // Only shorten the ordinary route if the usual/later finale windows do not fit.
        // Backwards, capacity improves when our complete show+turnover ends at a reservation.
        arrival = earlierArrivals.find(value => value >= earliestArrival && fitsFinale(value));
      }
      if (arrival !== undefined) {
        selected = candidate;
        finaleArrival = arrival;
        selectedEffectiveStop = Math.min(effectiveStop, arrival - input.finalePlanningTransferSeconds * 1_000);
        break;
      }
    }
    if (!selected || finaleArrival === null) {
      conflicts.push({
        code: !timeFeasible && desiredEndAt !== null ? "DESIRED_END_UNREACHABLE" : !timeFeasible ? "ROUTE_TIME_CONFLICT" : "FINALE_CAPACITY_EXCEEDED",
        subjectId: group.key,
        message: !timeFeasible && desiredEndAt !== null ? `De dominante gewenste eindtijd van ${group.key} is niet haalbaar met een vrij vertrek, de overdracht en de finale.`
          : !timeFeasible ? `Geen vrij vertrek voor ${group.key} past vóór het stoppen bij gewone poorten.`
            : `De eindpoort kan ${group.key} niet binnen het ingestelde venster en de gewenste eindtijd ontvangen.`,
      });
      continue;
    }
    finaleReservations.push({ groupKey: `proposal:${group.key}`, startsAt: finaleArrival, endsAt: finaleArrival + serviceMs, children: group.childCount });
    startLoads.set(physicalStart(selected.startPointId, Date.parse(selected.startsAt)), { groups: 1, children: group.childCount });
    const warnings: string[] = [];
    if (group.parties.some(party => party.paymentEligible === false)) warnings.push("PAYMENT_NOT_CONFIRMED");
    const shortenedMinutes = (effectiveStop - selectedEffectiveStop) / 60_000;
    if (shortenedMinutes > 0) warnings.push("ORDINARY_ROUTE_SHORTENED_FOR_FINALE");
    const selectedStart = Date.parse(selected.startsAt);
    const preferenceResult = evaluatePartyPreferences(group.parties, selectedStart, input);
    const deviationMinutes = preferenceResult.maxPreferenceDeviationMinutes;
    if (preferenceResult.preferenceMatch === "large_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_DEVIATION");
    else if (preferenceResult.preferenceMatch === "small_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_CHECK");
    const dominantDeviation = preferredStartAt === null ? null : Math.abs(selectedStart - preferredStartAt) / 60_000;
    const preferenceReason = dominantDeviation === null
      ? group.preference === "indifferent" ? "Er is geen vaste startvoorkeur" : "Er is geen exacte starttijd opgegeven; controleer de tijdsvoorkeur"
      : dominantDeviation === 0 ? "Dit moment ligt exact op de dominante startvoorkeur"
        : `Het dichtstbijzijnde haalbare vrije vertrek wijkt ${dominantDeviation} minuten af van de dominante startvoorkeur`;
    const householdReason = deviationMinutes === null ? "" : `; de grootste afwijking voor een gezin is ${deviationMinutes} minuten`;
    groups.push({
      key: group.key,
      partyIds: group.parties.map(party => party.id).sort(),
      childCount: group.childCount,
      startId: selected.id,
      dominantStartAt: group.dominantStartAt,
      dominantEndAt: group.dominantEndAt,
      effectiveStopAt: new Date(selectedEffectiveStop).toISOString(),
      expectedFinaleArrivalAt: new Date(finaleArrival).toISOString(),
      ...preferenceResult,
      warnings,
      explanation: `${preferenceReason}${householdReason}; één vertrek bij ${selected.pointName ?? "het startpunt"} is gereserveerd.${shortenedMinutes > 0 ? ` Stop ${shortenedMinutes} minuten eerder bij gewone poorten om binnen een vrije finaleplek en de eindtijd te blijven.` : ""}`,
    });
  }
  return { groups, conflicts };
}
