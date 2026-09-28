import { z } from "zod";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { interpolateShareText, isShareFormat, privacySafeSerialized, type ShareDynamic, type ShareFormat, type ShareStyle, type ShareTextConfig } from "@/lib/social-share/catalog";
import { renderShareCard } from "@/lib/social-share/render";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

export const runtime = "nodejs";

const inputSchema = z.object({
  templateKey: z.enum(["participant", "gate_owner", "join_us", "recruit_gate", "recruit_helper", "team_reveal", "world_reveal", "countdown", "participant_recap", "gate_recap", "general_event"]),
  format: z.string().refine(isShareFormat),
  style: z.enum(["event", "world"]),
  sessionId: z.uuid(),
});

type Reservation = {
  cached: boolean;
  generationId: string;
  publicShareId: string;
  storagePath: string;
  ogStoragePath: string;
  safePayload: ShareDynamic;
  template: {
    key: string; name: string; version: number; portraitAsset: string; landscapeAsset: string;
    textConfig: ShareTextConfig; defaultCaption: string; ctaType: string;
  };
};

function generationError(message: string) {
  if (message.includes("RATE_LIMITED")) return new ApiError(429, "RATE_LIMITED", "Je maakt veel kaarten achter elkaar. Wacht een minuut en probeer opnieuw.");
  if (message.includes("NOT_AUTHORIZED")) return new ApiError(403, "NOT_AUTHORIZED", "Deze deelkaart is niet beschikbaar voor jouw account.");
  return new ApiError(422, "INVALID_CARD", "Deze combinatie kan niet worden gemaakt.");
}
async function withRenderDeadline<T>(job: Promise<T>) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      job,
      new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("RENDER_TIMEOUT")), 15_000); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = inputSchema.parse(await request.json());
    const actor = await getActor();
    const privileged = createPrivilegedClient();
    if (!privileged) throw new ApiError(503, "UNAVAILABLE", "De Deelstudio is even niet beschikbaar.");
    const reserved = await privileged.schema("api").rpc("social_share_generation_reserve", {
      _event_slug: serverEnv().EVENT_SLUG,
      _actor: actor?.userId ?? null,
      _anonymous_session: input.sessionId,
      _template_key: input.templateKey,
      _format: input.format,
      _style: input.style,
    });
    if (reserved.error) throw generationError(reserved.error.message);
    const reservation = reserved.data as unknown as Reservation;
    if (!reservation || !privacySafeSerialized(reservation.safePayload)) throw new ApiError(500, "UNSAFE_CONTEXT", "De veilige kaartgegevens konden niet worden bevestigd.");

    const origin = new URL(serverEnv().APP_URL || serverEnv().NEXT_PUBLIC_SITE_URL || request.url).origin;
    const publicPageUrl = `${origin}/delen/${reservation.publicShareId}`;
    if (!reservation.cached) {
      try {
        const common = {
          style: input.style as ShareStyle,
          portraitAsset: reservation.template.portraitAsset,
          landscapeAsset: reservation.template.landscapeAsset,
          textConfig: reservation.template.textConfig,
          dynamic: reservation.safePayload,
          publicUrl: publicPageUrl,
          allowedOrigin: origin,
          includeQr: true,
          environmentLabel: serverEnv().APP_ENVIRONMENT === "staging" ? "STAGING" : undefined,
        };
        const [image, openGraph] = await withRenderDeadline(Promise.all([
          renderShareCard({ ...common, format: input.format as ShareFormat }),
          renderShareCard({ ...common, format: "opengraph" }),
        ]));
        const [assetUpload, ogUpload] = await Promise.all([
          privileged.storage.from("social-share-assets").upload(reservation.storagePath, image, { contentType: "image/png", cacheControl: "86400", upsert: false }),
          privileged.storage.from("social-share-assets").upload(reservation.ogStoragePath, openGraph, { contentType: "image/png", cacheControl: "31536000", upsert: false }),
        ]);
        if (assetUpload.error || ogUpload.error) throw assetUpload.error ?? ogUpload.error;
        const completed = await privileged.schema("api").rpc("social_share_generation_complete", { _generation_id: reservation.generationId, _success: true });
        if (completed.error) throw completed.error;
      } catch (error) {
        await Promise.allSettled([
          privileged.storage.from("social-share-assets").remove([reservation.storagePath, reservation.ogStoragePath]),
          privileged.schema("api").rpc("social_share_generation_complete", { _generation_id: reservation.generationId, _success: false }),
        ]);
        throw error;
      }
    }
    const caption = interpolateShareText(
      reservation.template.defaultCaption,
      reservation.safePayload,
      origin,
      reservation.template.textConfig.houseRegistrationPath,
    );
    return apiSuccess({
      generationId: reservation.generationId,
      publicShareId: reservation.publicShareId,
      imageUrl: `/api/deelstudio/public/${reservation.publicShareId}/image?kind=asset`,
      publicPageUrl,
      caption,
      cached: reservation.cached,
    }, reservation.cached ? 200 : 201);
  } catch (error) {
    return apiFailure(error instanceof Error && error.message === "RENDER_TIMEOUT" ? new ApiError(504, "RENDER_TIMEOUT", "Het maken duurt te lang. Probeer het nog eens.") : error, requestId);
  }
}
