import { beforeEach, describe, expect, it, vi } from "vitest";
import sharp from "sharp";
import { Webhook } from "standardwebhooks";
vi.mock("server-only", () => ({}));
const state = vi.hoisted(() => ({
  env: {
    APP_ENVIRONMENT: "staging",
    MAIL_MODE: "live",
    NEWSLETTER_SENDING_ENABLED: "true",
    WEB_PUSH_SENDING_ENABLED: "true",
    NEXT_PUBLIC_SUPABASE_URL: "https://fixture.supabase.co",
    NEXT_PUBLIC_VAPID_PUBLIC_KEY: "public",
    VAPID_PRIVATE_KEY: "private",
    VAPID_SUBJECT: "mailto:test@example.invalid",
    SEND_EMAIL_HOOK_SECRET: `v1,whsec_${"AQ=="}`,
    SENDGRID_REPLY_TO: "reply@example.invalid",
    EDITORIAL_ALLOWED_RECIPIENTS: "test@example.invalid",
  },
  rpc: vi.fn(),
  send: vi.fn(),
}));
vi.mock("@/lib/config/server-env", () => ({
  serverEnv: () => state.env,
  mailAllowlist: () => new Set(["test@example.invalid"]),
}));
vi.mock("@/lib/supabase/privileged", () => ({
  createPrivilegedClient: () => ({ schema: () => ({ rpc: state.rpc }) }),
}));
vi.mock("web-push", () => ({
  default: { setVapidDetails: vi.fn(), sendNotification: state.send },
}));
import { editorialTick } from "./worker";
import { editorialImageVariants } from "./media";
import { sendSendGrid } from "../mail/sendgrid";
import { sendTransactionalDelivery } from "../../supabase/functions/send-email-hook/send";
const id = "a0000000-0000-0000-0000-000000000001";
const job = {
  id,
  claimToken: id,
  versionId: id,
  url: "/omgeving/nieuws/de-nacht",
  targets: [
    {
      subscriptionId: id,
      endpoint: "https://push.example.invalid/one",
      p256dh: "secret-key",
      auth: "secret-auth",
    },
    {
      subscriptionId: "a0000000-0000-0000-0000-000000000002",
      endpoint: "https://push.example.invalid/two",
      p256dh: "key-two",
      auth: "auth-two",
    },
  ],
};
beforeEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  Object.assign(state.env, {
    APP_ENVIRONMENT: "staging",
    MAIL_MODE: "live",
    NEWSLETTER_SENDING_ENABLED: "true",
    WEB_PUSH_SENDING_ENABLED: "true",
    SEND_EMAIL_HOOK_SECRET: `v1,whsec_${Buffer.alloc(32, 1).toString("base64")}`,
  });
  state.rpc.mockImplementation(async (name: string) => ({
    data: name === "worker_claim_editorial_push" ? [job] : {},
    error: null,
  }));
  state.send.mockResolvedValue({ statusCode: 201 });
});
describe("editorial Web Push adapter", () => {
  it("passes an explicit staging allowlist and only safe lockscreen data per device", async () => {
    await editorialTick();
    expect(state.rpc).toHaveBeenCalledWith("worker_claim_editorial_push", {
      _allowed_emails: ["test@example.invalid"],
    });
    expect(state.send).toHaveBeenCalledTimes(2);
    const payload = JSON.parse(state.send.mock.calls[0][1]);
    expect(payload).toEqual({
      title: "De Duindorpse Poorten",
      body: "Er staat een nieuw bericht voor je klaar.",
      url: `/omgeving/nieuws/de-nacht?push=${id}&device=${id}`,
      tag: `news-${id}`,
    });
    expect(state.rpc).toHaveBeenCalledWith(
      "worker_record_editorial_push",
      expect.objectContaining({ _status: "sent_to_pushservice" }),
    );
  });
  it.each([404, 410])(
    "deactivates an expired endpoint on HTTP %s while continuing other devices",
    async (statusCode) => {
      state.send.mockRejectedValueOnce({ statusCode });
      await editorialTick();
      expect(state.rpc).toHaveBeenCalledWith(
        "worker_record_editorial_push",
        expect.objectContaining({
          _subscription: id,
          _status: "invalid",
          _error: `HTTP_${statusCode}`,
        }),
      );
      expect(state.send).toHaveBeenCalledTimes(2);
      expect(state.rpc).toHaveBeenCalledWith("worker_finish_editorial_push", {
        _id: id,
        _token: id,
      });
    },
  );
  it("records a transient error separately from successful devices", async () => {
    state.send.mockRejectedValueOnce({ statusCode: 503 });
    await editorialTick();
    expect(state.rpc).toHaveBeenCalledWith(
      "worker_record_editorial_push",
      expect.objectContaining({ _status: "failed", _error: "HTTP_503" }),
    );
    expect(state.rpc).toHaveBeenCalledWith(
      "worker_record_editorial_push",
      expect.objectContaining({ _status: "sent_to_pushservice" }),
    );
  });
  it("kill switch prevents claiming/sending while publication still advances", async () => {
    state.env.WEB_PUSH_SENDING_ENABLED = "false";
    await editorialTick();
    expect(state.send).not.toHaveBeenCalled();
    expect(state.rpc).toHaveBeenCalledTimes(1);
    expect(state.rpc).toHaveBeenCalledWith("worker_editorial_tick", {
      _mail_enabled: true,
    });
  });
  it("does not acknowledge completion when database receipt fails", async () => {
    state.rpc.mockImplementation(async (name: string) => ({
      data: name === "worker_claim_editorial_push" ? [job] : {},
      error: name === "worker_record_editorial_push" ? {} : null,
    }));
    await expect(editorialTick()).rejects.toThrow("EDITORIAL_PUSH_ACK_FAILED");
    expect(state.rpc).not.toHaveBeenCalledWith(
      "worker_finish_editorial_push",
      expect.anything(),
    );
  });
});
describe("signed Nachtpost transport", () => {
  const message = {
    to: "test@example.invalid",
    subject: "Nachtpost",
    html: "<p>Veilig nieuws</p>",
    text: "Veilig nieuws",
    editorial: true,
    senderName: "De Nachtpost",
    outboxId: id,
    unsubscribeUrl:
      "https://staging.example.invalid/api/editorial/unsubscribe?token=opaque",
  };
  it("retains signing/correlation and emits one-click headers through the real provider adapter", async () => {
    const provider = vi
      .fn()
      .mockResolvedValue(new Response(null, { status: 202 }));
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init: RequestInit) => {
        const headers = init.headers as Record<string, string>;
        const body = new Webhook(Buffer.alloc(32, 1).toString("base64")).verify(
          String(init.body),
          headers,
        ) as { message: typeof message & { replyTo: string } };
        expect(body.message.editorial).toBe(true);
        await sendTransactionalDelivery({
          ...body.message,
          email: body.message.to,
          from: "news@example.invalid",
          fromName: body.message.senderName,
          apiKey: "fixture",
          sandbox: false,
          fetcher: provider,
        });
        return new Response(null, {
          status: 200,
          headers: { "x-provider-message-id": "fixture-accepted" },
        });
      }),
    );
    expect(await sendSendGrid(message)).toEqual({
      accepted: true,
      providerId: "fixture-accepted",
    });
    const sent = JSON.parse(String(provider.mock.calls[0][1].body));
    expect(sent.headers).toEqual({
      "List-Unsubscribe": `<${message.unsubscribeUrl}>`,
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
    });
    expect(sent.personalizations).toEqual([
      { to: [{ email: message.to }], custom_args: { outbox_id: id } },
    ]);
    expect(sent.tracking_settings.open_tracking.enable).toBe(false);
  });
  it("staging cannot send editorial mail outside its allowlist even if MAIL_MODE is live", async () => {
    const fetcher = vi.fn();
    vi.stubGlobal("fetch", fetcher);
    await expect(
      sendSendGrid({ ...message, to: "participant@example.invalid" }),
    ).rejects.toMatchObject({ code: "EDITORIAL_RECIPIENT_NOT_ALLOWED" });
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("newsletter kill switch leaves transactional messages permitted", async () => {
    state.env.NEWSLETTER_SENDING_ENABLED = "false";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(null, { status: 200 })),
    );
    await expect(sendSendGrid(message)).rejects.toMatchObject({
      code: "EDITORIAL_RECIPIENT_NOT_ALLOWED",
    });
    await expect(
      sendSendGrid({ ...message, editorial: false }),
    ).resolves.toMatchObject({ accepted: true });
  });
});
describe("private media processing", () => {
  it("generates webp variants with bounded dimensions and removes metadata", async () => {
    const source = await sharp({
      create: { width: 1600, height: 1000, channels: 3, background: "#152c36" },
    })
      .jpeg()
      .withMetadata()
      .toBuffer();
    const result = await editorialImageVariants(source, "image/jpeg", 100, 0);
    expect(result.variants.map((v) => v.name)).toEqual([
      "source",
      "hero",
      "card",
      "portal",
      "email",
      "og",
    ]);
    for (const variant of result.variants) {
      const m = await sharp(variant.bytes).metadata();
      expect(m.format).toBe("webp");
      expect(m.exif).toBeUndefined();
      expect(m.width).toBeLessThanOrEqual(4000);
    }
  });
  it("rejects MIME spoofing and undersized source images", async () => {
    const png = await sharp({
      create: { width: 320, height: 180, channels: 3, background: "black" },
    })
      .png()
      .toBuffer();
    await expect(
      editorialImageVariants(png, "image/jpeg"),
    ).rejects.toMatchObject({ code: "INVALID_IMAGE" });
    await expect(
      editorialImageVariants(
        await sharp(png).resize(100).png().toBuffer(),
        "image/png",
      ),
    ).rejects.toMatchObject({ code: "INVALID_IMAGE" });
  });
});
