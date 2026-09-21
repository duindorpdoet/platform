import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { renderTransactionalMail } from "./templates";

const originalSiteUrl = process.env.NEXT_PUBLIC_SITE_URL;

afterEach(() => {
  if (originalSiteUrl === undefined) delete process.env.NEXT_PUBLIC_SITE_URL;
  else process.env.NEXT_PUBLIC_SITE_URL = originalSiteUrl;
});

describe("transactional mail templates", () => {
  it("renders a same-origin one-time household invitation link", () => {
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
    process.env.NEXT_PUBLIC_SITE_URL = "https://halloween.duindorpdoet.nl";
    const invitation = renderTransactionalMail({
      messageType: "household_invite",
      payload: { actionPath: "https://attacker.invalid/steal" },
    });

    expect(invitation.text).not.toContain("attacker.invalid");
    expect(invitation.text).toContain("https://halloween.duindorpdoet.nl");
  });
});
