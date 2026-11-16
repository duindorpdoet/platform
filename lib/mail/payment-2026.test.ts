import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { contentForMessage } from "./mail-catalog";
import { InvalidMailTemplateError, renderPremiumEmail } from "./premium-template";
import { configuredBrand, renderTransactionalMail } from "./templates";

const base = {
  personName: "Voorbeeldouder", groupCode: "G-VOORBEELD", groupName: "Fictief gezelschap",
  registrationReference: "VOORBEELD-2026-0001", amountCents: 500,
};
const externalUrl = "https://voorbeeld-betaling.invalid/geen-echte-betaling";
const examples: Array<{ id: string; payload: Record<string, unknown> }> = [
  { id: "01-betaallink-kinderen", payload: { ...base,
    paymentChildren: ["Voorbeeldkind A", "Voorbeeldkind B"],
    paymentChildDetails: [{ name: "Voorbeeldkind A", amountCents: 250 }, { name: "Voorbeeldkind B", amountCents: 250 }],
    anchorChildName: "Voorbeeldkind A", externalUrl, actionPath: "/omgeving/meeloper/nachtpas",
  } },
  { id: "02-betaallink-gezamenlijk-met-betaler", payload: { ...base,
    payerName: "Voorbeeldbetaler", paymentParticipants: ["Fictief gezin A", "Fictief gezin B"],
    externalUrl, actionPath: "/omgeving/meeloper/nu",
  } },
  { id: "03-betaallink-gezamenlijk-zonder-betaler", payload: { ...base,
    paymentParticipants: ["Fictief gezin A", "Fictief gezin B"], externalUrl, actionPath: "/omgeving/meeloper/nu",
  } },
  { id: "04-betaalinstructie-zonder-externe-link", payload: { ...base } },
];
const render = (payload: Record<string, unknown> = base, messageType = "payment_link_ready") =>
  renderTransactionalMail({ messageType, payload });

beforeEach(() => {
  vi.stubEnv("APP_ENVIRONMENT", "production");
  vi.stubEnv("EVENT_SLUG", "duindorp-halloween-2026");
  vi.stubEnv("APP_URL", "https://halloween.duindorpdoet.nl");
  vi.stubEnv("NEXT_PUBLIC_SITE_URL", "https://unused-build.example.invalid");
  vi.stubEnv("ORGANIZATION_SUPPORT_EMAIL", undefined);
});
afterEach(() => { vi.unstubAllEnvs(); });

