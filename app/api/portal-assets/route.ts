import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { PORTAL_IMAGE_LIMIT, validatedPortalImage } from "@/lib/storage/image-signature";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const actor = await getActor();
    if (!actor) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in om een afbeelding toe te voegen.");
    const form = await request.formData();
    const applicationId = z.uuid().parse(form.get("applicationId"));
    const file = form.get("file");
    if (!(file instanceof File) || file.size < 1 || file.size > PORTAL_IMAGE_LIMIT) throw new ApiError(422, "INVALID_FILE", "Kies een JPG-, PNG- of WebP-afbeelding van maximaal 8 MB.");
    const bytes = new Uint8Array(await file.arrayBuffer());
    const image = validatedPortalImage(bytes, file.type.toLowerCase(), file.size);
    if (!image) throw new ApiError(422, "INVALID_FILE_CONTENT", "De inhoud van dit bestand is geen geldige JPG-, PNG- of WebP-afbeelding.");

    const userClient = await createClient();
    const snapshot = userClient ? await userClient.schema("api").rpc("portal_snapshot", { _event_slug: serverEnv().EVENT_SLUG }) : null;
    const application = snapshot?.data as { application?: { id?: string; status?: string } } | null;
    if (snapshot?.error || application?.application?.id !== applicationId || !["draft", "changes_requested", "submitted"].includes(application.application.status ?? "")) {
      throw new ApiError(403, "NOT_AUTHORIZED", "Deze aanvraag kan geen nieuwe afbeelding ontvangen.");
    }

    const privileged = createPrivilegedClient();
    if (!privileged) throw new Error("Supabase privileged storage is not configured");
    const path = `${actor.userId}/${applicationId}/${crypto.randomUUID()}.${image.extension}`;
    const upload = await privileged.storage.from("portal-application-assets").upload(path, bytes, { contentType: image.contentType, upsert: false });
    if (upload.error) throw upload.error;
    return apiSuccess({ path: upload.data.path, name: file.name.slice(0, 160) }, 201);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
