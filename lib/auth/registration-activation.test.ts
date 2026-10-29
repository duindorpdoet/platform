import { expect, it } from "vitest";
import { safeReturnPath } from "./redirect";
import { registrationActivationMessage, registrationActivationReturnPath } from "./registration-activation";

it("uses the same safe invitation return path for OTP and Google without supplying account identity", () => {
  const path = registrationActivationReturnPath("a".repeat(64));
  expect(safeReturnPath(path)).toBe(path);
  expect(path).toBe(`/uitnodiging/inschrijving/${"a".repeat(64)}?verified=1`);
  expect(() => registrationActivationReturnPath("//external.invalid")).toThrow("INVALID_INVITATION");
});

it("explains expiry, explicit old-session confirmation and duplicate registrations without exposing backend errors", () => {
  expect(registrationActivationMessage("INVITATION_EXPIRED")).toContain("blijven bewaard");
  expect(registrationActivationMessage("FRESH_LOGIN_OR_EXPLICIT_CLAIM_REQUIRED")).toContain("zelf");
  expect(registrationActivationMessage("REGISTRATION_ALREADY_EXISTS")).toContain("organisatie");
  expect(registrationActivationMessage("private SQL and identity details")).not.toContain("private SQL");
});
