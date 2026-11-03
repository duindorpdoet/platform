import { describe, it, expect } from "vitest";
import { createEditionInvitation, verifyEditionInvitation } from "./edition-invitation";
const secret = "local-test-only-secret-for-edition-entry";
describe("beperkte testeditie-uitnodiging", () => {
  it("bindt een acht uur geldige link aan precies een testeditie", () => {
    const result = createEditionInvitation("frightnight-2027-test-januari", secret, 1000);
    expect(verifyEditionInvitation(result.token, secret, 2000)).toBe("frightnight-2027-test-januari");
    expect(verifyEditionInvitation(result.token, secret, 1000 + 8 * 3600_000)).toBeNull();
    expect(verifyEditionInvitation(result.token, secret, 0)).toBeNull();
  });
  it("weigert vervalsing, verkeerde sleutel, extra velden in de envelop en productie-edities", () => {
    const { token } = createEditionInvitation("frightnight-2027-test", secret, 1000);
    expect(verifyEditionInvitation(token + ".extra", secret, 1001)).toBeNull();
    expect(verifyEditionInvitation(token, secret + "x", 1001)).toBeNull();
    expect(verifyEditionInvitation(token.slice(0, -8) + "tampered", secret, 1001)).toBeNull();
    expect(() => createEditionInvitation("duindorp-halloween-2026", secret)).toThrow();
    expect(() => createEditionInvitation("frightnight-2027-test", "short")).toThrow();
  });
});
