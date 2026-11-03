import { z } from "zod";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId, ApiError } from "@/lib/http/api";
import { frightnightActor, rpcError, smallJson } from "@/lib/frightnight/server";
import { activeFrightnightSlug } from "@/lib/frightnight/edition-context";
import { createClient } from "@/lib/supabase/server";

const capability = z.enum(["content_manage", "event_admin", "groups_manage", "live_support", "payments_manage", "portals_manage", "registration_manage"]);
const input = z.object({ email: z.email().max(254), capabilities: z.array(capability).max(7), expectedCapabilities: z.array(capability).max(7), reason: z.string().trim().min(10).max(500) }).strict();

export async function GET(request: Request) {
  try {
    const actor = await frightnightActor();
    const slug = await activeFrightnightSlug(actor.userId);
    const client = await createClient();
    if (!client) throw new ApiError(503, "BACKEND_UNAVAILABLE", "Toegangsbeheer is tijdelijk niet bereikbaar.");
    // Existing database authorization checks the actor and this exact event.
    const { data, error } = await client.schema("api").rpc("admin_access_snapshot", { _event_slug: slug });
    if (error) rpcError(error);
    return apiSuccess({ ...data, eventSlug: slug });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}

export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const actor = await frightnightActor();
    const values = input.parse(await smallJson(request));
    const client = await createClient();
    if (!client) throw new ApiError(503, "BACKEND_UNAVAILABLE", "Toegangsbeheer is tijdelijk niet bereikbaar.");
    const { data, error } = await client.schema("api").rpc("admin_set_user_capabilities", {
      _event_slug: await activeFrightnightSlug(actor.userId), _email: values.email,
      _capabilities: values.capabilities, _expected_capabilities: values.expectedCapabilities, _reason: values.reason,
    });
    if (error) rpcError(error);
    return apiSuccess(data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
