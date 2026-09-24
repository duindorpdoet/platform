import { describe, expect, it } from "vitest";
import { renderAuthMail } from "./auth-template";

describe("premium Auth mail renderer", () => {
  it.each([
    ["auth_otp", "Je code voor De Duindorpse Poorten", "De poort gaat voor je open."],
    ["auth_email_change", "Bevestig de wijziging van je e-mailadres", "Controle op je huidige adres."],
    ["auth_email_change_new", "Bevestig je nieuwe e-mailadres", "Controle op je nieuwe adres."],
  ] as const)("renders %s as branded HTML and plaintext", (template, subject, title) => {
    const rendered = renderAuthMail({
      template,
      token: "483921",
      siteUrl: "https://staging-halloween.duindorpdoet.nl",
      supportEmail: "halloween@duindorpdoet.nl",
    });
    expect(rendered.subject).toBe(subject);
    expect(rendered.subject).not.toContain("483921");
    expect(rendered.preheader).not.toContain("483921");
    expect(rendered.html).toContain(title);
    expect(rendered.html).toContain("483921");
    expect(rendered.text).toContain("483921");
    expect(rendered.html).toContain("https://staging-halloween.duindorpdoet.nl/images/logo.webp");
    expect(rendered.html).not.toContain("hero-image");
    expect(Buffer.byteLength(rendered.html)).toBeLessThan(50 * 1024);
  });

  it("rejects unsafe asset origins and malformed codes", () => {
    expect(() => renderAuthMail({
      template: "auth_otp",
      token: "123456",
      siteUrl: "http://halloween.duindorpdoet.nl",
      supportEmail: "halloween@duindorpdoet.nl",
    })).toThrow(/clean HTTPS URL/);
    expect(() => renderAuthMail({
      template: "auth_otp",
      token: "12 34",
      siteUrl: "https://halloween.duindorpdoet.nl",
      supportEmail: "halloween@duindorpdoet.nl",
    })).toThrow(/Invalid Auth code/);
  });
});
