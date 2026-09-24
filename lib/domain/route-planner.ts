export type StartTimePreference = "early" | "indifferent" | "later";

export type PlanningParty = {
  id: string;
  childCount: number;
  startPreference?: StartTimePreference;
  requestedStopAt?: string | null;
  paymentEligible?: boolean;
  togetherKey?: string;
  togetherOverride?: boolean;
};

export type PlanningStart = {
  id: string;
  startPointId: string;
  startsAt: string;
  maxGroups: number;
  maxChildren: number;
};

export type PlanningConflict = { code: string; subjectId?: string; message: string };
export type PreferenceMatch = "good" | "small_deviation" | "large_deviation" | "neutral";
export type PlannedGroup = {
  key: string;
  partyIds: string[];
  childCount: number;
  startId: string;
  effectiveStopAt: string;
  expectedFinaleArrivalAt: string;
  preferenceMatch: PreferenceMatch;
  warnings: string[];
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

function preferenceScore(preference: StartTimePreference, startAt: number, input: PlanningInput) {
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

function matchFor(preference: StartTimePreference, startAt: number, input: PlanningInput): PreferenceMatch {
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

export function proposePlan(input: PlanningInput): { groups: PlannedGroup[]; conflicts: PlanningConflict[] } {
  const conflicts: PlanningConflict[] = [];
  const globalStop = millis(input.globalOrdinaryStopAt);
  const finaleOpen = millis(input.finaleOpensAt);
  const finaleLast = millis(input.finaleLastArrivalAt);
  const finaleClose = millis(input.finaleClosesAt);
  if (!input.starts.length) conflicts.push({ code: "NO_START_SLOTS", message: "Voeg ten minste één geverifieerd startpunt met een exact tijdstip toe." });
  if (input.targetGroupSize < 1 || input.targetGroupSize > input.maxGroupSize) conflicts.push({ code: "INVALID_GROUP_LIMIT", message: "De gewenste groepsgrootte valt buiten de grens." });
  if ([globalStop, finaleOpen, finaleLast, finaleClose].some((value) => value === null)) conflicts.push({ code: "ROUTE_CONFIGURATION_INCOMPLETE", message: "Vul de stopgrens en alle eindpoortvensters in." });
  if (input.finaleShowSeconds < 60 || input.finaleMaxGroups < 1 || input.finaleMaxChildren < 1) conflicts.push({ code: "INVALID_FINALE_CAPACITY", message: "De eindpoortcapaciteit is niet geldig." });
  if (conflicts.length) return { groups: [], conflicts };

  const starts = [...input.starts].sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.id.localeCompare(b.id));
  const clusters = new Map<string, PlanningParty[]>();
  for (const party of stable(input.parties)) {
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
    if (bundle.size > input.maxGroupSize && !bundle.capacityOverride) conflicts.push({ code: "TOGETHER_PARTY_TOO_LARGE", subjectId: bundle.key, message: `${bundle.key} bevat ${bundle.size} kinderen; maximaal ${input.maxGroupSize}.` });
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
  const finaleReservations: Array<{ startsAt: number; endsAt: number; children: number }> = [];
  const groups: PlannedGroup[] = [];
  const serviceMs = (input.finaleShowSeconds + input.finaleTurnoverSeconds) * 1_000;
  for (const group of draftGroups) {
    const selected = [...starts]
      .filter((start) => {
        const load = startLoads.get(start.id)!;
        return load.groups < start.maxGroups && load.children + group.childCount <= start.maxChildren;
      })
      .sort((a, b) => preferenceScore(group.preference, Date.parse(a.startsAt), input) - preferenceScore(group.preference, Date.parse(b.startsAt), input)
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
      if (overlapping.length < input.finaleMaxGroups
        && overlapping.reduce((sum, reservation) => sum + reservation.children, 0) + group.childCount <= input.finaleMaxChildren) {
        finaleReservations.push({ startsAt: finaleArrival, endsAt: finaleArrival + serviceMs, children: group.childCount });
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
    groups.push({
      key: group.key,
      partyIds: group.parties.map((party) => party.id).sort(),
      childCount: group.childCount,
      startId: selected.id,
      effectiveStopAt: new Date(effectiveStop).toISOString(),
      expectedFinaleArrivalAt: new Date(finaleArrival).toISOString(),
      preferenceMatch: matchFor(group.preference, Date.parse(selected.startsAt), input),
      warnings,
    });
  }
  return conflicts.length ? { groups: [], conflicts } : { groups, conflicts: [] };
}
