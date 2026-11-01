import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import { renderTransactionalMail } from "./templates";
import { EVENING_CLOSURE_BODY, EVENING_CLOSURE_SUBJECT } from "@/lib/event-evening/defaults";
import { PORTAL_CERTIFICATE_BODY, PORTAL_CERTIFICATE_SUBJECT } from "@/lib/event-evening/portal-certificate-defaults";
beforeEach(() => vi.stubEnv("APP_URL", "https://app.example.invalid"));
afterEach(() => vi.unstubAllEnvs());
describe("fixed event closure and individual resident mail", () => {
  it("renders the organization's certificate notice and FrightNight invitation with a fixed private-room link", () => {
    const body = PORTAL_CERTIFICATE_BODY + '\n\nEigen aanvulling <script>alert("x")</script>.';
    const mail = renderTransactionalMail({ messageType: "portal_certificate_ready", payload: { subject: PORTAL_CERTIFICATE_SUBJECT, body, actionPath: "/mijn-huis?claim=secret" } });
    expect(mail.subject).toBe(PORTAL_CERTIFICATE_SUBJECT);
    expect(mail.text).toContain(body);
    expect(mail.text).toContain("Duindorp FrightNight nog groter en nog succesvoller");
    expect(mail.text).toContain("https://app.example.invalid/mijn-huis");
    expect(mail.text).not.toContain("claim=secret");
    expect(mail.html).not.toContain("<script>");
    expect(mail.html).toContain("&lt;script&gt;");
    expect(() => renderTransactionalMail({ messageType: "portal_certificate_ready", payload: {} })).toThrow();
    expect(() => renderTransactionalMail({ messageType: "portal_certificate_ready", payload: { subject: "bad\r\nBcc: x", body: "Hallo" } })).toThrow();
  });
  it("renders the exact confirmed subject and full original/added paragraphs in both formats", () => {
    const body = "\n" + EVENING_CLOSURE_BODY + "\n\nEigen alinea.\nNog een regel.\n";
    const subject = "  Een persoonlijk slotbericht 🎃 ";
    const mail = renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject, body } });
    expect(mail.subject).toBe(subject);
    expect(mail.text).toContain(body);
    expect(mail.html).toContain("Eigen alinea.<br>Nog een regel.<br>");
    expect(mail.text).toContain("/omgeving/meeloper/nu");
    expect(mail.text).not.toContain("de poorten die jullie echt hebben bereikt");
  });
  it("keeps every byte of the supplied default organization message", () => {
    const mail = renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject: EVENING_CLOSURE_SUBJECT, body: EVENING_CLOSURE_BODY } });
    expect(mail.subject).toBe(EVENING_CLOSURE_SUBJECT);
    expect(mail.text).toContain(EVENING_CLOSURE_BODY);
  });
  it("accepts the complete 20k editing limit without silently truncating or changing long paragraphs", () => {
    const body = "a".repeat(19_980) + "\n\nAlle alinea’s.";
    const mail = renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject: "Bedankt", body } });
    expect(mail.text).toContain(body);
    expect(() => renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject: "Bedankt", body: "a".repeat(20_001) } })).toThrow();
  });
  it("escapes editable copy and refuses header injection or missing confirmed material", () => {
    const mail = renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject: "Dank <iedereen>", body: '<script>alert("x")</script>\n<img src=x onerror=evil()> & leuk' } });
    expect(mail.html).not.toContain("<script>");
    expect(mail.html).not.toContain("<img src=x");
    expect(mail.html).toContain("&lt;script&gt;");
    expect(mail.html).toContain("<br>&lt;img");
    expect(() => renderTransactionalMail({ messageType: "event_closure_thanks", payload: { subject: "Dank\r\nBcc: test@example.invalid", body: "Hoi" } })).toThrow();
    expect(() => renderTransactionalMail({ messageType: "event_closure_thanks", payload: {} })).toThrow();
  });
  it.each(["all", "personal"])("renders one %s received thank with safe sender and authenticated fixed route", kind => {
    const mail = renderTransactionalMail({ messageType: "house_thanks_received", payload: { kind, portalName: "De mooie <poort>", choice: "welcome", message: "Bedankt!\nWat een avond.", senderLabel: "DO-NOT-EXPOSE test@example.invalid Kindnaam", actionPath: "https://evil.example.invalid/?claim=secret", portalRoomPath: "/mijn-huis?claim=secret" } });
    expect(mail.text).toContain(kind === "all" ? "Algemeen bedankje" : "extra persoonlijk bedankje");
    expect(mail.text).toContain("Fijne ontvangst");
    expect(mail.text).toContain("Bedankt!\nWat een avond.");
    expect(mail.text).toContain("Van: Een gezin uit Duindorp");
    expect(mail.html).toContain("De mooie &lt;poort&gt;");
    expect(mail.html).not.toContain("DO-NOT-EXPOSE");
    expect(mail.text).not.toContain("claim=secret");
    expect(mail.text).not.toContain("evil.example.invalid");
    expect(mail.text).toContain("https://app.example.invalid/mijn-huis");
  });
});
