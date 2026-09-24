import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { MAIL_MESSAGE_TYPES } from "./mail-catalog";
import { renderTransactionalMail, UnknownMailTemplateError } from "./templates";

const originalAppUrl = process.env.APP_URL;
const originalSiteUrl = process.env.NEXT_PUBLIC_SITE_URL;

beforeAll(() => {
  process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
  process.env.NEXT_PUBLIC_SITE_URL = "https://build.example.invalid";
});

afterAll(() => {
  if (originalAppUrl === undefined) delete process.env.APP_URL;
  else process.env.APP_URL = originalAppUrl;
  if (originalSiteUrl === undefined) delete process.env.NEXT_PUBLIC_SITE_URL;
  else process.env.NEXT_PUBLIC_SITE_URL = originalSiteUrl;
});

const completePayload = {
  code: "483921",
  expiresText: "De code verloopt over 10 minuten.",
  firstName: "Sam",
  groupName: "De Nachtdwalers",
  headGroup: "De Schaduwlopers",
  reference: "DDP-1042",
  childCount: 4,
  startPoint: "Tesselseplein",
  startAddress: "Besloten startadres 1",
  startsAt: "2026-10-31T17:30:00+01:00",
  ordinaryStopAt: "2026-10-31T19:30:00+01:00",
  requestedStops: 2,
  decision: "goedgekeurd",
  explanation: "Er is ruimte in het avondschema.",
  summary: "Kom naar het bijgewerkte startpunt.",
  organization: "Een lokale ondernemer",
  senderRole: "groepsleider",
  queueStatus: "in de wachtrij",
  title: "Een update voor vanavond",
  message: "Controleer de actuele informatie voordat jullie vertrekken.",
};

describe("premium transactional mail catalog", () => {
  it("renders every one of the 35 catalog keys as bounded HTML and matching plaintext", () => {
    expect(MAIL_MESSAGE_TYPES).toHaveLength(35);
    expect(new Set(MAIL_MESSAGE_TYPES).size).toBe(35);

    for (const messageType of MAIL_MESSAGE_TYPES) {
      const rendered = renderTransactionalMail({ messageType, payload: completePayload });
      expect(rendered.subject).toBeTruthy();
      expect(rendered.html).toContain('<html lang="nl">');
      expect(rendered.html).toContain("https://staging-halloween.duindorpdoet.nl/images/logo.webp");
      expect(rendered.text).toContain("De Duindorpse Poorten van Halloween");
      expect(Buffer.byteLength(rendered.html)).toBeLessThan(50 * 1024);
      expect(rendered.html).not.toContain("undefined");
      expect(rendered.text).not.toContain("undefined");
      expect(rendered.html).not.toContain("build.example.invalid");
    }
  });

  it("fails closed for an unknown message type", () => {
    expect(() => renderTransactionalMail({ messageType: "invented_status", payload: {} }))
      .toThrow(UnknownMailTemplateError);
    try {
      renderTransactionalMail({ messageType: "invented_status", payload: {} });
    } catch (error) {
      expect(error).toMatchObject({ code: "UNKNOWN_TEMPLATE" });
    }
  });

  it("escapes participant copy and rejects a multiline subject", () => {
    const escaped = renderTransactionalMail({
      messageType: "participant_update",
      payload: { title: "Route <pauze>", message: '<script>bad()</script> & "quotes"' },
    });
    expect(escaped.html).toContain("Route &lt;pauze&gt;");
    expect(escaped.html).toContain("&lt;script&gt;bad()&lt;/script&gt; &amp; &quot;quotes&quot;");
    expect(escaped.html).not.toContain("<script>bad");

    expect(() => renderTransactionalMail({
      messageType: "participant_update",
      payload: { title: "Hallo\r\nBcc: iemand@example.invalid", message: "Bericht" },
    })).toThrow(/Subject must be one line/);
  });

  it("keeps OTP codes out of subject and preheader and does not render a hero", () => {
    for (const messageType of ["auth_otp", "auth_email_change", "auth_email_change_new"] as const) {
      const rendered = renderTransactionalMail({ messageType, payload: { code: "483921" } });
      expect(rendered.subject).not.toContain("483921");
      expect(rendered.preheader).not.toContain("483921");
      expect(rendered.text).toContain("483921");
      expect(rendered.html).toContain("483921");
      expect(rendered.html).not.toContain('class="hero-image"');
    }
  });

  it("uses only the configured HTTPS origin for calls to action", () => {
    const invitation = renderTransactionalMail({
      messageType: "household_invite",
      payload: { actionPath: "/mijn-inschrijving?uitnodiging=abc123" },
    });
    expect(invitation.text).toContain("https://staging-halloween.duindorpdoet.nl/mijn-inschrijving?uitnodiging=abc123");

    const rejected = renderTransactionalMail({
      messageType: "household_invite",
      payload: { actionPath: "https://attacker.invalid/steal" },
    });
    expect(rejected.text).not.toContain("attacker.invalid");
    expect(rejected.text).toContain("https://staging-halloween.duindorpdoet.nl/mijn-inschrijving");
  });

  it("formats schedule timestamps in Europe/Amsterdam and exposes the private start only in schedule mail", () => {
    const schedule = renderTransactionalMail({
      messageType: "group_schedule_published",
      payload: completePayload,
    });
    expect(schedule.text).toContain("Tesselseplein");
    expect(schedule.text).toContain("Besloten startadres 1");
    expect(schedule.text).toContain("31 oktober 2026 om 17:30");
    expect(schedule.text).toContain("Geen nieuwe gewone poorten vanaf: 31 oktober 2026 om 19:30");

    const viewer = renderTransactionalMail({ messageType: "group_viewer_invite", payload: completePayload });
    expect(viewer.text).not.toContain("Besloten startadres 1");
  });

  it("keeps support conversation content in the authenticated environment", () => {
    const ticket = renderTransactionalMail({
      messageType: "group_ticket_message_organization",
      payload: { ticketReference: "TCK-000042", message: "Gevoelige inhoud", subject: "Privévraag" },
    });
    expect(ticket.text).toContain("TCK-000042");
    expect(ticket.text).not.toContain("Gevoelige inhoud");
    expect(ticket.text).not.toContain("Privévraag");
  });

  it("requires a clean HTTPS application URL", () => {
    process.env.APP_URL = "http://staging-halloween.duindorpdoet.nl";
    expect(() => renderTransactionalMail({ messageType: "contact_received", payload: {} }))
      .toThrow(/clean HTTPS URL/);
    process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
  });
});
