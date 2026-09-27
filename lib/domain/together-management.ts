export type TogetherGroup = {
  id: string;
  systemCode: string;
  displayName: string | null;
  status: string;
  locked: boolean;
};
export type TogetherMember = {
  id: string;
  reference: string;
  togetherCode: string;
  status: string;
  householdLabel: string;
  parentName: string;
  parentEmail: string | null;
  childCount: number;
  children: Array<{ name: string; age: number | null }>;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  walkingGroup: TogetherGroup | null;
  assignmentPublished: boolean;
};
export type TogetherParty = {
  partyId: string;
  clusterReference: string | null;
  memberCount: number;
  childCount: number;
  members: TogetherMember[];
  walkingGroup: TogetherGroup | null;
  walkingGroups: TogetherGroup[];
  locked: boolean;
  published: boolean;
  problems: string[];
  stateToken: string;
};
export type TogetherRequest = {
  id: string;
  version: number;
  registrationReference: string;
  requestedCode: string;
  source: TogetherParty | null;
  target: TogetherParty | null;
  projectedChildren: number;
};
export type TogetherSnapshot = {
  realtimeTopic: string;
  maxGroupSize: number;
  confirmed: TogetherParty[];
  requests: TogetherRequest[];
  problems: TogetherParty[];
  totals: Record<"confirmed" | "requests" | "problems", number>;
};
export type TogetherPreview = {
  source: TogetherParty;
  target: TogetherParty;
  projectedChildren: number;
  projectedRegistrations: number;
  maxGroupSize: number;
  blockers: string[];
  canMerge: boolean;
};
export const partyIdentity = (party: TogetherParty) => party.clusterReference ??
  (party.memberCount > 1 ? "Samenloop · reference ontbreekt" : party.members[0]?.reference ?? "Inschrijving niet beschikbaar");
export const groupLabel = (party: TogetherParty) => party.walkingGroups.length
  ? party.walkingGroups.map((group) => [group.systemCode, group.displayName].filter(Boolean).join(" · ")).join(", ")
  : "Nog niet ingedeeld";
export const togetherProblemLabels: Record<string, string> = {
  missing_reference: "Samenloopnummer ontbreekt.",
  split_groups: "Leden zijn verdeeld over meerdere groepen of deels nog niet ingedeeld.",
  over_capacity: "Het aantal kinderen overschrijdt de actuele groepslimiet.",
  published_pending: "Gepubliceerde indeling met een open samenloopverzoek.",
  duplicate_membership: "Een inschrijving heeft meerdere actieve memberships.",
  inactive_registration: "Een actief membership verwijst naar een niet-actieve inschrijving.",
  locked_pending: "Vergrendelde samenloop of wandelgroep met een open verzoek.",
  same_party: "Bron en doel behoren al tot dezelfde samenloop.",
  locked: "Een samenloop of wandelgroep is vergrendeld.",
  published: "Een indeling is al gepubliceerd.",
  event_locked: "Dit evenement is niet meer bewerkbaar.",
  different_groups: "Deze inschrijvingen hebben een verschillende groepsindeling. Pas eerst de groepsindeling aan.",
  invalid_membership: "De memberships vragen eerst controle door beheer.",
  open_outgoing_request: "Behandel eerst het open verzoek van bron of doel via Open verzoeken.",
};
const time = (value: string | null) => value ? new Intl.DateTimeFormat("nl-NL", {
  hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam",
}).format(new Date(value)) : null;
export function partyPreference(party: TogetherParty) {
  const preferences = [...new Set(party.members.map((member) => [time(member.preferredStartAt), time(member.desiredEndAt)].filter(Boolean).join("–")))];
  if (preferences.every((value) => !value)) return "Geen voorkeur";
  return preferences.length > 1 ? "Verschillende voorkeurstijden" : `Voorkeur: ${preferences[0]}`;
}
export function matchingMembers(party: TogetherParty, query: string) {
  const needle = query.trim().toLocaleLowerCase("nl");
  if (!needle) return [];
  return party.members.filter((member) => [member.reference, member.togetherCode, member.householdLabel,
    member.parentName, member.parentEmail, ...member.children.map((child) => child.name)]
    .some((value) => value?.toLocaleLowerCase("nl").includes(needle))).map((member) => member.reference);
}
export function togetherError(message: string) {
  if (message.includes("STALE_VERSION")) return "De gegevens zijn gewijzigd. Controleer bron en doel opnieuw voordat je bevestigt.";
  if (message.includes("IDENTIFIER_NOT_FOUND")) return "Geen actieve inschrijving of samenloop gevonden bij dit nummer.";
  if (message.includes("MERGE_BLOCKED")) return "Koppelen is geblokkeerd. Controleer de actuele groepsindeling en voorwaarden.";
  if (message.includes("NOT_AUTHORIZED")) return "Je hebt geen toegang tot dit samenloopbeheer.";
  return "De actie is niet bevestigd. Probeer opnieuw; een herhaling wordt veilig afgehandeld.";
}
