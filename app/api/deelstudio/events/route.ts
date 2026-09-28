import { z } from "zod";
import { serverEnv } from "@/lib/config/server-env";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";

const schema = z.object({
  publicShareId: z.string().regex(/^[a-f0-9]{32}$/).nullable().optional(),
  templateKey: z.string().regex(/^[a-z_]{3,40}$/).nullable().optional(),
  eventType: z.enum(["studio_opened", "template_selected", "preview_generated", "image_downloaded", "caption_copied", "link_copied", "native_share_opened", "native_share_completed", "platform_fallback_opened", "public_page_viewed", "house_registration_started", "house_registration_completed", "participant_registration_started", "participant_registration_completed"]),
  platform: z.enum(["native", "facebook", "instagram", "snapchat", "whatsapp", "x"]).nullable().optional(),
  sessionId: z.uuid(),
});

export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const input = schema.parse(await request.json());
    const client = await createClient();
    if (!client) throw new Error("Supabase is not configured");
    const result = await client.schema("api").rpc("social_share_track", {
      _event_slug: serverEnv().EVENT_SLUG,
      _public_share_id: input.publicShareId ?? null,
      _template_key: input.templateKey ?? null,
      _event_type: input.eventType,
      _platform: input.platform ?? null,
      _session_id: input.sessionId,
    });
    if (result.error) throw result.error;
    return apiSuccess({ accepted: true }, 202);
  } catch (error) {
    return apiFailure(error, correlationId(request));
  }
}
