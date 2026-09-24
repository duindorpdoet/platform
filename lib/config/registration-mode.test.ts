import { describe, expect, it } from "vitest";
import { registrationChannelIsOpen } from "@/lib/config/registration-mode";

describe("registrationChannelIsOpen", () => {
  it("keeps every channel closed when the deployed release mode is closed", () => {
    expect(registrationChannelIsOpen("closed", true)).toBe(false);
    expect(registrationChannelIsOpen("closed", false)).toBe(false);
    expect(registrationChannelIsOpen("closed")).toBe(false);
  });

  it("honours the organizer channel setting outside the closed release mode", () => {
    expect(registrationChannelIsOpen("staging_test", true)).toBe(true);
    expect(registrationChannelIsOpen("staging_test", false)).toBe(false);
    expect(registrationChannelIsOpen("live", true)).toBe(true);
  });

  it("defaults an unconfigured non-production channel to open", () => {
    expect(registrationChannelIsOpen("staging_test")).toBe(true);
  });
});
