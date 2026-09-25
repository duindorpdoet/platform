export type PortalRegistrationStatus =
  | "awaiting_otp"
  | "activated_incomplete"
  | "ready_for_review"
  | "changes_requested"
  | "approved"
  | "closed";

export const portalRegistrationStatusLabels: Record<PortalRegistrationStatus, string> = {
  awaiting_otp: "Aangemeld — wacht op OTP",
  activated_incomplete: "Omgeving geactiveerd — gegevens nog aanvullen",
  ready_for_review: "Klaar voor beoordeling",
  changes_requested: "Aanpassing gevraagd",
  approved: "Goedgekeurd",
  closed: "Afgewezen of ingetrokken",
};

export type PortalRegistrationProgress = {
  contact: boolean;
  address: boolean;
  experience: boolean;
  planning: boolean;
};

export function countPortalRegistrationProgress(progress: PortalRegistrationProgress) {
  const completed = Object.values(progress).filter(Boolean).length;
  return { completed, total: 4, percentage: completed * 25 };
}

export function formatPortalAddress(address: {
  street?: string | null;
  houseNumber?: string | null;
  addition?: string | null;
  postalCode?: string | null;
  city?: string | null;
} | null | undefined) {
  if (!address) return "Niet ingevuld";
  const firstLine = [address.street, address.houseNumber, address.addition].filter(Boolean).join(" ");
  const secondLine = [address.postalCode, address.city ?? (firstLine ? "Den Haag" : null)].filter(Boolean).join(" ");
  return [firstLine, secondLine].filter(Boolean).join(", ") || "Niet ingevuld";
}

