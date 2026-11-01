export type EveningClosure = {
  id: string;
  closedAt: string;
  subject: string;
  body: string;
  messageVersion?: number;
  readAt?: string | null;
  portalCount?: number;
};

export type EveningClosurePortal = {
  id: string;
  name: string;
  worldId?: string | null;
  worldSlug?: string | null;
  worldName?: string | null;
  finale?: boolean;
  presentation?: unknown;
  visited: true;
  source: "event_closure";
};

export type EveningClosureMail = {
  queued: number;
  processed: number;
  providerAccepted: number;
  delivered: number;
  failed: number;
  unknown: number;
  suppressed: number;
  houseFailed?: number;
};

export type EveningClosureSnapshot = {
  event: { id: string; slug: string; title: string };
  closed: boolean;
  closure: EveningClosure | null;
  counts?: {
    participantAccounts: number;
    children: number;
    participatingHouses: number;
    uniqueEmailRecipients: number;
    missingContactAccounts: number;
    pendingActivations?: number;
  };
  mail?: EveningClosureMail;
  portals?: EveningClosurePortal[];
  requeued?: number;
};

/** The authenticated Next API uses the application's existing data envelope. */
export function eveningClosureResponse(value: unknown): unknown {
  return value && typeof value === "object" && "data" in value ? value.data : null;
}

/** Reject a response for another event before it can enter a private view. */
export function isEveningClosureSnapshot(value: unknown, eventSlug: string, eventId?: string): value is EveningClosureSnapshot {
  if (!value || typeof value !== "object") return false;
  const snapshot = value as Partial<EveningClosureSnapshot>;
  if (snapshot.event?.slug !== eventSlug || (eventId && snapshot.event.id !== eventId) || typeof snapshot.closed !== "boolean") return false;
  if (!snapshot.closed) return snapshot.closure === null;
  const closure = snapshot.closure;
  return Boolean(closure && typeof closure.id === "string" && typeof closure.closedAt === "string" && typeof closure.subject === "string" && typeof closure.body === "string");
}
