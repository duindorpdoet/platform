import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { shareFormats, type ShareFormat } from "./catalog";
import { renderShareCard } from "./render";

const templates = [
  ["participant", "participant/participant", "WIJ LOPEN MEE", "SAMEN DOOR DE NACHT"],
  ["gate-owner", "gate-owner/gate-owner", "WIJ ZIJN EEN POORT", "ACHTER ONZE DEUR"],
  ["join-us", "join-us/join-us", "LOOP JIJ MET ONS MEE?", "SAMEN DOOR DE NACHT"],
  ["recruit-gate", "recruit-gate/recruit-gate", "LAAT JOUW DEUR OOK ONTWAKEN", "WORD ONDERDEEL VAN HET VERHAAL"],
  ["recruit-helper", "recruit-helper/helper", "HELP JIJ MEE BIJ ONZE POORT?", "SAMEN MAKEN WE DE MAGIE"],
  ["team-reveal", "team-reveal/team-reveal", "ONS TEAM IS KLAAR VOOR DE NACHT", "ONS VAANDEL IS GEKOZEN"],
  ["world-reveal", "world-reveal/world-reveal", "ONZE WERELD ONTWAAKT", "ACHTER DE POORT"],
  ["countdown", "countdown/countdown", "NOG 33 NACHTEN", "HET AFTELLEN IS BEGONNEN"],
  ["participant-recap", "participant-recap/participant-recap", "WIJ LIEPEN MEE", "ONZE HERINNERING AAN DE NACHT"],
  ["gate-recap", "gate-recap/gate-recap", "ONZE POORT WAS GEOPEND", "DANK VOOR DEZE BIJZONDERE AVOND"],
  ["general-event", "general/general-event", "DE DUINDORPSE POORTEN VAN HALLOWEEN", "HALLOWEEN AVONDLOOP"],
] as const;

const allDynamic = {
  teamName: "De Nachtwachters van het Duin",
  portalName: "De Gloeiende Duinpoort",
  worldName: "Het Fluisterende Woud",
  worldColor: "violet",
  nightsRemaining: 33,
  visitedCount: 6,
  receivedGroups: 18,
  estimatedVisitors: 142,
  banner: { color: "violet", secondaryColor: "cyan", symbol: "star" },
};

async function render(format: ShareFormat, template: (typeof templates)[number] = templates[10]) {
  const [key, asset, title, eyebrow] = template;
  const dynamic = key === "team-reveal" ? { teamName: allDynamic.teamName, worldColor: "violet", banner: allDynamic.banner }
    : key === "world-reveal" ? { portalName: allDynamic.portalName, worldName: allDynamic.worldName, worldColor: "violet" }
    : key === "countdown" ? { nightsRemaining: 33 }
    : key === "participant-recap" ? { teamName: allDynamic.teamName, visitedCount: 6, banner: allDynamic.banner }
    : key === "gate-recap" ? { portalName: allDynamic.portalName, worldName: allDynamic.worldName, receivedGroups: 18, estimatedVisitors: 142 }
    : key === "gate-owner" ? { portalName: allDynamic.portalName }
    : {};
  return renderShareCard({
    format,
    style: key === "world-reveal" ? "world" : "event",
    portraitAsset: `/images/social-share/${asset}-portrait.webp`,
    landscapeAsset: `/images/social-share/${asset}-landscape.webp`,
    textConfig: { title, eyebrow, subtitle: key === "join-us" ? "VRAAG ONZE SAMENLOOPCODE!" : undefined, date: key.includes("recap") ? "2026" : "31 OKTOBER 2026" },
    dynamic,
    publicUrl: "https://duindorpdoet.nl/delen/0123456789abcdef0123456789abcdef",
    allowedOrigin: "https://duindorpdoet.nl",
    includeQr: true,
  });
}

describe("Deelstudio renderer", () => {
  beforeAll(async () => {
    const output = process.env.SHARE_PROOFS_DIR;
    if (!output) return;
    await mkdir(output, { recursive: true });
    for (const template of templates) await writeFile(path.join(output, `${template[0]}-story.png`), await render("story", template));
    for (const format of Object.keys(shareFormats) as ShareFormat[]) await writeFile(path.join(output, `general-event-${format}.png`), await render(format));
  }, 60_000);

  for (const format of Object.keys(shareFormats) as ShareFormat[]) {
    it(`renders a valid ${format} PNG at the exact dimensions`, async () => {
      const bytes = await render(format);
      const metadata = await sharp(bytes).metadata();
      expect(metadata.format).toBe("png");
      expect(metadata.width).toBe(shareFormats[format].width);
      expect(metadata.height).toBe(shareFormats[format].height);
      expect(bytes.byteLength).toBeGreaterThan(50_000);
    }, 20_000);
  }

  it("refuses unsafe internal payload keys", async () => {
    await expect(renderShareCard({
      format: "square", style: "event", portraitAsset: "/images/social-share/general/general-event-portrait.webp",
      landscapeAsset: "/images/social-share/general/general-event-landscape.webp", textConfig: { title: "VEILIGE KAART" },
      dynamic: { childName: "Niet delen" } as never, publicUrl: "https://duindorpdoet.nl/",
      allowedOrigin: "https://duindorpdoet.nl",
    })).rejects.toThrow("UNSAFE_SHARE_PAYLOAD");
  });

  it("refuses external or traversing sources", async () => {
    await expect(renderShareCard({ format: "square", style: "event", portraitAsset: "/images/social-share/../../secret.webp", landscapeAsset: "/images/social-share/general/general-event-landscape.webp", textConfig: {}, dynamic: {}, publicUrl: "https://duindorpdoet.nl/", allowedOrigin: "https://duindorpdoet.nl" })).rejects.toThrow("UNSAFE_TEMPLATE_ASSET");
    await expect(renderShareCard({ format: "square", style: "event", portraitAsset: "/images/social-share/general/general-event-portrait.webp", landscapeAsset: "/images/social-share/general/general-event-landscape.webp", textConfig: {}, dynamic: {}, publicUrl: "https://evil.example/", allowedOrigin: "https://duindorpdoet.nl" })).rejects.toThrow("UNSAFE_PUBLIC_URL");
  });
});
