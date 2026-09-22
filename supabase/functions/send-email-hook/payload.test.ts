import { describe, expect, it, vi } from "vitest";
import { deliveriesForPayload } from "./payload";
import { sendHookDeliveries } from "./send";

describe("Auth email hook payload contract", () => {
  it("rejects an unknown action instead of sending a login-like mail", () => {
    expect(deliveriesForPayload({
      user: { email: "victim@example.invalid" },
      email_data: { email_action_type: "attacker_defined", token: "123456" },
    })).toEqual({ deliveries: [], supported: false });
  });

  it("maps a standard OTP action only to the verified hook user address", () => {
    expect(deliveriesForPayload({
      user: { email: "parent@example.invalid", new_email: "ignored@example.invalid" },
      email_data: { email_action_type: "email", token: "123456" },
    })).toEqual({ deliveries: [{ email: "parent@example.invalid", token: "123456" }], supported: true });
  });

  it("maps secure dual email change tokens to their intended addresses", () => {
    expect(deliveriesForPayload({
      user: { email: "old@example.invalid", new_email: "new@example.invalid" },
      email_data: {
        email_action_type: "email_change",
        token: "old-token",
        token_new: "new-token",
        token_hash: "old-hash",
        token_hash_new: "new-hash",
      },
    })).toEqual({
      deliveries: [
        { email: "old@example.invalid", token: "old-token" },
        { email: "new@example.invalid", token: "new-token" },
      ],
      supported: true,
    });
  });

  it("treats missing delivery fields as a controlled invalid payload", () => {
    expect(deliveriesForPayload({ user: {}, email_data: { email_action_type: "recovery" } })).toEqual({
      deliveries: [],
      supported: true,
    });
  });

  it("bounds a stalled SendGrid request instead of reporting false Auth-hook success", async () => {
    const stalledFetch = vi.fn((_url: string | URL | Request, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
    }));

    await expect(sendHookDeliveries({
      deliveries: [{ email: "halloweentest1@duindorpdoet.nl", token: "123456" }],
      apiKey: "test-only",
      from: "halloween@duindorpdoet.nl",
      fromName: "Halloween test",
      subject: "Test",
      providerProbe: false,
      sandbox: false,
      timeoutMs: 10,
      fetcher: stalledFetch,
    })).rejects.toBeTruthy();
    expect(stalledFetch).toHaveBeenCalledOnce();
  });
});
