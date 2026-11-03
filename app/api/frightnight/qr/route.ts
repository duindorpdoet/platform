import { createHash } from "node:crypto";
import QRCode from "qrcode";
import { z } from "zod";
import { apiFailure, correlationId } from "@/lib/http/api";
import { frightnightActor, frightnightCommand, frightnightSnapshot } from "@/lib/frightnight/server";
import { escapeHtml, printDocument } from "@/lib/frightnight/downloads";
import type { FrightnightCommandResult } from "@/lib/frightnight/model";
export async function GET(request: Request) {
  try {
    const actor = await frightnightActor();
    const url = new URL(request.url);
    const zoneId = url.searchParams.get("zoneId");
    if (zoneId) z.uuid().parse(zoneId);
    const snapshot = await frightnightSnapshot();
    const selectedZone = snapshot.ownZones.find(x => x.id === zoneId) ?? snapshot.zones?.find(x => x.id === zoneId);
    // Stable export receipt: a download never silently rotates a printed credential.
    const raw = createHash("sha256").update(`${snapshot.event.slug}:${snapshot.event.runId}:${snapshot.event.seedVersion}:qr-export:${actor.userId}:${snapshot.registration?.id ?? "none"}:${zoneId ?? "start"}:${selectedZone?.version ?? 0}`).digest("hex").slice(0, 32);
    const commandId = `${raw.slice(0, 8)}-${raw.slice(8, 12)}-4${raw.slice(13, 16)}-8${raw.slice(17, 20)}-${raw.slice(20)}`;
    const response = await frightnightCommand("qr.issue", zoneId ? { zoneId } : {}, commandId) as FrightnightCommandResult;
    const code = z.string().min(16).parse(response.result.code ?? response.result.token);
    const svg = await QRCode.toString(code, { type: "svg", errorCorrectionLevel: "M", margin: 4, width: 512 });
    if (url.searchParams.get("format") === "svg") return new Response(svg, { headers: { "Content-Type": "image/svg+xml", "Cache-Control": "private, no-store" } });
    const zone = response.snapshot.ownZones.find(x => x.id === zoneId) ?? response.snapshot.zones?.find(x => x.id === zoneId);
    return new Response(printDocument("Zonebord — FrightNight 2027", `<h1>${escapeHtml(zone?.name ?? "Start op het Duinpad")}</h1><p>${zone ? escapeHtml(zone.type === "candy" ? "Snoepzone · zonder schrikniveau" : `${zone.intensity} van 5 pompoenen`) : "Scan om jullie gekozen tocht te starten"}</p>${svg}<p>Geen camera? Vul deze code handmatig in je Nachtpas in:</p><p style="overflow-wrap:anywhere"><code>${escapeHtml(code)}</code></p>${zone ? `<p>Opening: ${escapeHtml(zone.opensAt)} – ${escapeHtml(zone.closesAt)}</p>` : ""}<p>Deze QR geldt alleen voor deze testeditie en bevat geen beheertoegang. Druk dit document af via de afdrukfunctie van je browser.</p>`), { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "private, no-store" } });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
