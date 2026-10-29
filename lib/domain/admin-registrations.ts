export type AdminRegistration = {
  id: string; reference: string; version?: number; status: string; submittedAt: string | null; updatedAt: string;
  parentName: string; parentEmail: string; phone: string | null; groupId: string | null; groupCode: string | null; groupName: string;
  togetherCode: string | null; partyId: string | null; clusterReference: string | null; preferredStartAt: string | null; desiredEndAt: string | null;
  childCount: number; children: Array<{ id: string; name: string; age: number | null; accessibilityNote: string | null; stepFreeRequired?: boolean | null; requiresAccessibilityReview?: boolean; status: string }>; priceCents: number;
  activation?: { status: "pending" | "activated"; invitationVersion?: number; expiresAt?: string | null; email?: string | null };
  mailStatus?: string | null; reservedChildCount?: number; activatedChildCount?: number; presentChildCount?: number | null; paidChildCount?: number;
};
export type ManagedRegistrationGroup = {
  id: string; version: number; code: string; name: string; children: number; maxChildren?: number; status: string;
  confirmed: boolean; startConfirmed?: boolean; compositionConfirmed?: boolean; startPointCode: string | null; startsAt: string | null; desiredEndAt: string | null; expectedCompletionAt: string | null; started: boolean;
};
export type RegistrationCreationOptions = {
  eventVersion: number; canManageGroups?: boolean; allowedStartTimes: string[]; allowedEndTimes: string[]; priceCents: number; maxGroupSize: number;
  groups: ManagedRegistrationGroup[]; parties: Array<{ id: string; reference: string; groupId: string | null; children: number; households: number }>;
};
export type ManagedRegistrationChild = {
  id: string; childId: string; firstName: string; ageAtEvent: number | null; accessibilityNote: string | null; stepFreeRequired?: boolean | null; requiresAccessibilityReview?: boolean; participationStatus: string; unitPriceCents: number;
};
export type RegistrationManagementPreview = {
  registrationId: string; version: number; inputHash: string; children: ManagedRegistrationChild[];
  sourceGroup: ManagedRegistrationGroup | null; groups: ManagedRegistrationGroup[];
  together: { partyId: string | null; otherHouseholds: number; splitOnMove: boolean }; canEdit: boolean; canMove: boolean;
};
export type RegistrationChildDraft = { key: string; id: string | null; name: string; age: string; accessibilityNote: string; stepFreeRequired?: boolean | null };
export type RegistrationChildInput = { id: string | null; firstName: string; ageAtEvent: number; accessibilityNote: string | null; stepFreeRequired?: boolean | null };

