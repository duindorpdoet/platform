export type CompositionRegistration = {
  id: string;
  reference: string;
  householdLabel: string;
  parentEmail: string | null;
  childCount: number;
  children: Array<{ name: string; age: number | null }>;
  partyId: string | null;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  assignmentPublished: boolean;
};

export type CompositionItem = {
  id: string;
  registrations: CompositionRegistration[];
  partyId: string | null;
};

/** Only the server-confirmed party id is allowed to join registrations. */
export function compositionItems(
  registrations: CompositionRegistration[],
): CompositionItem[] {
  const parties = new Map<string, CompositionRegistration[]>();
  const singles: CompositionItem[] = [];
  for (const registration of registrations) {
    if (!registration.partyId)
      singles.push({
        id: registration.id,
        registrations: [registration],
        partyId: null,
      });
    else
      parties.set(registration.partyId, [
        ...(parties.get(registration.partyId) ?? []),
        registration,
      ]);
  }
  return [
    ...singles,
    ...[...parties.entries()].map(([partyId, members]) => ({
      id: `party:${partyId}`,
      registrations: members,
      partyId,
    })),
  ].sort((a, b) =>
    a.registrations[0].reference.localeCompare(b.registrations[0].reference),
  );
}

export const itemChildren = (item: CompositionItem) =>
  item.registrations.reduce(
    (total, registration) => total + registration.childCount,
    0,
  );
export const itemRepresentative = (item: CompositionItem) =>
  item.registrations[0];

export function itemMatches(item: CompositionItem, query: string) {
  const needle = query.trim().toLocaleLowerCase("nl");
  if (!needle) return true;
  return item.registrations.some((registration) =>
    [
      registration.reference,
      registration.householdLabel,
      registration.parentEmail,
      ...registration.children.map((child) => child.name),
    ].some((value) => value?.toLocaleLowerCase("nl").includes(needle)),
  );
}
