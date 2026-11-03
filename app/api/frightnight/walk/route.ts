import { z } from "zod";
import { apiSuccess, apiFailure, correlationId, ApiError } from "@/lib/http/api";
import { frightnightSnapshot, rpcError } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
import { walkingRoute, type WalkingPoint } from "@/lib/frightnight/walking";
export async function GET(request: Request) {
  try {
    const destinationId = z.uuid().parse(new URL(request.url).searchParams.get("destinationId"));
    const snapshot = await frightnightSnapshot();
    if (snapshot.current?.id !== destinationId) throw new ApiError(409, "DESTINATION_CHANGED", "Open de actuele bestemming voor een wandelroute.");
    const client = await createClient();
    const { data, error } = await client!.schema("api").rpc("frightnight_walk", { p_slug: snapshot.event.slug, p_destination_id: destinationId });
    if (error) rpcError(error);
    const path = data as { from?: WalkingPoint; to?: WalkingPoint; geometry?: unknown; minutes?: number; source?: string };
    if (path.source === "synthetic-fixture") return apiSuccess({ available: false, source: "Synthetische testgraaf", reason: "Deze testroute gebruikt synthetische looptijden om de serverregels te testen. Er is geen gecontroleerd straatpad. Gebruik dit scenario alleen voor server- en schermproeven, niet als echte wandelinstructie." });
    if (path?.geometry) return apiSuccess({ available: true, geometry: path.geometry, minutes: path.minutes, source: "Door de organisatie gecontroleerde wandelverbinding" });
    if (!path?.from || !path.to) return apiSuccess({ available: false, reason: "Er is nog geen gecontroleerde ingang of wandelverbinding. Gebruik het vrijgegeven adres en de aanwijzingen van de organisatie." });
    try { return apiSuccess(await walkingRoute(path.from, path.to)); }
    catch { return apiSuccess({ available: false, reason: "De wandelkaart is tijdelijk niet beschikbaar. Het vrijgegeven adres blijft geldig; volg veilige openbare paden of vraag hulp op het Duinpad." }); }
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
