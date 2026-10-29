/** PostgreSQL and browser timestamps may spell the same instant differently. */
export function canonicalTimestamp(value?: string | null): string {
  const timestamp = value ? Date.parse(value) : Number.NaN;
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : "";
}

export function sameTimestamp(left?: string | null, right?: string | null) {
  return canonicalTimestamp(left) === canonicalTimestamp(right);
}

export function timestampChoices(values: Array<string | null | undefined>) {
  return [...new Set(values.map(canonicalTimestamp).filter(Boolean))].sort();
}

type Assignment = { pointId: string; startsAt: string; revision: number };
export type AssignmentDraft = { saved: Assignment; pointId: string; startsAt: string; sourceChanged: boolean };

export function assignmentDraft(saved: Assignment): AssignmentDraft {
  const canonical = { ...saved, startsAt: canonicalTimestamp(saved.startsAt) };
  return { saved: canonical, pointId: canonical.pointId, startsAt: canonical.startsAt, sourceChanged: false };
}

/** Refresh pristine fields; keep an organizer's unsaved edits visible. */
export function reconcileAssignment(draft: AssignmentDraft, incoming: Assignment): AssignmentDraft {
  const saved = { ...incoming, startsAt: canonicalTimestamp(incoming.startsAt) };
  if (draft.saved.pointId === saved.pointId && draft.saved.startsAt === saved.startsAt && draft.saved.revision === saved.revision) return draft;
  const pristine = draft.pointId === draft.saved.pointId && draft.startsAt === draft.saved.startsAt;
  const accepted = draft.pointId === saved.pointId && draft.startsAt === saved.startsAt;
  return pristine || accepted ? assignmentDraft(saved) : { ...draft, saved, sourceChanged: true };
}

type CountableRoute = { groupId: string; revision: number; start?: { pointId: string; startsAt: string }; stops: Array<{ portalId: string; kind: string }> };

export function checkedRouteVisitLabel(route: CountableRoute | undefined, currentRevision: number | undefined,
  expected: { groupId: string; pointId: string; startsAt: string } | null) {
  if (!route || !expected || route.groupId !== expected.groupId || route.revision !== currentRevision
    || route.start?.pointId !== expected.pointId || !sameTimestamp(route.start.startsAt, expected.startsAt)) {
    return "Aantal bezoeken volgt na routecontrole";
  }
  const finale = new Set(route.stops.filter(stop => stop.kind === "finale").map(stop => stop.portalId));
  const ordinary = new Set(route.stops.filter(stop => stop.kind !== "finale" && !finale.has(stop.portalId)).map(stop => stop.portalId));
  const duplicate = route.stops.length !== ordinary.size + finale.size;
  return `${ordinary.size} ${ordinary.size === 1 ? "gewoon huis" : "gewone huizen"} + ${finale.size} finale${finale.size === 1 ? "" : "s"}${duplicate ? " · dubbele poort in route: controleer de route" : ""}`;
}
