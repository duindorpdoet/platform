import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const environment = {
  SENDGRID_API_KEY: "test-key-never-sent",
  SENDGRID_API: undefined,
  SENDGRID_API_BASE_URL: "https://sendgrid.test/v3",
  SENDGRID_FROM_EMAIL: "halloween@duindorpdoet.nl",
  SENDGRID_FROM_NAME: "De Duindorpse Poorten van Halloween",
  SENDGRID_REPLY_TO: "halloween@duindorpdoet.nl",
  MAIL_MODE: "allowlist",
};

vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => environment,
  mailAllowlist: () => new Set(["halloweentest1@duindorpdoet.nl", "halloweentest2@duindorpdoet.nl"]),
}));

import { sendSendGrid } from "./sendgrid";

const message = {
  to: "halloweentest1@duindorpdoet.nl",
  subject: "Testbericht",
  text: "Tekst",
  html: "<p>Tekst</p>",
  outboxId: "outbox-1",
};

describe("SendGrid transactional adapter", () => {
  beforeEach(() => {
    environment.MAIL_MODE = "allowlist";
    vi.unstubAllGlobals();
  });

  it("rejects a staging recipient outside the explicit allowlist before any provider call", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    await expect(sendSendGrid({ ...message, to: "unexpected@example.invalid" })).rejects.toMatchObject({
      status: 403,
      code: "RECIPIENT_NOT_ALLOWED",
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("treats provider HTTP 202 only as accepted and preserves outbox correlation", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 202, headers: { "x-message-id": "provider-123" } }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(sendSendGrid({ ...message, to: " HalloweenTest1@DuindorpDoet.nl " })).resolves.toEqual({
      accepted: true,
      providerId: "provider-123",
    });
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));
    expect(body.personalizations[0]).toEqual({
      to: [{ email: "halloweentest1@duindorpdoet.nl" }],
      custom_args: { outbox_id: "outbox-1" },
    });
    expect(body.from).toEqual({ email: "halloween@duindorpdoet.nl", name: "De Duindorpse Poorten van Halloween" });
    expect(body.reply_to).toEqual({ email: "halloween@duindorpdoet.nl" });
  });

  it("does not report a non-202 provider response as accepted", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 429 })));

    await expect(sendSendGrid(message)).rejects.toMatchObject({ status: 502, code: "SENDGRID_429" });
  });

  it("enables provider sandbox mode without changing the recipient contract", async () => {
    environment.MAIL_MODE = "sandbox";
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 202 }));
    vi.stubGlobal("fetch", fetchMock);

    await sendSendGrid({ ...message, to: "sandbox@example.invalid" });
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));
    expect(body.mail_settings).toEqual({ sandbox_mode: { enable: true } });
    expect(body.personalizations[0].to[0].email).toBe("sandbox@example.invalid");
  });
});
