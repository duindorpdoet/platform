import { describe, expect, it } from "vitest";
import { validatePortalCertificateSnapshot } from "./portal-certificates";

const initial = { event: { id: "event-one", slug: "duindorp-halloween-2026", title: "Halloween" }, ready: true, confirmed: false, campaign: null, message: null, counts: { participatingHouses: 4, teamAccounts: 8, uniqueEmailRecipients: 6, missingContactAccounts: 2 }, mail: { pending: 0, queued: 0, processed: 0, providerAccepted: 0, delivered: 0, failed: 0, unknown: 0, suppressed: 0, retryableFailed: 0 } };
const check = (value: unknown) => validatePortalCertificateSnapshot(value, initial.event.slug, initial.event.id);
describe("certificate-campaign private snapshot validation", () => {
  it("accepts a complete current-event snapshot and valid immutable campaign", () => {
    expect(check(initial)).toEqual(initial);
    const campaign = { id: "campaign-one", createdAt: "2026-11-01T22:00:00Z", createdBy: "organizer-one", subject: "Dank!", body: "Eigen tekst\n\nExact bewaren." };
    expect(check({ ...initial, confirmed: true, campaign, message: { subject: campaign.subject, body: campaign.body } })).not.toBeNull();
  });
  it("rejects another event and incomplete or contradictory HTTP-200 bodies", () => {
    for (const value of [{ ok: true }, { ...initial, event: { ...initial.event, id: "other" } }, { ...initial, event: { ...initial.event, slug: "other" } }, { ...initial, confirmed: true }, { ...initial, counts: {} }, { ...initial, mail: { ...initial.mail, failed: -1 } }, { ...initial, mail: { ...initial.mail, queued: .5 } }]) expect(check(value)).toBeNull();
  });
  it("requires confirmed text and timestamp to match the authoritative campaign", () => {
    const campaign = { id: "campaign-one", createdAt: "2026-11-01T22:00:00Z", createdBy: "organizer-one", subject: "Dank!", body: "Vaste tekst" };
    expect(check({ ...initial, confirmed: true, campaign, message: { subject: "Ander onderwerp", body: campaign.body } })).toBeNull();
    expect(check({ ...initial, confirmed: true, campaign: { ...campaign, createdAt: "invalid" }, message: { subject: campaign.subject, body: campaign.body } })).toBeNull();
  });
});
