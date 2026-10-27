import { describe, expect, it } from "vitest";
import { restoredMailScopes } from "./restore-mail-send.mjs";

describe("repairing Mail Send authorization", () => {
  it("adds only mail.send while preserving every existing permission and the input", () => {
    const original = ["api_keys.read", "api_keys.update", "messages.read"];
    expect(restoredMailScopes(original)).toEqual([...original, "mail.send"]);
    expect(original).toEqual(["api_keys.read", "api_keys.update", "messages.read"]);
  });
  it("preserves an already working key exactly", () => {
    expect(restoredMailScopes(["mail.send", "messages.read"])).toEqual(["mail.send", "messages.read"]);
  });
  it.each([undefined, [], ["mail.send", 1]])("refuses an unconfirmed permission set %s", scopes => {
    expect(() => restoredMailScopes(scopes)).toThrow("INVALID_EXISTING_SCOPES");
  });
});
