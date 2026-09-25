import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("PWA privacy and installation contract", () => {
  it("starts the standalone app in the authenticated environment with PNG icons", () => {
    const manifest = JSON.parse(readFileSync("public/manifest.webmanifest", "utf8")) as {
      id: string;
      start_url: string;
      display: string;
      icons: Array<{ src: string; purpose: string }>;
    };
    expect(manifest).toMatchObject({ id: "/omgeving", start_url: "/omgeving", display: "standalone" });
    expect(manifest.icons.some((icon) => icon.src.endsWith("maskable-512.png") && icon.purpose === "maskable")).toBe(true);
    expect(manifest.icons.every((icon) => icon.src.endsWith(".png"))).toBe(true);
  });

  it("never adds private documents, API or RSC responses to Cache Storage", () => {
    const worker = readFileSync("public/sw.js", "utf8");
    expect(worker).toContain('"/omgeving"');
    expect(worker).toContain('"/api/"');
    expect(worker).toContain('fetch(event.request, { cache: "no-store" })');
    expect(worker).not.toMatch(/cache\.put\([^\n]*(omgeving|api|document)/);
    expect(worker).toContain('self.addEventListener("push"');
    expect(worker).toContain('self.addEventListener("notificationclick"');
  });
});
