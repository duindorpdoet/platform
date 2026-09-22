import { describe, expect, it } from "vitest";
import { transactionalMessageForPayload } from "./transactional";

describe("transactional mail hook payload", () => {
  it("accepts the bounded signed transactional envelope", () => {
    expect(transactionalMessageForPayload({
      kind: "transactional",
      message: {
        to: " Test@Example.nl ",
        subject: "Je bericht is ontvangen",
        text: "Tekst",
        html: "<p>Tekst</p>",
        outboxId: "outbox-1",
        replyTo: "reply@example.nl",
        providerProbe: false,
      },
    })).toEqual({
      to: "test@example.nl",
      subject: "Je bericht is ontvangen",
      text: "Tekst",
      html: "<p>Tekst</p>",
      outboxId: "outbox-1",
      replyTo: "reply@example.nl",
      providerProbe: false,
    });
  });

  it("rejects malformed recipients and oversized or incomplete messages", () => {
    expect(transactionalMessageForPayload({
      kind: "transactional",
      message: { to: "not-an-email", subject: "x", text: "x", html: "x" },
    })).toBeNull();
    expect(transactionalMessageForPayload({
      kind: "transactional",
      message: { to: "test@example.nl", subject: "", text: "x", html: "x" },
    })).toBeNull();
  });
});