export function registrationChildrenInput(children: RegistrationChildDraft[]): { children?: RegistrationChildInput[]; error?: string } {
  if (!children.length) return { error: "De laatste deelnemer verwijderen vraagt een expliciete annulering van de inschrijving. Behoud minstens één kind of laat de organisatie de deelname annuleren." };
  const ids = children.flatMap(child => child.id ? [child.id] : []);
  if (new Set(ids).size !== ids.length) return { error: "Een kind staat twee keer in deze wijziging. Open de actuele inschrijving opnieuw." };
  if (children.some(child => !child.name.trim() || child.name.trim().length > 80 || !/^\d{1,2}$/.test(child.age) || Number(child.age) > 20 || child.accessibilityNote.length > 500)) {
    return { error: "Vul voor ieder kind een voornaam van maximaal 80 tekens en een leeftijd van 0 tot en met 20 jaar in. Een toegankelijkheidswens mag maximaal 500 tekens bevatten." };
  }
  return { children: children.map(child => ({ id: child.id, firstName: child.name.trim(), ageAtEvent: Number(child.age), accessibilityNote: child.accessibilityNote.trim() || null, ...(Object.hasOwn(child,"stepFreeRequired") ? {stepFreeRequired:child.stepFreeRequired} : {}) })) };
}
export function registrationChildChanges(existing: ManagedRegistrationChild[], desired: RegistrationChildDraft[]) {
  const active = existing.filter(child => child.participationStatus === "active");
  const kept = new Set(desired.flatMap(child => child.id ? [child.id] : []));
  return {
    before: active.length, after: desired.length,
    added: desired.filter(child => !child.id).map(child => child.name.trim() || "Nieuw kind"),
    removed: active.filter(child => !kept.has(child.id)).map(child => child.firstName),
    corrected: desired.filter(child => {
      const old = active.find(item => item.id === child.id);
      return old && (old.firstName !== child.name.trim() || old.ageAtEvent !== Number(child.age) || (old.accessibilityNote ?? "").trim() !== child.accessibilityNote.trim() || (Object.hasOwn(child,"stepFreeRequired") && old.stepFreeRequired !== child.stepFreeRequired));
    }).map(child => child.name.trim() || "Kind"),
  };
}
export function registrationAdminError(error: { message?: string; code?: string; details?: string } | null | undefined) {
  const message = error?.message ?? "";
  if (/NOT_AUTHORIZED|PERMISSION_DENIED/.test(message) || error?.code === "42501") return "Je hebt geen bevoegdheid voor deze beheeractie. Je invoer blijft behouden.";
  if (/STALE|INPUT_CHANGED|VERSION_CONFLICT|SOURCE_CHANGED/.test(message)) return "Deze inschrijving of groepsruimte is intussen gewijzigd. Je invoer blijft staan. Haal de actuele versie op en beoordeel de wijziging opnieuw.";
  if (/LAST_CHILD|NO_ACTIVE_CHILDREN|CHILDREN_REQUIRED|REGISTRATION_REQUIRES_CHILD/.test(message)) return "De laatste deelnemer verwijderen vraagt een expliciete annulering. De huidige deelname is behouden.";
  if (/GROUP_STARTED|RUN_STARTED|LIVE_TRANSFER|BEGUN_GROUP/.test(message)) return "Deze groep is al begonnen. Gebruik de ondersteunde overdrachtsprocedure; de bestaande aanwezigheid en bezoeken blijven behouden.";
  if (/SOLE_LEADER|LAST_LEADER|LEADER_REQUIRED/.test(message)) return "Dit gezin levert de enige bevoegde groepsleider. Regel eerst een opvolger via het bestaande rollenbeheer.";
  if (/ALREADY_ACTIVATED|INVITATION_NOT_PENDING|REGISTRATION_NOT_PENDING/.test(message)) return "Deze ouder heeft de inschrijving al geactiveerd. Het e-mailadres kan hier niet meer worden gewijzigd; gebruik de veilige accountprocedure.";
  if (/CAPACITY|GROUP_SIZE_LIMIT|CHILD_LIMIT|MAX_GROUP_SIZE/.test(message)) {
    let details: { needed?: unknown; available?: unknown } = {};
    try { details = JSON.parse(error?.details ?? "{}"); } catch { /* Only structured numeric capacity detail is displayed. */ }
    const quantities = typeof details.needed === "number" && typeof details.available === "number" ? ` Benodigd: ${details.needed}; beschikbaar: ${details.available}.` : "";
    return `Er is onvoldoende geldige capaciteit in de groep, het startpunt of een poort.${quantities} Kies een passende groep of controleer de capaciteitsinstellingen; de bestaande indeling is behouden.`;
  }
  if (/EMAIL|CONTACT/.test(message)) return "Controleer het e-mailadres van de ouder. De invoer blijft behouden.";
  if (/INVALID|VALIDATION_ERROR|REQUIRED|PREFERENCE/.test(message)) return "Controleer de ingevulde gegevens en voorkeurstijden. Je invoer blijft behouden.";
  return "De beheeractie kon niet worden afgerond. Je invoer blijft staan; probeer dezelfde actie opnieuw. Er wordt geen extra opdracht aangemaakt door opnieuw te klikken.";
}
export const registrationMailStatus: Record<string, string> = {
  queued: "Wacht op verzenden", pending: "Wacht op verzenden", processing: "Verzending wordt verwerkt", sending: "Verzending wordt verwerkt",
  submitted: "Aangeboden aan maildienst", sent: "Verzonden", delivered: "Bezorgd", failed: "Verzenden mislukt", retry: "Wacht op nieuwe verzendpoging",
  deferred: "Wacht op nieuwe verzendpoging", suppressed: "Ingetrokken", unknown: "Verzendresultaat wordt gecontroleerd", superseded: "Vervangen door een actuele mail", cancelled: "Ingetrokken", dropped: "Niet bezorgd", bounced: "Niet bezorgd",
};
export function registrationActivationLabel(registration: Pick<AdminRegistration, "activation">) {
  return registration.activation?.status === "pending" ? "Wacht op eerste inlog" : registration.activation?.status === "activated" ? "Geactiveerd · definitief" : "Activatiestatus niet beschikbaar";
}
