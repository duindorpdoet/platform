import { z } from "zod";
import { serverEnv } from "@/lib/config/server-env";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";

const schema = z.object({
  eventType: z.enum([
    "login_completed",
    "environment_opened",
    "pwa_install_prompt_accepted",
    "pwa_install_completed",
    "pwa_install_manual_confirmed",
    "pwa_standalone_opened",
  ]),
  surface: z.enum([
    "participant",
    "group",
    "homeowner",
    "child",
    "admin",
    "editorial",
    "share_studio",
    "unknown",
  ]),
  sessionId: z.uuid(),
  metadata: z.object({
    platform: z.enum(["ios", "android", "desktop", "other"]).optional(),
    displayMode: z.enum(["browser", "standalone"]).optional(),
  }).strict().default({}),
}).strict();

export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = schema.parse(await request.json());
    const client = await createClient();
    if (!client) throw new Error("Supabase is not configured");
    const result = await client.schema("api").rpc("analytics_track", {
      _event_slug: serverEnv().EVENT_SLUG,
      _event_type: input.eventType,
      _surface: input.surface,
      _session_id: input.sessionId,
      _metadata: input.metadata,
    });
    if (result.error) throw result.error;
    return apiSuccess({ accepted: true }, 202);
  } catch (error) {
    return apiFailure(error, correlationId(request));
  }
}
