import { describe, expect, it } from "vitest";
import { recipientAllowed } from "./policy";

describe("independent Auth and transactional recipient policies", () => {
  const allowed = new Set(["tester@example.invalid"]);
  it("allows a resident's OTP while restricting transactional staging mail", () => {
    expect(recipientAllowed("live", "resident@example.invalid", allowed)).toBe(true);
    expect(recipientAllowed("allowlist", "resident@example.invalid", allowed)).toBe(false);
    expect(recipientAllowed("allowlist", " Tester@Example.Invalid ", allowed)).toBe(true);
  });
  it("fails closed for disabled and unknown modes", () => {
    expect(recipientAllowed("disabled", "tester@example.invalid", allowed)).toBe(false);
    expect(recipientAllowed("typo", "tester@example.invalid", allowed)).toBe(false);
  });
});
