export type ThankChoice = "beautiful" | "welcome" | "treats";
export type HouseInboxMessage = { id: string; kind: "all" | "personal"; choice: ThankChoice | null; message: string; senderLabel: string; receivedAt: string; read: boolean; missingContacts: number; mailCounts: Record<string, number> };
export type HouseInbox = { portalId: string; portalName: string; total: number; unread: number; nextCursor: string | null; counters: { general: number; personal: number; beautiful: number; welcome: number; treats: number }; aggregateOnlyCount: number; customMessageCount: number; messages: HouseInboxMessage[] };
export type LegacyHouseThank = { portalId: string; portalName: string; choice: ThankChoice };
const record = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const count = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const choice = (value: unknown): value is ThankChoice => value === "beautiful" || value === "welcome" || value === "treats";

/** The redesign endpoint returns raw JSON. Never interpret a missing/foreign payload as zero. */
export function parseHouseInbox(value: unknown, portalId?: string): HouseInbox {
  if (!record(value) || typeof value.portalId !== "string" || !value.portalId || (portalId && value.portalId !== portalId) || typeof value.portalName !== "string" ||
    !count(value.total) || !count(value.unread) || !count(value.aggregateOnlyCount) || !count(value.customMessageCount) || !record(value.counters) ||
    !["general", "personal", "beautiful", "welcome", "treats"].every(key => count((value.counters as Record<string, unknown>)[key])) ||
    (value.nextCursor !== null && typeof value.nextCursor !== "string") || !Array.isArray(value.messages) ||
    value.messages.some(item => !record(item) || typeof item.id !== "string" || !item.id || !["all", "personal"].includes(String(item.kind)) || (item.choice !== null && !choice(item.choice)) ||
      typeof item.message !== "string" || typeof item.senderLabel !== "string" || typeof item.receivedAt !== "string" || !Number.isFinite(Date.parse(item.receivedAt)) || typeof item.read !== "boolean" || !count(item.missingContacts) || !record(item.mailCounts) || !Object.values(item.mailCounts).every(count))) {
    throw new Error("INVALID_THANKS_RESPONSE");
  }
  if (value.total !== value.aggregateOnlyCount + value.customMessageCount || value.unread > value.customMessageCount || value.messages.length > value.customMessageCount) throw new Error("INVALID_THANKS_RESPONSE");
  return value as HouseInbox;
}

export function parseLegacyHouseThanks(value: unknown, portalId: string): LegacyHouseThank[] {
  if (!record(value) || !Array.isArray(value.thanks) || value.thanks.some(item => !record(item) || item.portalId !== portalId || typeof item.portalName !== "string" || !choice(item.choice))) throw new Error("INVALID_THANKS_RESPONSE");
  return value.thanks as LegacyHouseThank[];
}
