import { describe, expect, it } from "vitest";
import { contentForMessage } from "./mail-catalog";
import { renderPremiumEmail, type PremiumMailBrand } from "./premium-template";

const brand: PremiumMailBrand = {
  name: "De Duindorpse Poorten van Halloween", supportEmail: "halloween@example.invalid",
  homeUrl: "https://halloween.example.invalid/", contactUrl: "https://halloween.example.invalid/contact",
  privacyUrl: "https://halloween.example.invalid/privacy", logoUrl: "https://halloween.example.invalid/logo.webp",
  heroUrl: "https://halloween.example.invalid/hero.webp", allowedLinkHosts: ["halloween.example.invalid"], allowedImageHosts: ["halloween.example.invalid"],
};

describe("Duinpad closing mail", () => {
  it("uses the premium gateway template with an authenticated own-environment destination", () => {
    const content = contentForMessage("duinpad_evening_thanks", {}, brand);
    const rendered = renderPremiumEmail(content, brand);
    expect(content.primaryAction?.url).toBe("https://halloween.example.invalid/omgeving/meeloper");
    expect(rendered.text).toContain("volgend jaar samen nóg grootser");
    expect(rendered.text).toContain("echt hebben bereikt");
    expect(rendered.text).not.toMatch(/token=|claim=|bezorgd|show is afgelopen/);
  });
});
