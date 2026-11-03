import { z } from "zod";
import { apiFailure, apiSuccess, ApiError, correlationId } from "@/lib/http/api";
import { frightnightSnapshot, rpcError } from "@/lib/frightnight/server";
import { createClient } from "@/lib/supabase/server";
import { walkingRoute } from "@/lib/frightnight/walking";
export async function GET(request: Request) {
  try {
    const snapshot = await frightnightSnapshot();
    if (!snapshot.actor.capabilities.includes("event_admin")) throw new ApiError(403, "EVENT_ADMIN_REQUIRED", "Alleen de organisator kan een wandelverbinding beoordelen.");
    const query = new URL(request.url).searchParams;
    const ids = z.object({ from: z.uuid(), to: z.uuid() }).refine(v => v.from !== v.to).parse({ from: query.get("fromZoneId"), to: query.get("toZoneId") });
    const client = await createClient();
    // Paginated reads use the actor's existing event-scoped database policy.
    // A foreign zone UUID never becomes an arbitrary provider coordinate.
    let found: { id: string; latitude?: number; longitude?: number }[] = [];
    for (let cursor = 0; cursor < 1000 && found.length < 2; cursor += 100) {
      const { data, error } = await client!.schema("api").rpc("frightnight_admin_list", { p_slug: snapshot.event.slug, p_resource: "zones", p_cursor: cursor, p_limit: 100 });
      if (error) rpcError(error);
      const page = data as { items: { id: string; latitude?: number; longitude?: number }[]; total: number };
      found = [...found, ...page.items.filter(zone => zone.id === ids.from || zone.id === ids.to)];
      if (cursor + page.items.length >= page.total) break;
    }
    const from = found.find(zone => zone.id === ids.from), to = found.find(zone => zone.id === ids.to);
    if (!from || !to || from.latitude == null || from.longitude == null || to.latitude == null || to.longitude == null) throw new ApiError(422, "LOCATION_REQUIRED", "Bevestig eerst de ligging van beide zones binnen deze editie.");
    try { return apiSuccess(await walkingRoute({ latitude: from.latitude, longitude: from.longitude }, { latitude: to.latitude, longitude: to.longitude })); }
    catch { return apiSuccess({ available: false, reason: "De wandelprovider is tijdelijk niet beschikbaar. Beoordeel en meet de verbinding ter plaatse voordat je haar vastlegt; er wordt geen lijn verzonnen." }); }
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
