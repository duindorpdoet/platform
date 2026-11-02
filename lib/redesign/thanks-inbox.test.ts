import { describe, expect, it } from "vitest";
import { parseHouseInbox, parseLegacyHouseThanks } from "./thanks-inbox";
const portalId = "synthetic-gate";
const inbox = () => ({ portalId, portalName: "De pompoen", total: 3, unread: 1, aggregateOnlyCount: 2, customMessageCount: 1, counters: { general: 2, personal: 1, beautiful: 1, welcome: 0, treats: 0 }, messages: [{ id: "receipt", kind: "personal", choice: "beautiful", message: "Dank voor jullie decor!", senderLabel: "Een gezin uit Duindorp", receivedAt: "2026-11-01T20:00:00Z", read: false, missingContacts: 0, mailCounts: { delivered: 1 } }], nextCursor: null });
describe("raw private house thanks responses", () => {
  it("accepts explicit valid counters, including a confirmed empty result", () => {
    expect(parseHouseInbox(inbox(), portalId)).toMatchObject({ total: 3, unread: 1 });
    expect(parseHouseInbox({ ...inbox(), total: 0, unread: 0, aggregateOnlyCount: 0, customMessageCount: 0, counters: { general: 0, personal: 0, beautiful: 0, welcome: 0, treats: 0 }, messages: [] }, portalId).total).toBe(0);
  });
  it("never substitutes zero for a missing, wrapped, malformed or foreign response", () => {
    for (const value of [null, {}, { data: inbox() }, { ...inbox(), portalId: "foreign-gate" }, { ...inbox(), messages: undefined }, { ...inbox(), total: -1 }, { ...inbox(), total: 0 }, { ...inbox(), unread: 2 }, { ...inbox(), counters: {} }, { ...inbox(), messages: [{ ...inbox().messages[0], mailCounts: { delivered: -1 } }] }]) expect(() => parseHouseInbox(value, portalId)).toThrow("INVALID_THANKS_RESPONSE");
  });
  it("keeps historical reactions as a separate own-house collection rather than assuming an empty list", () => {
    const historical = { thanks: [{ portalId, portalName: "De pompoen", choice: "welcome" }] };
    expect(parseLegacyHouseThanks(historical, portalId)).toHaveLength(1);
    expect(parseLegacyHouseThanks({ thanks: [] }, portalId)).toEqual([]);
    for (const value of [{}, { data: historical }, { thanks: [{ ...historical.thanks[0], portalId: "foreign-gate" }] }, { thanks: [{ ...historical.thanks[0], choice: "unknown" }] }]) expect(() => parseLegacyHouseThanks(value, portalId)).toThrow("INVALID_THANKS_RESPONSE");
  });
});
