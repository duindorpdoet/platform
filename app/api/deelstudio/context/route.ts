import { apiFailure, apiSuccess, correlationId } from "@/lib/http/api";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  try {
    const client = await createClient();
    if (!client) throw new Error("Supabase is not configured");
    const { data, error } = await client.schema("api").rpc("social_share_context", {
      _event_slug: serverEnv().EVENT_SLUG,
    });
    if (error) throw error;
    return apiSuccess(data);
  } catch (error) {
    return apiFailure(error, correlationId(request));
  }
}
