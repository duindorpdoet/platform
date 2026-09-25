import { describe, expect, it } from "vitest";
import {
  countPortalRegistrationProgress,
  formatPortalAddress,
  portalRegistrationStatusLabels,
} from "@/lib/domain/admin-portals";

describe("admin portal list helpers", () => {
  it("uses the operationally unambiguous Dutch status labels", () => {
    expect(portalRegistrationStatusLabels.awaiting_otp).toBe("Aangemeld — wacht op OTP");
    expect(portalRegistrationStatusLabels.activated_incomplete).toBe("Omgeving geactiveerd — gegevens nog aanvullen");
    expect(portalRegistrationStatusLabels.approved).toBe("Goedgekeurd");
  });

  it("counts the four intake stages without treating an activated account as complete", () => {
    expect(countPortalRegistrationProgress({ contact: true, address: true, experience: false, planning: false })).toEqual({
      completed: 2,
      total: 4,
      percentage: 50,
    });
  });

  it("formats partial and complete private addresses without invented street data", () => {
    expect(formatPortalAddress({ street: "Markensestraat", houseNumber: "52", postalCode: "2583PS" })).toBe(
      "Markensestraat 52, 2583PS Den Haag",
    );
    expect(formatPortalAddress({})).toBe("Niet ingevuld");
  });
});