describe("the approved final Halloween 2026 payment request", () => {
  it.each(examples)("matches the supplied HTML and plaintext byte for byte: $id", ({ id, payload }) => {
    const mail = render(payload);
    expect(mail.html).toBe(readFileSync(new URL(`./fixtures/halloween-2026/${id}.html`, import.meta.url), "utf8"));
    expect(mail.text).toBe(readFileSync(new URL(`./fixtures/halloween-2026/${id}.txt`, import.meta.url), "utf8"));
    expect(mail.subject).toBe("Laatste betaalverzoek voor Halloween 2026");
    expect(mail.preheader).toBe("De tocht is voorbij. Hier staat de actuele betaalinstructie voor jullie openstaande bijdrage.");
    expect(mail.text).toContain("Een laatste betaalverzoek");
    expect(mail.text).toContain("Hoi Voorbeeldouder,");
    expect(mail.text).toContain("Totaal te betalen: €\u00a05,00");
    expect(mail.text).toContain("Groetjes,\nTeam Duindorpse Poorten");
    expect(mail.text).not.toMatch(/30 oktober/i);
    expect(mail.html).not.toContain("unused-build.example.invalid");
  });

  it.each([
    { environment: "staging", edition: "duindorp-halloween-2026" },
    { environment: "test", edition: "duindorp-halloween-2026" },
    { environment: "production", edition: "frightnight-2027-test" },
    { environment: "production", edition: undefined },
    { environment: undefined, edition: "duindorp-halloween-2026" },
  ])("keeps the original request outside the exact production edition: $environment/$edition", ({ environment, edition }) => {
    vi.stubEnv("APP_ENVIRONMENT", environment); vi.stubEnv("EVENT_SLUG", edition);
    const mail = render({ ...examples[0].payload, APP_ENVIRONMENT: "production", eventSlug: "duindorp-halloween-2026" });
    expect(mail.subject).toBe("Betaling van je inschrijving");
    expect(mail.text).toContain("We verzoeken je vriendelijk om de betaling uiterlijk 30 oktober te voltooien");
    expect(mail.text).not.toContain("Een laatste betaalverzoek");
    expect(mail.text).toContain("Tot tussen de poorten,");
  });

  it.each(["payment_reminder", "payment_reported", "payment_confirmed", "payment_deadline_missed"])(
    "does not rewrite another payment message: %s", messageType => {
      for (const payload of [base, examples[0].payload, { ...examples[1].payload, paymentChildren: [] }]) {
        const production = render(payload, messageType);
        vi.stubEnv("APP_ENVIRONMENT", "staging");
        expect(render(payload, messageType)).toEqual(production);
        vi.stubEnv("APP_ENVIRONMENT", "production");
        expect(production.subject).not.toBe("Laatste betaalverzoek voor Halloween 2026");
        expect(production.text).not.toContain("Groetjes,");
      }
    },
  );

  it("keeps family labels and the named payer when a joint payment contains an empty child list", () => {
    const expected = render(examples[1].payload);
    const mail = render({ ...examples[1].payload, paymentChildren: [] });
    expect(mail).toEqual(expected);
    expect(mail.text).toContain("Voorbeeldbetaler regelt de gezamenlijke betaling");
    expect(mail.text).toContain("Betaler: Voorbeeldbetaler");
    expect(mail.text).toContain("Voor: Fictief gezin A");
    expect(mail.text).toContain("Voor: Fictief gezin B");
    expect(mail.text).not.toContain("Voor kind:");
  });

  it("keeps the external payment action or the existing private-environment fallback", () => {
    const linked = render(examples[0].payload);
    expect(linked.text).toContain(`Open de betaallink: ${externalUrl}`);
    expect(linked.html).toContain(`href="${externalUrl}"`);
    const fallback = render();
    expect(fallback.text).toContain("Open jullie persoonlijke omgeving voor de actuele betaalinstructie.");
    expect(fallback.text).toContain("Bekijk de betaling: https://halloween.duindorpdoet.nl/mijn-inschrijving");
    expect(fallback.text).not.toContain(externalUrl);
    expect(() => render({ ...base, externalUrl: "javascript:alert(1)" })).toThrow(InvalidMailTemplateError);
  });

  it("uses server-configured branding and support rather than arbitrary payload fields", () => {
    vi.stubEnv("APP_URL", "https://configured.example.invalid");
    vi.stubEnv("ORGANIZATION_SUPPORT_EMAIL", "support@example.invalid");
    const mail = render({ ...base, supportEmail: "payload@example.invalid", homeUrl: "https://untrusted.example.invalid" });
    expect(mail.text).toContain("Vragen? support@example.invalid");
    expect(mail.text).toContain("Website: https://configured.example.invalid/");
    expect(mail.text).toContain("Bekijk de betaling: https://configured.example.invalid/mijn-inschrijving");
    expect(mail.text).not.toContain("payload@example.invalid");
    expect(mail.html).not.toContain("untrusted.example.invalid");
  });

  it("does not invent a person or payer from a group code or an email address", () => {
    for (const personName of ["", "G-28", "parent@example.invalid"]) {
      const mail = render({ ...examples[2].payload, personName, payerName: "G-28" });
      expect(mail.text).toContain("Hoi, de Halloweentocht");
      expect(mail.text).toContain("Spreek samen af wie het totaalbedrag betaalt.");
      expect(mail.text).not.toContain("Hoi G-28");
      expect(mail.text).not.toContain("Hoi parent");
      expect(mail.text).not.toContain("Betaler: G-28");
    }
  });

  it("escapes an explicit closing greeting and leaves it as literal plaintext", () => {
    const brand = configuredBrand();
    const content = contentForMessage("payment_link_ready", base, brand);
    const mail = renderPremiumEmail({ ...content, closingGreeting: '<img src=x onerror="alert(1)"> & groetjes' }, brand);
    expect(mail.html).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; groetjes");
    expect(mail.html).not.toContain('<img src=x onerror="alert(1)">');
    expect(mail.text).toContain('<img src=x onerror="alert(1)"> & groetjes');
  });

  it("bounds an explicitly supplied greeting and rejects blank or excessive content", () => {
    const brand = configuredBrand();
    const content = contentForMessage("payment_link_ready", base, brand);
    expect(() => renderPremiumEmail({ ...content, closingGreeting: "x".repeat(200) }, brand)).not.toThrow();
    for (const closingGreeting of ["", "   ", "x".repeat(201)]) {
      expect(() => renderPremiumEmail({ ...content, closingGreeting }, brand)).toThrow(InvalidMailTemplateError);
    }
  });
});
