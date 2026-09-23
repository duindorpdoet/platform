import { describe, expect, it, vi } from "vitest";
import { providerAccepted, sendTransactionalDelivery } from "./send";

describe("SendGrid Edge transport", () => {
  it("accepts 202 for real delivery and 200 for sandbox validation", () => {
    expect(providerAccepted(new Response(null, { status: 202 }), false)).toBe(true);
    expect(providerAccepted(new Response(null, { status: 200 }), true)).toBe(true);
    expect(providerAccepted(new Response(null, { status: 200 }), false)).toBe(false);
    expect(providerAccepted(new Response(null, { status: 202 }), true)).toBe(false);
  });

  it("preserves correlation and enables provider sandbox mode for runtime probes", async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response(null, { status: 200 }));

    await sendTransactionalDelivery({
      email: "test@example.nl",
      subject: "Probe",
      text: "Tekst",
      html: "<p>Tekst</p>",
      outboxId: "outbox-1",
      replyTo: "reply@example.nl",
      apiKey: "test-key",
      from: "halloween@duindorpdoet.nl",
      fromName: "Halloween",
      sandbox: true,
      fetcher,
    });

    const [, init] = fetcher.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));
    expect(body.personalizations[0].custom_args).toEqual({ outbox_id: "outbox-1" });
    expect(body.tracking_settings).toEqual({
      click_tracking: { enable: false, enable_text: false },
      open_tracking: { enable: false },
    });
    expect(body.reply_to).toEqual({ email: "reply@example.nl" });
    expect(body.mail_settings).toEqual({ sandbox_mode: { enable: true } });
  });
});
