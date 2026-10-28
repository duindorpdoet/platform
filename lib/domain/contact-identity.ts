/** Names and participation identifiers are separate display fields. */
export type ContactIdentity = {
  personName?: string | null;
  parentName?: string | null;
  contactName?: string | null;
  householdLabel?: string | null;
  groupCode?: string | null;
  groupName?: string | null;
  portalName?: string | null;
  systemCode?: string | null;
  subjectKind?: string;
};

/** Never turn a code, email address or household/group label into a person's name. */
export function usablePersonName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.trim();
  if (!name || /[@\r\n\u0000-\u001f\u007f]/u.test(name)
    || /^(?:G[-–— ]?\d+|SL-\d{4}-[A-Z0-9]+|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/iu.test(name)) return null;
  return name;
}

export function contactPersonName(identity: ContactIdentity, fallback = "Deelnemer"): string {
  return usablePersonName(identity.personName) ?? usablePersonName(identity.parentName) ?? usablePersonName(identity.contactName) ?? fallback;
}

const value = (input: unknown) => typeof input === "string" ? input.trim() : "";
const distinct = (parts: string[]) => parts.filter((part, index) => part && parts.findIndex(other => other.toLocaleLowerCase("nl-NL") === part.toLocaleLowerCase("nl-NL")) === index);

export function walkingGroupLabel(identity: Pick<ContactIdentity, "groupCode" | "groupName">, fallback = "jullie groep"): string {
  return distinct([value(identity.groupCode), value(identity.groupName)]).join(" · ") || fallback;
}

/** The participant is primary; a code remains additional context, including after a reload. */
export function conversationIdentityLabel(identity: ContactIdentity): string {
  const code = value(identity.groupCode) || value(identity.systemCode);
  return distinct([contactPersonName(identity), code]).join(" · ");
}

export function messengerSenderLabel(message: { senderSide: string; senderName?: string | null }): string {
  return message.senderSide === "organization" ? "Organisatie" : usablePersonName(message.senderName) ?? "Deelnemer";
}
