import { describe, it, expect } from "vitest";
import { escapeHtml, printDocument, passDocument, passSvg, emergencyDocument } from "./downloads";
import type { FrightnightSnapshot } from "./model";
describe("veilige persoonlijke downloads", () => {
  it("escapet HTML in alle gebruikersvelden en noemt expliciet staging", () => {
    expect(escapeHtml('<script>"&')).toBe("&lt;script&gt;&quot;&amp;");
    const result = printDocument("<img src=x onerror=alert(1)>", "<p>Eigen gegevens</p>");
    expect(result).not.toContain("<title><img"); expect(result).toContain("STAGING / TEST");
  });
  it("maakt een zelfstandig SVG-aandenken zonder contactdata, bestemming of autorisatiegeheim", () => {
    const snapshot = { registration: { label: 'Ons <script>alert(1)</script> & gezin', routeType: "lantern", persons: 4, contactPhone: "+31612345678" }, progress: { sparks: 3, visits: [{ zoneId: "private-zone" }], awards: [{ key: "quest:game-1" }, { key: "visit:9d7ac7bb-54a5-4012-912c-17cef4f1cb3b" }] }, event: { serverTime: "2027-10-30T15:05:00Z" }, current: { zone: { address: "Privéadres" }, secret: "NEVER-IN-SOUVENIR" } } as unknown as FrightnightSnapshot;
    const svg = passSvg(snapshot, "data:image/png;base64,aGVsbG8=");
    expect(svg).toContain('<svg xmlns="http://www.w3.org/2000/svg"');
    expect(svg).toContain('href="data:image/png;base64,aGVsbG8="');
    expect(svg).toContain("Symbolenvolgorde");
    expect(svg).toContain("Bezoekzegel");
    const html = passDocument(snapshot, "/frightnight/logo.png");
    expect(html).toContain("Symbolenvolgorde");
    expect(html).toContain("Bezoekzegel");
    expect(html).not.toContain("9d7ac7bb-54a5-4012-912c-17cef4f1cb3b");
    expect(svg).not.toContain("9d7ac7bb-54a5-4012-912c-17cef4f1cb3b");
    expect(svg).toContain("&lt;script&gt;");
    for (const value of ["<script>", "+31612345678", "Privéadres", "private-zone", "NEVER-IN-SOUVENIR"]) expect(svg).not.toContain(value);
    expect(svg).toContain("Geen toegangsbewijs");
  });
  it("weigert externe of actieve image-URL's in de download en breekt lange gezelschapsnamen af", () => {
    const snapshot = { registration: { label: "W".repeat(100), routeType: "roots", persons: 1 }, progress: { sparks: 0, visits: [], awards: [] }, event: { serverTime: "2027-10-30T15:05:00Z" } } as unknown as FrightnightSnapshot;
    for (const image of ["https://example.invalid/track.png", 'javascript:alert(1)', 'data:image/svg+xml,<svg onload="alert(1)"/>']) {
      const svg = passSvg(snapshot, image);
      expect(svg).not.toContain("<image");
      expect(svg).toContain("Worteltocht");
      expect(svg).toContain('y="521"');
    }
  });
  it("voegt afdrukbare bevestigingskaartjes alleen toe voor bevoegde avondpost, zonder toekomstige adressen bij deelnemers", () => {
    const snapshot = { actor: { capabilities: [] }, event: { serverTime: "2027-10-30T15:05:00Z" }, current: null, zones: [{ name: "Goedgekeurde testzone", reviewStatus: "approved", address: "Eigen testadres", capacity: 8, type: "candy", opensAt: "17:00", closesAt: "18:30", status: "open" }, { name: "Nog niet beoordeeld", reviewStatus: "submitted", address: "Nooit in noodpakket" }] } as unknown as FrightnightSnapshot;
    expect(emergencyDocument(snapshot)).not.toContain("Eigen testadres");
    snapshot.actor.capabilities = ["portals_manage"];
    const printed = emergencyDocument(snapshot);
    expect(printed).toContain("Eigen testadres"); expect(printed).toContain("Bevestigd om: __________");
    expect(printed).toContain("geen toestemming om nu bezoekers te sturen"); expect(printed).not.toContain("Nooit in noodpakket");
  });
  it("houdt werkelijke downloadtijd apart van een stilstaande editieklok", () => {
    const snapshot = { actor: { capabilities: [] }, registration: null, event: { serverTime: "2027-10-30T15:05:00Z" }, progress: { visits: [], awards: [], sparks: 0 }, current: null } as unknown as FrightnightSnapshot;
    const realTime = "2026-11-03T03:30:00Z";
    for (const artifact of [passSvg(snapshot, "", realTime), emergencyDocument(snapshot, realTime)]) {
      expect(artifact).toContain(`${realTime} (werkelijke tijd)`);
      expect(artifact).toContain(`Editieklok: ${snapshot.event.serverTime}`);
    }
  });
});
