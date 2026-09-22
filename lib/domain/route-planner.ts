export type PlanningParty = { id: string; childCount: number; requestedStartId?: string; togetherKey?: string };
export type PlanningStart = { id: string; startsAt: string; maxGroups: number; maxChildren: number };
export type PlanningPortal = { id: string; worldId: string; opensAt: string; closesAt: string; visitMinutes: number; maxConcurrentGroups: number; maxChildren: number; maxTotalChildren?: number };
export type PlanningConflict = { code: string; subjectId?: string; message: string };
export type PlannedGroup = { key: string; partyIds: string[]; childCount: number; startId: string; portalIds: string[] };

export type PlanningInput = {
  parties: PlanningParty[];
  starts: PlanningStart[];
  portals: PlanningPortal[];
  targetGroupSize: number;
  maxGroupSize: number;
  stopsPerGroup: number;
};

function stable<T extends { id: string }>(items: T[]) {
  return [...items].sort((a, b) => a.id.localeCompare(b.id));
}

export function proposePlan(input: PlanningInput): { groups: PlannedGroup[]; conflicts: PlanningConflict[] } {
  const conflicts: PlanningConflict[] = [];
  if (input.starts.length === 0) conflicts.push({ code: "NO_START_SLOTS", message: "Voeg ten minste één geverifieerd startmoment toe." });
  if (input.portals.length < input.stopsPerGroup) conflicts.push({ code: "INSUFFICIENT_PORTALS", message: `Minimaal ${input.stopsPerGroup} goedgekeurde poorten zijn nodig.` });
  if (input.targetGroupSize < 1 || input.targetGroupSize > input.maxGroupSize) conflicts.push({ code: "INVALID_GROUP_LIMIT", message: "De gewenste groepsgrootte valt buiten de grens." });
  if (conflicts.length) return { groups: [], conflicts };

  const starts = stable(input.starts);
  const portals = stable(input.portals);
  const clusters = new Map<string, PlanningParty[]>();
  for (const party of stable(input.parties)) {
    const key = party.togetherKey ? `together:${party.togetherKey}` : `party:${party.id}`;
    clusters.set(key, [...(clusters.get(key) ?? []), party]);
  }

  const bundles = [...clusters.entries()].map(([key, parties]) => ({
    key,
    parties,
    size: parties.reduce((sum, party) => sum + party.childCount, 0),
  })).sort((a, b) => b.size - a.size || a.key.localeCompare(b.key));

  if (bundles.some((bundle) => bundle.size > input.maxGroupSize)) {
    for (const bundle of bundles.filter((item) => item.size > input.maxGroupSize)) {
      conflicts.push({ code: "TOGETHER_PARTY_TOO_LARGE", subjectId: bundle.key, message: `${bundle.key} bevat ${bundle.size} kinderen; maximaal ${input.maxGroupSize}.` });
    }
    return { groups: [], conflicts };
  }

  const draftGroups: Array<{ key: string; parties: PlanningParty[]; childCount: number }> = [];
  for (const bundle of bundles) {
    const preferred = draftGroups
      .filter((group) => group.childCount + bundle.size <= input.maxGroupSize)
      .sort((a, b) => a.childCount - b.childCount || a.key.localeCompare(b.key))[0];
    if (preferred && preferred.childCount < input.targetGroupSize) {
      preferred.parties.push(...bundle.parties);
      preferred.childCount += bundle.size;
    } else {
      draftGroups.push({ key: `group-${String(draftGroups.length + 1).padStart(3, "0")}`, parties: [...bundle.parties], childCount: bundle.size });
    }
  }

  const startLoads = new Map(starts.map((start) => [start.id, { groups: 0, children: 0 }]));
  const portalReservations = new Map<string, Array<{ startsAt: number; endsAt: number }>>();
  const portalChildTotals = new Map<string, number>();
  const groups: PlannedGroup[] = [];
  for (const [index, group] of draftGroups.entries()) {
    const requestedIds = [...new Set(group.parties.map((party) => party.requestedStartId).filter(Boolean))] as string[];
    if (requestedIds.length > 1) {
      conflicts.push({ code: "START_PREFERENCE_CONFLICT", subjectId: group.key, message: `Gekoppelde inschrijvingen in ${group.key} hebben verschillende startvoorkeuren.` });
      continue;
    }
    const candidates = stable(starts.filter((start) => requestedIds.length === 0 || requestedIds.includes(start.id)));
    const selected = candidates.find((start) => {
      const load = startLoads.get(start.id)!;
      return load.groups < start.maxGroups && load.children + group.childCount <= start.maxChildren;
    });
    if (!selected) {
      conflicts.push({ code: "START_CAPACITY_EXCEEDED", subjectId: group.key, message: `Geen passend startmoment voor ${group.key}.` });
      continue;
    }
    const portalIds: string[] = [];
    const pendingReservations: Array<{ portalId: string; startsAt: number; endsAt: number }> = [];
    const usedWorlds = new Set<string>();
    const startAt = new Date(selected.startsAt).getTime();
    for (let offset = 0; offset < input.stopsPerGroup; offset += 1) {
      const arrival = startAt + offset * 8 * 60_000;
      const candidatesForStop = Array.from({ length: portals.length }, (_, portalOffset) => portals[(index + offset + portalOffset) % portals.length]);
      const selectedPortal = candidatesForStop.find((portal) => {
        const departure = arrival + portal.visitMinutes * 60_000;
        const overlapping = (portalReservations.get(portal.id) ?? []).filter((reservation) => arrival < reservation.endsAt && departure > reservation.startsAt).length;
        return !portalIds.includes(portal.id)
          && !usedWorlds.has(portal.worldId)
          && group.childCount <= portal.maxChildren
          && (portalChildTotals.get(portal.id) ?? 0) + group.childCount <= (portal.maxTotalChildren ?? Number.MAX_SAFE_INTEGER)
          && arrival >= new Date(portal.opensAt).getTime()
          && departure <= new Date(portal.closesAt).getTime()
          && overlapping < portal.maxConcurrentGroups;
      });
      if (!selectedPortal) {
        conflicts.push({ code: "PORTAL_CAPACITY_EXCEEDED", subjectId: group.key, message: `Geen veilige poortcapaciteit voor stop ${offset + 1} van ${group.key}.` });
        break;
      }
      portalIds.push(selectedPortal.id);
      usedWorlds.add(selectedPortal.worldId);
      pendingReservations.push({ portalId: selectedPortal.id, startsAt: arrival, endsAt: arrival + selectedPortal.visitMinutes * 60_000 });
    }
    if (portalIds.length !== input.stopsPerGroup) continue;
    const load = startLoads.get(selected.id)!;
    load.groups += 1;
    load.children += group.childCount;
    for (const reservation of pendingReservations) {
      portalReservations.set(reservation.portalId, [...(portalReservations.get(reservation.portalId) ?? []), reservation]);
      portalChildTotals.set(reservation.portalId, (portalChildTotals.get(reservation.portalId) ?? 0) + group.childCount);
    }
    groups.push({ key: group.key, partyIds: group.parties.map((party) => party.id).sort(), childCount: group.childCount, startId: selected.id, portalIds });
  }
  return { groups: conflicts.length ? [] : groups, conflicts };
}
