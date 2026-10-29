import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
import { renderTransactionalMail } from "./templates";

const previousUrl = process.env.APP_URL;
beforeAll(() => { process.env.APP_URL = "https://halloween.example.invalid"; });
afterAll(() => { if (previousUrl === undefined) delete process.env.APP_URL; else process.env.APP_URL = previousUrl; });

const family = { personName: "Synthetische Ouder", registrationReference: "TEST-GEZIN", children: ["Testkind Eén", "Testkind Twee", "Testkind Drie"] };

describe("personal registration mail", () => {
  it("invites one family with all children without inventing a confirmed group or payment", () => {
    const rendered = renderTransactionalMail({ messageType: "registration_activation", payload: { ...family, actionPath: "/uitnodiging/inschrijving/local-test-token", expiresAt: "2026-11-05T12:00:00Z" } });
    expect(rendered.text).toContain("Hoi Synthetische Ouder");
    for (const child of family.children) expect(rendered.text).toContain(child);
    expect(rendered.text).toContain("nog niet bij een loopgroep");
    expect(rendered.text).toContain("betekent niet dat er al is betaald");
    expect(rendered.text).toContain("https://halloween.example.invalid/uitnodiging/inschrijving/local-test-token");
    expect(rendered.subject).not.toContain("local-test-token");
  });

  it("names the new group and the current confirmed time without leaking any start address", () => {
    const rendered = renderTransactionalMail({ messageType: "registration_group_changed", payload: { ...family, groupName: "Testnachtdwalers", groupCode: "G-TEST", startConfirmed: true, startsAt: "2026-10-31T17:30:00Z", addressReleaseAt: "2026-10-31T16:30:00Z", addressReleased: false, startAddress: "SYNTHETIC-SECRET-ADDRESS", latitude: 52.123 } });
    expect(rendered.subject).toBe("Jullie groepsindeling is aangepast");
    expect(rendered.text).toContain("Hoi Synthetische Ouder");
    expect(rendered.text).toContain("Testnachtdwalers");
    expect(rendered.text).toContain("G-TEST");
    expect(rendered.text).toContain("18:30");
    expect(rendered.text).toContain("17:30");
    expect(rendered.text).not.toContain("SYNTHETIC-SECRET-ADDRESS");
    expect(rendered.html).not.toContain("52.123");
  });

  it("keeps a draft time provisional even when a startsAt field exists", () => {
    const rendered = renderTransactionalMail({ messageType: "registration_group_changed", payload: { ...family, groupName: "Testgroep", groupCode: "G-TEST", startConfirmed: false, startsAt: "2026-10-31T17:30:00Z" } });
    expect(rendered.text).toContain("nog niet bevestigd");
    expect(rendered.text).toContain("voorlopig");
    expect(rendered.text).not.toContain("18:30");
    expect(rendered.text).not.toContain("Bevestigde starttijd");
  });

  it("retains the secure activation route for a pending family that moves", () => {
    const rendered = renderTransactionalMail({ messageType: "registration_group_changed", payload: { ...family, activationPending: true, groupCode: "G-TEST", actionPath: "/uitnodiging/inschrijving/rotated-test-token" } });
    expect(rendered.text).toContain("nieuwe groepsindeling blijft daarbij behouden");
    expect(rendered.text).toContain("Log in en activeer jullie inschrijving");
    expect(rendered.text).toContain("https://halloween.example.invalid/uitnodiging/inschrijving/rotated-test-token");
  });

  it.each(["registration_activation", "registration_group_changed"])("escapes child names and rejects external invitation destinations in %s", (messageType) => {
    const rendered = renderTransactionalMail({ messageType, payload: { ...family, children: ["<script>synthetic()</script>"], actionPath: "//other.example.invalid/claim" } });
    expect(rendered.html).toContain("&lt;script&gt;synthetic()&lt;/script&gt;");
    expect(rendered.html).not.toContain("<script>synthetic");
    expect(rendered.text).not.toContain("other.example.invalid");
  });
});
