import { describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import {
  absoluteExpiry,
  codeDigest,
  decryptValue,
  encryptValue,
  generateChildCode,
  newSessionToken,
  safeDigestEqual,
  secretBytes,
  subjectDigest,
  tokenHash,
} from "./crypto";
import {
  CODE_ALPHABET,
  comingSoon,
  demoEnabled,
  normalizeCode,
  rankedChoices,
  validCode,
} from "./model";
import { demoSnapshot, newDemoSession } from "./demo";

const pepper = Buffer.alloc(32, 7).toString("base64");
const key = Buffer.alloc(32, 9).toString("base64");
describe("child credentials", () => {
  it("generates six unbiased safe characters and normalizes only at the boundary", () => {
    expect(CODE_ALPHABET).toHaveLength(32);
    for (let n = 0; n < 1000; n++)
      expect(validCode(generateChildCode())).toBe(true);
    expect(normalizeCode("  x7k9pq  ")).toBe("X7K9PQ");
    for (const value of ["ABCIO1", "ABCD0O", "ABC", "ABCDEFG", "AB CDE"])
      expect(validCode(value)).toBe(false);
    expect(validCode("DEMO26")).toBe(false);
  });
  it("uses domain-separated HMAC lookups and constant-time digest comparison", () => {
    const digest = codeDigest("ABC234", pepper);
    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(safeDigestEqual(digest, codeDigest(" abc234 ", pepper))).toBe(true);
    expect(safeDigestEqual(digest, codeDigest("ABC235", pepper))).toBe(false);
    expect(safeDigestEqual(digest, "bad")).toBe(false);
    expect(codeDigest("ABC234", key)).not.toBe(digest);
    expect(subjectDigest("ip", "same", pepper)).not.toBe(
      subjectDigest("device", "same", pepper),
    );
  });
  it("authenticated encryption is randomized and bound to its child and event", () => {
    const encrypted = encryptValue("ABC234", key, "event:child");
    expect(encrypted).not.toContain("ABC234");
    expect(encrypted).not.toBe(encryptValue("ABC234", key, "event:child"));
    expect(decryptValue(encrypted, key, "event:child")).toBe("ABC234");
    expect(() => decryptValue(encrypted, key, "event:other-child")).toThrow();
    expect(() => decryptValue(encrypted, pepper, "event:child")).toThrow();
    const parts = encrypted.split(".");
    parts[3] = Buffer.from("tampered").toString("base64url");
    expect(() => decryptValue(parts.join("."), key, "event:child")).toThrow();
    for (const invalid of [
      undefined,
      "plaintext",
      Buffer.alloc(16).toString("base64"),
    ])
      expect(() => secretBytes(invalid)).toThrow();
  });
  it("uses separate random 256-bit session tokens and exactly twelve absolute hours", () => {
    const token = newSessionToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newSessionToken()).not.toBe(token);
    expect(tokenHash(token)).toMatch(/^[a-f0-9]{64}$/);
    expect(tokenHash(token)).not.toContain(token);
    const issued = Date.parse("2026-10-24T22:00:00Z");
    expect(absoluteExpiry(issued) - issued).toBe(43_200_000); // includes DST change
  });
});
describe("staging demo and presentation", () => {
  it("requires both staging and the explicit flag, even if production is misconfigured", () => {
    expect(demoEnabled("staging", "true")).toBe(true);
    for (const environment of ["production", "development", "test", undefined])
      expect(demoEnabled(environment, "true")).toBe(false);
    for (const flag of [undefined, "false", "TRUE", "1"])
      expect(demoEnabled("staging", flag)).toBe(false);
  });
  it("keeps demo phases fictitious and expiry unchanged by actions", () => {
    const session = newDemoSession(1000);
    expect(
      demoSnapshot(session).companions.map((member) => member.firstName),
    ).toEqual(["Mila", "Sem", "Yara", "Finn", "Noor"]);
    for (const phase of [
      "empty",
      "three",
      "all",
      "finalists",
      "winner",
      "prepared",
    ] as const) {
      session.phase = phase;
      expect(demoSnapshot(session).expiresAt).toBe(
        new Date(43_201_000).toISOString(),
      );
      expect(demoSnapshot(session).demo).toBe(true);
    }
    expect(comingSoon).toHaveLength(3);
    expect(
      comingSoon.every((feature) => feature.status === "coming_soon"),
    ).toBe(true);
    expect(
      rankedChoices(["first", "second", "third"]).map(
        (choice) => choice.sparks,
      ),
    ).toEqual([3, 2, 1]);
  });
});
