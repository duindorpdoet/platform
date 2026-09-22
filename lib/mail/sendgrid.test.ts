import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const environment = {
  NEXT_PUBLIC_SUPABASE_URL: "https://project-ref.supabase.co",
  SEND_EMAIL_HOOK_SECRET: `v1,whsec_${Buffer.alloc(32, 1).toString("base64")}`,
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

describe("signed transactional mail gateway adapter", () => {
  beforeEach(() => {
    environment.MAIL_MODE = "allowlist";
    vi.unstubAllGlobals();
  });

  it("rejects a staging recipient outside the explicit allowlist before any gateway call", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    await expect(sendSendGrid({ ...message, to: "unexpected@example.invalid" })).rejects.toMatchObject({
      status: 403,
      code: "RECIPIENT_NOT_ALLOWED",
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("signs the transactional envelope and preserves outbox correlation", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(null, { status: 200, headers: { "x-provider-message-id": "provider-123" } }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(sendSendGrid({ ...message, to: " HalloweenTest1@DuindorpDoet.nl " })).resolves.toEqual({
      accepted: true,
      providerId: "provider-123",
    });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://project-ref.supabase.co/functions/v1/send-email-hook");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>)["webhook-signature"]).toBeTruthy();
    expect((init.headers as Record<string, string>)["webhook-id"]).toMatch(/^msg_/);

    const body = JSON.parse(String(init.body));
    expect(body).toEqual({
      kind: "transactional",
      message: {
        to: "halloweentest1@duindorpdoet.nl",
        subject: "Testbericht",
        text: "Tekst",
        html: "<p>Tekst</p>",
        outboxId: "outbox-1",
        replyTo: "halloween@duindorpdoet.nl",
        providerProbe: false,
      },
    });
  });

  it("does not report a rejected mail gateway response as accepted", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 502 })));

    await expect(sendSendGrid(message)).rejects.toMatchObject({
      status: 502,
      code: "MAIL_GATEWAY_502",
    });
  });

  it("marks runtime probes for provider sandbox validation without weakening the allowlist", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    await sendSendGrid({ ...message, sandbox: true });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));
    expect(body.message.providerProbe).toBe(true);
    expect(body.message.to).toBe("halloweentest1@duindorpdoet.nl");
  });
});
