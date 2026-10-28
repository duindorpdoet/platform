import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import { renderTransactionalMail } from "./templates";
const originalAppUrl = process.env.APP_URL;
beforeAll(() => { process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl"; });
afterAll(() => { if (originalAppUrl === undefined) delete process.env.APP_URL; else process.env.APP_URL = originalAppUrl; });

describe("person and group fields in final transactional mail", () => {
  it("describes the G-46 samenloop without presenting a code as the contact person", () => {
    const rendered = renderTransactionalMail({ messageType: "group_merge_approved", payload: { headGroup: "G-46", groupName: "G-46", groupCode: "G-46", clusterReference: "SL-2026-9VPTQB" } });
    expect(rendered.subject).toBe("Jullie samenloop is bevestigd");
    expect(rendered.text).toContain("Jullie samenloop is bevestigd.");
    expect(rendered.text).toContain("Samenloopnummer: SL-2026-9VPTQB");
    expect(rendered.text).toContain("Wandelgroep: G-46");
    expect(rendered.text).not.toContain("De samenvoeging met G-46");
    expect(rendered.text).not.toContain("Hoi G-46");
  });
  it("does not select one contact as the name of several joined households", () => {
    const rendered = renderTransactionalMail({ messageType: "group_merge_approved", payload: { personName: "Élodie van 't Hof", householdLabel: "Familie van 't Hof", memberNames: ["Élodie van 't Hof", "Sam de Jong"], headGroup: "G-46", groupCode: "G-46", groupName: "De Nachtdwalers" } });
    expect(rendered.text).toContain("De aangesloten gezelschappen lopen samen.");
    expect(rendered.text).toContain("Wandelgroep: G-46 · De Nachtdwalers");
    expect(rendered.text).not.toContain("Élodie");
    expect(rendered.text).not.toContain("Sam de Jong");
  });
  it.each(["group_merge_requested", "group_merge_declined"])("keeps %s wording independent of a legacy headGroup name", messageType => {
    const rendered = renderTransactionalMail({ messageType, payload: { headGroup: "G-46", groupCode: "G-46", clusterReference: "SL-2026-9VPTQB" } });
    expect(rendered.text).not.toContain("bij G-46");
    expect(rendered.text).toContain("Wandelgroep: G-46");
  });
  it("uses the trusted full person name in personal mail and preserves accents and particles", () => {
    const rendered = renderTransactionalMail({ messageType: "registration_received", payload: { personName: "Élodie van 't Hof-de Peña", firstName: "G-28", groupName: "G-28", groupCode: "G-28" } });
    expect(rendered.text).toContain("Hoi Élodie van 't Hof-de Peña,");
    expect(rendered.html).toContain("Élodie van &#39;t Hof-de Peña");
    expect(rendered.text).not.toContain("Hoi G-28");
  });
  it("does not invent a missing person from group fields or email addresses", () => {
    for (const firstName of ["G-28", "ouder@example.invalid", ""]) {
      const rendered = renderTransactionalMail({ messageType: "registration_received", payload: { firstName, groupName: "G-28", householdLabel: "Familie Voorbeeld" } });
      expect(rendered.text).not.toContain("Hoi G-28");
      expect(rendered.text).not.toContain("Hoi ouder");
      expect(rendered.text).not.toContain("Familie Voorbeeld");
    }
  });
  it("does not describe a legacy group code as the named payer", () => {
    const rendered = renderTransactionalMail({ messageType: "payment_link_ready", payload: { payerName: "G-28", externalUrl: "https://betaalverzoek.ing.nl/verzoek/fixture", amountCents: 500 } });
    expect(rendered.text).not.toContain("G-28 regelt");
    expect(rendered.text).not.toContain("Betaler: G-28");
    expect(rendered.text).toContain("Spreek samen af wie het totaalbedrag betaalt");
  });
  it("does not repeat a group code in a composition confirmation", () => {
    const rendered = renderTransactionalMail({ messageType: "group_composition_confirmed", payload: { groupName: "G-28", groupCode: "G-28" } });
    expect(rendered.text.match(/G-28/g)).toHaveLength(1);
    expect(rendered.text).not.toContain("G-28 (G-28)");
  });
});
