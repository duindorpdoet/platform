import { z } from "zod";
import { apiFailure, apiSuccess, ApiError, correlationId } from "@/lib/http/api";
import { frightnightSnapshot } from "@/lib/frightnight/server";
import { findAddress } from "@/lib/frightnight/geocoding";
const recent = new Map<string, number>();
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    const id = z.uuid().parse(new URL(request.url).searchParams.get("zoneId"));
    const zone = [...snapshot.ownZones, ...(snapshot.zones ?? [])].find(x => x.id === id);
    if (!zone?.address) throw new ApiError(403, "ZONE_FORBIDDEN", "Je kunt alleen het adres van je eigen zone controleren.");
    const previous = recent.get(snapshot.actor.id) ?? 0;
    if (Date.now() - previous < 1500) throw new ApiError(429, "ADDRESS_RETRY_LATER", "Wacht even voordat je het adres opnieuw controleert.");
    if (recent.size >= 256) recent.delete(recent.keys().next().value!);
    recent.set(snapshot.actor.id, Date.now());
    try {
      const candidates = await findAddress(zone.address);
      return apiSuccess({ candidates, source: "PDOK Locatieserver / BAG", message: candidates.length ? "Kies het juiste adres en bevestig de ligging. De organisatie beoordeelt daarna ingang en veilige wandelverbinding." : "Geen passend Duindorps adres gevonden. Stem adres en ingang af met de organisatie; er wordt geen pin verzonnen." });
    } catch { return apiSuccess({ candidates: [], source: "PDOK Locatieserver / BAG", message: "De adresdienst is tijdelijk niet bereikbaar. Je aanmelding blijft bewaard; stem de ingang af met de organisatie." }); }
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
