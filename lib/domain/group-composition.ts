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
export type MoveCheck = { canMove: boolean; reason: string | null };

const ordered = (members: CompositionRegistration[]) =>
  [...members].sort(
    (a, b) =>
      a.reference.localeCompare(b.reference) || a.id.localeCompare(b.id),
  );
/** Only a server-confirmed party id joins registrations; ordering makes the representative stable. */
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
      registrations: ordered(members),
      partyId,
    })),
  ].sort(
    (a, b) =>
      itemRepresentative(a).reference.localeCompare(
        itemRepresentative(b).reference,
      ) || itemRepresentative(a).id.localeCompare(itemRepresentative(b).id),
  );
}
export const itemChildren = (item: CompositionItem) =>
  item.registrations.reduce(
    (total, registration) => total + registration.childCount,
    0,
  );
export const itemRepresentative = (item: CompositionItem) =>
  item.registrations[0];
export function preferenceSummary(item: CompositionItem) {
  const values = [
    ...new Set(
      item.registrations
        .map((registration) => registration.preferredStartAt)
        .filter((value): value is string => Boolean(value)),
    ),
  ];
  return values.length === 0
    ? "Geen voorkeur"
    : values.length === 1
      ? values[0]
      : "Verschillende voorkeurstijden";
}
export function itemMatches(item: CompositionItem, query: string) {
  const needle = query.trim().toLocaleLowerCase("nl");
  return (
    !needle ||
    item.registrations.some((registration) =>
      [
        registration.reference,
        registration.householdLabel,
        registration.parentEmail,
        ...registration.children.map((child) => child.name),
      ].some((value) => value?.toLocaleLowerCase("nl").includes(needle)),
    )
  );
}
export const groupMatches = (
  code: string,
  name: string | null,
  query: string,
) =>
  !query.trim() ||
  [code, name].some((value) =>
    value
      ?.toLocaleLowerCase("nl")
      .includes(query.trim().toLocaleLowerCase("nl")),
  );
export function canMoveCompositionItem(
  item: CompositionItem,
  options: {
    editable: boolean;
    sourceLocked: boolean;
    targetLocked: boolean;
    targetValid: boolean;
    targetChildCount: number;
    maxGroupSize: number;
    alreadyInTarget?: boolean;
    inconsistent?: boolean;
  },
): MoveCheck {
  if (!options.editable)
    return {
      canMove: false,
      reason: "De groepsindeling is niet meer bewerkbaar.",
    };
  if (options.inconsistent)
    return {
      canMove: false,
      reason:
        "Deze samenloop is verdeeld over meerdere groepen. Vernieuw de gegevens voordat je verplaatst.",
    };
  if (options.sourceLocked)
    return { canMove: false, reason: "De huidige groep is vergrendeld." };
  if (!options.targetValid || options.targetLocked)
    return {
      canMove: false,
      reason: "Deze doelgroep is vergrendeld of niet beschikbaar.",
    };
  if (
    item.registrations.some((registration) => registration.assignmentPublished)
  )
    return {
      canMove: false,
      reason: "Een inschrijving in deze bundel is al gepubliceerd.",
    };
  if (
    !options.alreadyInTarget &&
    options.targetChildCount + itemChildren(item) > options.maxGroupSize
  )
    return {
      canMove: false,
      reason: `Vol · ${options.targetChildCount}/${options.maxGroupSize} + ${itemChildren(item)} kinderen`,
    };
  return { canMove: true, reason: null };
}
export function dividedPartyIds(
  columns: Array<{ id: string; registrations: CompositionRegistration[] }>,
) {
  const locations = new Map<string, Set<string>>();
  for (const column of columns)
    for (const registration of column.registrations)
      if (registration.partyId)
        locations.set(
          registration.partyId,
          new Set([...(locations.get(registration.partyId) ?? []), column.id]),
        );
  return new Set(
    [...locations]
      .filter(([, groups]) => groups.size > 1)
      .map(([partyId]) => partyId),
  );
}
