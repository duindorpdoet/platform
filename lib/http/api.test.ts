import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({
  allowedOrigins: () => new Set(["https://halloween.duindorpdoet.nl", "https://staging-halloween.duindorpdoet.nl"]),
}));

import { assertTrustedOrigin } from "./api";

function request(origin?: string) {
  return new Request("https://halloween.duindorpdoet.nl/api/public/contact", {
    method: "POST",
    headers: origin === undefined ? {} : { origin },
  });
}

describe("trusted mutation origins", () => {
  it("accepts the exact configured production origin", () => {
    expect(() => assertTrustedOrigin(request("https://halloween.duindorpdoet.nl"))).not.toThrow();
  });

  it("rejects a cross-origin request even when the hostname is a lookalike", () => {
    expect(() => assertTrustedOrigin(request("https://halloween.duindorpdoet.nl.attacker.invalid"))).toThrowError(
      expect.objectContaining({ status: 403, code: "ORIGIN_NOT_ALLOWED" }),
    );
  });

  it("rejects a request without an Origin header", () => {
    expect(() => assertTrustedOrigin(request())).toThrowError(
      expect.objectContaining({ status: 403, code: "ORIGIN_NOT_ALLOWED" }),
    );
  });

  it("maps a malformed Origin to the same controlled denial", () => {
    expect(() => assertTrustedOrigin(request("not a url"))).toThrowError(
      expect.objectContaining({ status: 403, code: "ORIGIN_NOT_ALLOWED" }),
    );
  });
});
