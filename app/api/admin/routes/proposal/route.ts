import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { boundedBody } from "@/lib/http/bounded-body";
import { createClient } from "@/lib/supabase/server";
import { proposeJointRoutes, type JointRouteInput } from "@/lib/domain/joint-route-planner";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const bodySchema = z.object({ eventSlug: z.string().min(1).max(100).regex(/^[a-z0-9-]+$/) }).strict();

/** Explicit read-only computation; applying a reviewed proposal is a separate locked DB command. */
export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const body = bodySchema.parse(JSON.parse(await boundedBody(request, 2048)));
    const client = await createClient();
    const identity = await client?.auth.getUser();
    if (!client || !identity?.data.user || identity.error) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in als bevoegde organisator.");
    const input = await client.schema("api").rpc("admin_joint_route_planning_input", { _event_slug: body.eventSlug });
    if (input.error) {
      if (input.error.code === "42501") throw new ApiError(403, "NOT_AUTHORIZED", "Groepsbeheer is nodig om een gezamenlijk routevoorstel te bekijken.");
      throw new ApiError(409, "ROUTE_INPUT_UNAVAILABLE", "De actuele routegegevens konden niet samen worden gecontroleerd. Vernieuw het planbord en probeer opnieuw.");
    }
    if (!input.data) throw new ApiError(409, "ROUTE_INPUT_UNAVAILABLE", "Er zijn nog geen controleerbare start- en routegegevens.");
    return apiSuccess(proposeJointRoutes(input.data as JointRouteInput));
  } catch (error) {
    if (error instanceof RangeError) return apiFailure(new ApiError(413, "BODY_TOO_LARGE", "Het verzoek is te groot."), requestId);
    if (error instanceof Error && error.message === "INVALID_JOINT_PLANNING_INPUT") return apiFailure(new ApiError(409, "ROUTE_INPUT_UNAVAILABLE", "De routegegevens passen niet binnen de begrensde gezamenlijke planner. Controleer de startafspraken."), requestId);
    return apiFailure(error, requestId);
  }
}
