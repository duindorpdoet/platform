import { describe, expect, it } from "vitest";

import { paymentRegistrationStage } from "./payment-registration-stage";

describe("paymentRegistrationStage", () => {
  it("keeps a partly linked registration in the list that still needs a link", () => {
    expect(paymentRegistrationStage([
      { status: "awaiting_payment" },
      { status: "awaiting_link" },
    ])).toBe("needs_link");
  });

  it("groups sent, reported and review states under an existing payment link", () => {
    for (const status of ["awaiting_payment", "reported", "needs_review"]) {
      expect(paymentRegistrationStage([{ status }])).toBe("link_sent");
    }
  });

  it("only marks a registration paid when every active child is settled", () => {
    expect(paymentRegistrationStage([
      { status: "confirmed" },
      { status: "waived" },
      { status: "cancelled" },
    ])).toBe("paid");
    expect(paymentRegistrationStage([{ status: "cancelled" }])).toBeNull();
  });
});
