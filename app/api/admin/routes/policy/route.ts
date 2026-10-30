import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId, requireIdempotencyKey } from "@/lib/http/api";
import { boundedBody } from "@/lib/http/bounded-body";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const eventSlug = z.string().min(1).max(100).regex(/^[a-z0-9-]+$/);
// PostgreSQL also accepts existing UUIDs without RFC version/variant bits.
// The locked database command checks actual event ownership and suitability.
const portalId = z.string().regex(/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
const bodySchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("get"), eventSlug }).strict(),
  z.object({
    action: z.literal("save"), eventSlug, expectedVersion: z.number().int().positive(),
    maxTotalWalkingSeconds: z.number().int().min(1).max(86_400),
    maxEarlyFinishSeconds: z.number().int().min(0).max(86_400),
    organizerCoveragePortalIds: z.array(portalId).max(64).refine(ids => new Set(ids).size === ids.length),
    reason: z.string().trim().min(10).max(500),
  }).strict(),
]);

/** Only the authorized database command saves policy; it never changes appointments or routes. */
export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const body = bodySchema.parse(JSON.parse(await boundedBody(request, 8_192)));
    const key = body.action === "save" ? requireIdempotencyKey(request) : null;
    const client = await createClient();
    const identity = await client?.auth.getUser();
    if (!client || !identity?.data.user || identity.error) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in als bevoegde organisator.");
    const result = body.action === "get"
      ? await client.schema("api").rpc("admin_joint_route_policy_get", { _event_slug: body.eventSlug })
      : await client.schema("api").rpc("admin_joint_route_policy_save", {
        _event_slug: body.eventSlug, _expected_version: body.expectedVersion,
        _max_total_walking_seconds: body.maxTotalWalkingSeconds, _max_early_finish_seconds: body.maxEarlyFinishSeconds,
        _organizer_coverage_portal_ids: body.organizerCoveragePortalIds, _reason: body.reason, _idempotency_key: key,
      });
    if (result.error) {
      if (result.error.code === "42501") throw new ApiError(403, "NOT_AUTHORIZED", "Groepsbeheer is nodig om het routebeleid te bekijken of te wijzigen.");
      if (/STALE|VERSION|SOURCE_CHANGED/.test(result.error.message ?? "")) throw new ApiError(409, "ROUTE_POLICY_STALE", "Het routebeleid is intussen gewijzigd. Haal de actuele versie op; je invoer blijft behouden.");
      if (result.error.code === "22023" || /INVALID|COVERAGE_PORTAL/.test(result.error.message ?? "")) throw new ApiError(422, "INVALID_ROUTE_POLICY", "Controleer het loopbudget, de vroegtegrens en de gekozen actieve gewone poorten.");
      throw new ApiError(409, "ROUTE_POLICY_UNAVAILABLE", "Het routebeleid kon niet worden bevestigd. Vernieuw de gegevens en probeer dezelfde opdracht opnieuw.");
    }
    if (!result.data) throw new ApiError(409, "ROUTE_POLICY_UNAVAILABLE", "Het routebeleid is niet beschikbaar.");
    return apiSuccess(result.data);
  } catch (error) {
    if (error instanceof RangeError) return apiFailure(new ApiError(413, "BODY_TOO_LARGE", "Het verzoek is te groot."), requestId);
    return apiFailure(error, requestId);
  }
}
