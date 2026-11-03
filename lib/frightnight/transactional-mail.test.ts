import { describe, expect, it } from "vitest";
import { renderFrightnightTransactionalMail } from "./transactional-mail";
const eventSlug = "frightnight-2027-test-mail";
const payload = { brandVersion: 7, orderId: "1b30219e-e56d-4e0c-8361-d1c290776ac0", amountCents: 1050 };
describe("FrightNight transactionele sinktemplates", () => {
  it("rendert hetzelfde exacte serverbedrag als tekst en afdrukbaar v7-voorbeeld zonder transport", () => {
    const result = renderFrightnightTransactionalMail("frightnight-payment-confirmed", payload, { eventSlug });
    expect(result.text).toContain("€ 10,50"); expect(result.html).toContain("€ 10,50");
    expect(result.html).toContain("TESTVOORBEELD · NIET VERZONDEN"); expect(result.text).toContain("Oogstdorp · Duinpad");
    expect(result).toMatchObject({ delivery: "sink", externallyDelivered: false });
    expect(result.subject).toContain("FrightNight 2027"); expect(result.html).toContain("#081712");
  });
  it("escapet contacttekst en weigert ongeldige templates, edities, bedragen en imagelinks", () => {
    const result = renderFrightnightTransactionalMail("frightnight-help-reply", { brandVersion: 7, label: "<script>alert(1)</script>", message: '<img src=x onerror="alert(1)">\nAntwoord' }, { eventSlug });
    expect(result.html).not.toContain("<script>"); expect(result.html).not.toContain("<img src=x");
    expect(result.html).toContain("&lt;script&gt;"); expect(result.html).toContain("<br>Antwoord");
    expect(() => renderFrightnightTransactionalMail("unknown", payload, { eventSlug })).toThrow("UNKNOWN_FRIGHTNIGHT_MAIL_TEMPLATE");
    expect(() => renderFrightnightTransactionalMail("frightnight-payment-confirmed", payload, { eventSlug: "duindorp-halloween-2026" })).toThrow();
    for (const amountCents of [0, -1, 10.5, Infinity]) expect(() => renderFrightnightTransactionalMail("frightnight-payment-confirmed", { ...payload, amountCents }, { eventSlug })).toThrow();
    expect(() => renderFrightnightTransactionalMail("frightnight-payment-confirmed", payload, { eventSlug, logoDataUri: "https://tracking.invalid/pixel" })).toThrow("INVALID_MAIL_IMAGE");
  });
  it("ondersteunt de afgesproken transactionele berichttypen uitsluitend als capture", () => {
    for (const template of ["registration-confirmed", "payment-status", "house-submitted", "house-approved", "reminder", "help-reply", "closed", "thanks"]) {
      const result = renderFrightnightTransactionalMail(`frightnight-${template}`, { brandVersion: 7, message: "Een bericht uit deze testeditie." }, { eventSlug });
      expect(result.externallyDelivered).toBe(false); expect(result.html).toContain(eventSlug);
    }
  });
});
