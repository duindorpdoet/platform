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

function groupPreference(parties: PlanningParty[]): StartTimePreference | "conflict" {
  const values = new Set(parties.map((party) => party.startPreference ?? "indifferent").filter((value) => value !== "indifferent"));
  if (values.size > 1) return "conflict";
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

/** Report the least satisfied household, while the selection score may still use a soft group average. */
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
  if ([globalStop, finaleOpen, finaleLast, finaleClose].some((value) => value === null)) conflicts.push({ code: "ROUTE_CONFIGURATION_INCOMPLETE", message: "Vul de stopgrens en alle eindpoortvensters in." });
  if (input.finaleShowSeconds < 60 || input.finaleMaxGroups < 1 || input.finaleMaxChildren < 1) conflicts.push({ code: "INVALID_FINALE_CAPACITY", message: "De eindpoortcapaciteit is niet geldig." });
  const serviceMs = (input.finaleShowSeconds + input.finaleTurnoverSeconds) * 1_000;
  const existingSchedules = new Map<string, ExistingPlanningSchedule>();
  for (const schedule of input.existingSchedules ?? []) {
    const arrival = millis(schedule.expectedFinaleArrivalAt);
    const end = schedule.finaleEndsAt ? millis(schedule.finaleEndsAt) : arrival === null ? null : arrival + serviceMs;
    if (!schedule.id || !schedule.startId || !Number.isInteger(schedule.childCount) || schedule.childCount < 0 || arrival === null || end === null || end <= arrival) {
      conflicts.push({ code: "INVALID_EXISTING_RESERVATION", subjectId: schedule.id, message: "Een bestaande afspraak heeft ongeldige capaciteitsgegevens. Controleer de opgeslagen planning." });
      continue;
    }
    const previous = existingSchedules.get(schedule.id);
    if (previous && (previous.groupId !== schedule.groupId || previous.startId !== schedule.startId || previous.childCount !== schedule.childCount
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
    return Number.isFinite(value) && start.markerValid !== false
      && (availableFrom === null || value >= availableFrom)
      && (availableUntil === null || value <= availableUntil)
      && (portalOpensAt === null || value >= portalOpensAt)
      && (portalClosesAt === null || value <= portalClosesAt);
  }).sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.id.localeCompare(b.id));
  const clusters = new Map<string, PlanningParty[]>();
  const assignedPartyIds = new Set([...existingSchedules.values()].flatMap((schedule) => schedule.partyIds ?? []));
  for (const party of stable(input.parties).filter((party) => !assignedPartyIds.has(party.id))) {
    const key = party.togetherKey ? `together:${party.togetherKey}` : `party:${party.id}`;
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
    if (bundle.preference === "conflict") conflicts.push({ code: "START_PREFERENCE_CONFLICT", subjectId: bundle.key, message: `${bundle.key} bevat zowel een vroege als late voorkeur. Stem een gezamenlijke afspraak af of splits bewust.` });
  }
  if (conflicts.length) return { groups: [], conflicts };

  const draftGroups: Array<{ key: string; parties: PlanningParty[]; childCount: number; capacityOverride: boolean; preference: StartTimePreference }> = [];
  for (const bundle of bundles) {
    const preference = bundle.preference as StartTimePreference;
    const preferred = draftGroups
      .filter((group) => !bundle.capacityOverride && !group.capacityOverride
        && group.childCount + bundle.size <= input.maxGroupSize
        && (group.preference === "indifferent" || preference === "indifferent" || group.preference === preference))
      .sort((a, b) => a.childCount - b.childCount || a.key.localeCompare(b.key))[0];
    if (preferred && preferred.childCount < input.targetGroupSize) {
      preferred.parties.push(...bundle.parties);
      preferred.childCount += bundle.size;
      if (preferred.preference === "indifferent") preferred.preference = preference;
    } else {
      draftGroups.push({ key: `group-${String(draftGroups.length + 1).padStart(3, "0")}`, parties: [...bundle.parties], childCount: bundle.size, capacityOverride: bundle.capacityOverride, preference });
    }
  }

  const startLoads = new Map(starts.map((start) => [start.id, { groups: 0, children: 0 }]));
  const finaleReservations: Array<{ groupKey: string; startsAt: number; endsAt: number; children: number }> = [];
  const existingStartReservations = new Map<string, { startId: string; children: number }>();
  for (const schedule of existingSchedules.values()) {
    const groupKey = `existing:${schedule.groupId ?? schedule.id}`;
    const reservationKey = `${groupKey}:${schedule.startId}`;
    const previous = existingStartReservations.get(reservationKey);
    existingStartReservations.set(reservationKey, { startId: schedule.startId, children: Math.max(previous?.children ?? 0, schedule.childCount) });
    const startsAt = millis(schedule.expectedFinaleArrivalAt)!;
    finaleReservations.push({ groupKey, startsAt, endsAt: schedule.finaleEndsAt ? millis(schedule.finaleEndsAt)! : startsAt + serviceMs, children: schedule.childCount });
  }
  for (const reservation of existingStartReservations.values()) {
    const load = startLoads.get(reservation.startId);
    if (load) { load.groups += 1; load.children += reservation.children; }
  }
  const groups: PlannedGroup[] = [];
  for (const group of draftGroups) {
    const preferredStarts = group.parties.map((party) => millis(party.preferredStartAt)).filter((value): value is number => value !== null);
    const preferredStartAt = preferredStarts.length
      ? Math.round(preferredStarts.reduce((sum, value) => sum + value, 0) / preferredStarts.length)
      : null;
    const selected = [...starts]
      .filter((start) => {
        const load = startLoads.get(start.id)!;
        return load.groups < start.maxGroups && load.children + group.childCount <= start.maxChildren;
      })
      .sort((a, b) => preferenceScore(group.preference, Date.parse(a.startsAt), input, preferredStartAt) - preferenceScore(group.preference, Date.parse(b.startsAt), input, preferredStartAt)
        || Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.id.localeCompare(b.id))[0];
    if (!selected) {
      conflicts.push({ code: "START_CAPACITY_EXCEEDED", subjectId: group.key, message: `Geen passend geverifieerd startmoment voor ${group.key}.` });
      continue;
    }
    const requestedStops = group.parties.map((party) => millis(party.requestedStopAt)).filter((value): value is number => value !== null);
    const effectiveStop = Math.min(globalStop!, ...(requestedStops.length ? requestedStops : [globalStop!]));
    let finaleArrival = Math.max(finaleOpen!, effectiveStop + input.finalePlanningTransferSeconds * 1_000);
    let reserved = false;
    while (finaleArrival <= finaleLast! && finaleArrival + serviceMs <= finaleClose!) {
      const overlapping = finaleReservations.filter((reservation) => finaleArrival < reservation.endsAt && finaleArrival + serviceMs > reservation.startsAt);
      // A draft and a still-published appointment are alternatives for one group, not two actual groups.
      const occupiedGroups = new Map<string, number>();
      for (const reservation of overlapping) occupiedGroups.set(reservation.groupKey, Math.max(occupiedGroups.get(reservation.groupKey) ?? 0, reservation.children));
      if (occupiedGroups.size < input.finaleMaxGroups
        && [...occupiedGroups.values()].reduce((sum, children) => sum + children, 0) + group.childCount <= input.finaleMaxChildren) {
        finaleReservations.push({ groupKey: `proposal:${group.key}`, startsAt: finaleArrival, endsAt: finaleArrival + serviceMs, children: group.childCount });
        reserved = true;
        break;
      }
      finaleArrival += 60_000;
    }
    if (!reserved) {
      conflicts.push({ code: "FINALE_CAPACITY_EXCEEDED", subjectId: group.key, message: `De eindpoort kan ${group.key} niet binnen het ingestelde venster ontvangen.` });
      continue;
    }
    const load = startLoads.get(selected.id)!;
    load.groups += 1;
    load.children += group.childCount;
    const warnings: string[] = [];
    if (group.parties.some((party) => party.paymentEligible === false)) warnings.push("PAYMENT_NOT_CONFIRMED");
    const selectedStart = Date.parse(selected.startsAt);
    const preferenceResult = evaluatePartyPreferences(group.parties, selectedStart, input);
    const deviationMinutes = preferenceResult.maxPreferenceDeviationMinutes;
    if (preferenceResult.preferenceMatch === "large_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_DEVIATION");
    else if (preferenceResult.preferenceMatch === "small_deviation") warnings.push("HOUSEHOLD_START_PREFERENCE_CHECK");
    const remainingChildren = selected.maxChildren - load.children;
    const preferenceReason = deviationMinutes === null
      ? group.preference === "indifferent" ? "Er is geen vaste startvoorkeur" : "Er is geen exacte starttijd opgegeven; controleer de tijdsvoorkeur"
      : deviationMinutes === 0 ? "Dit moment ligt exact op de voorkeur van ieder gezin met een opgegeven tijdsvoorkeur" : `De grootste afwijking voor een gezin is ${deviationMinutes} minuten; controleer de voorkeur per inschrijving`;
    groups.push({
      key: group.key,
      partyIds: group.parties.map((party) => party.id).sort(),
      childCount: group.childCount,
      startId: selected.id,
      effectiveStopAt: new Date(effectiveStop).toISOString(),
      expectedFinaleArrivalAt: new Date(finaleArrival).toISOString(),
      ...preferenceResult,
      warnings,
      explanation: `${preferenceReason}; ${selected.pointName ?? "het startpunt"} heeft daarna nog ruimte voor ${Math.max(0, remainingChildren)} kinderen.`,
    });
  }
  return conflicts.length ? { groups: [], conflicts } : { groups, conflicts: [] };
}
