import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { renderTransactionalMail } from "./templates";

const originalAppUrl = process.env.APP_URL;
const originalSiteUrl = process.env.NEXT_PUBLIC_SITE_URL;

afterEach(() => {
  if (originalAppUrl === undefined) delete process.env.APP_URL;
  else process.env.APP_URL = originalAppUrl;
  if (originalSiteUrl === undefined) delete process.env.NEXT_PUBLIC_SITE_URL;
  else process.env.NEXT_PUBLIC_SITE_URL = originalSiteUrl;
});

describe("transactional mail templates", () => {
  it("uses the runtime application URL when a build-time public URL differs", () => {
    process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
    process.env.NEXT_PUBLIC_SITE_URL = "https://build.example.invalid";
    const notification = renderTransactionalMail({ messageType: "contact_notification", payload: {} });
    expect(notification.text).toContain(process.env.APP_URL);
    expect(notification.html).toContain(`href="${process.env.APP_URL}"`);
    expect(notification.text).not.toContain("build.example.invalid");
  });

  it("renders a same-origin one-time household invitation link", () => {
    delete process.env.APP_URL;
    process.env.NEXT_PUBLIC_SITE_URL = "https://staging-halloween.duindorpdoet.nl";
    const invitation = renderTransactionalMail({
      messageType: "household_invite",
      payload: { actionPath: "/mijn-inschrijving?uitnodiging=abc123" },
    });

    expect(invitation.subject).toBe("Uitnodiging voor gezinstoegang");
    expect(invitation.text).toContain("https://staging-halloween.duindorpdoet.nl/mijn-inschrijving?uitnodiging=abc123");
    expect(invitation.html).toContain('href="https://staging-halloween.duindorpdoet.nl/mijn-inschrijving?uitnodiging=abc123"');
  });

  it("rejects an external or script-like action path", () => {
    delete process.env.APP_URL;
    process.env.NEXT_PUBLIC_SITE_URL = "https://halloween.duindorpdoet.nl";
    const invitation = renderTransactionalMail({
      messageType: "household_invite",
      payload: { actionPath: "https://attacker.invalid/steal" },
    });

    expect(invitation.text).not.toContain("attacker.invalid");
    expect(invitation.text).toContain("https://halloween.duindorpdoet.nl");
  });

  it("renders a privacy-safe viewer invitation into the unified environment", () => {
    process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
    const invitation = renderTransactionalMail({
      messageType: "group_viewer_invite",
      payload: { actionPath: "/omgeving?meekijkuitnodiging=abc123" },
    });

    expect(invitation.subject).toBe("Uitnodiging om een groep te volgen");
    expect(invitation.text).toContain("Kindernamen, live GPS en toekomstige adressen blijven verborgen.");
    expect(invitation.text).toContain("https://staging-halloween.duindorpdoet.nl/omgeving?meekijkuitnodiging=abc123");
  });

  it("escapes custom role update copy", () => {
    const update = renderTransactionalMail({
      messageType: "participant_update",
      payload: { title: "Route <pauze>", message: "Wacht & blijf samen." },
    });

    expect(update.subject).toBe("Route <pauze>");
    expect(update.html).toContain("Route &lt;pauze&gt;");
    expect(update.html).toContain("Wacht &amp; blijf samen.");
  });

  it("escapes public-form fields in organization notifications", () => {
    const notification = renderTransactionalMail({
      messageType: "contact_notification",
      payload: {
        ticketReference: "ticket-1",
        contactName: "<img src=x onerror=alert(1)>",
        contactEmail: "sender@example.invalid",
        subject: "Vraag <script>alert(1)</script>",
        message: "Hallo & welkom",
      },
    });

    expect(notification.subject).toBe("Nieuw contactbericht");
    expect(notification.text).toContain("sender@example.invalid");
    expect(notification.html).toContain("&lt;img src=x onerror=alert(1)&gt;");
    expect(notification.html).not.toContain("<script>");
    expect(notification.html).toContain("Hallo &amp; welkom");
  });

  it.each([
    ["group_ticket_message_organization", "/admin", "Nieuw bericht bij Hulp & contact"],
    ["group_ticket_message_leader", "/omgeving/meeloper/groep", "Nieuw bericht over jouw groep"],
  ])("renders private ticket notification %s", (messageType, actionPath, subject) => {
    process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
    const notification = renderTransactionalMail({
      messageType,
      payload: {
        ticketReference: "TCK-000042",
        subject: "Route <wijziging>",
        message: "Kunnen jullie & helpen?",
        senderLabel: "Groepsleider",
        actionPath,
      },
    });

    expect(notification.subject).toBe(subject);
    expect(notification.text).toContain(`https://staging-halloween.duindorpdoet.nl${actionPath}`);
    expect(notification.html).toContain("Route &lt;wijziging&gt;");
    expect(notification.html).toContain("Kunnen jullie &amp; helpen?");
    expect(notification.text).toContain("Van: Groepsleider");
  });

  it.each([
    ["group_schedule_published", "Startpunt en starttijd bevestigd"],
    ["group_schedule_corrected", "Correctie van jullie groepsstart"],
  ])("renders private, versioned schedule message %s", (messageType, subject) => {
    process.env.APP_URL = "https://staging-halloween.duindorpdoet.nl";
    const notification = renderTransactionalMail({
      messageType,
      payload: {
        startPoint: "Verzamelplek Zuid",
        startAddress: "Besloten startadres 1",
        startsAt: "2026-10-31T17:30:00+01:00",
        ordinaryStopAt: "2026-10-31T19:30:00+01:00",
        actionPath: "/omgeving/meeloper/nu",
      },
    });

    expect(notification.subject).toBe(subject);
    expect(notification.text).toContain("Verzamelplek Zuid");
    expect(notification.text).toContain("31 oktober 2026 om 17:30");
    expect(notification.text).toContain("Geen nieuwe gewone poorten vanaf: 31 oktober 2026 om 19:30");
    expect(notification.text).not.toContain("Testpoort");
  });
});
