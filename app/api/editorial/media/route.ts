import { randomUUID } from "node:crypto";
import { z } from "zod";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import {
  apiFailure,
  apiSuccess,
  ApiError,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { editorialEnabled, editorialError } from "@/lib/editorial/server";
import { editorialImageVariants, mediaVariants } from "@/lib/editorial/media";
export const runtime = "nodejs";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    if (!editorialEnabled())
      throw new ApiError(404, "NOT_FOUND", "Niet gevonden.");
    if (!(await getActor()))
      throw new ApiError(401, "LOGIN_REQUIRED", "Log opnieuw in.");
    if (Number(request.headers.get("content-length")) > 13 * 1024 * 1024)
      throw new ApiError(413, "TOO_LARGE", "Maximaal 12 MB per afbeelding.");
    const client = await createClient();
    const privileged = createPrivilegedClient();
    if (!client || !privileged)
      throw new ApiError(
        503,
        "UNAVAILABLE",
        "Uploaden is even niet beschikbaar.",
      );
    const access = await client
      .schema("api")
      .rpc("admin_editorial_snapshot", { _event_slug: serverEnv().EVENT_SLUG });
    if (access.error) throw editorialError(access.error);
    const form = await request.formData();
    const file = form.get("file");
    if (!(file instanceof File) || file.size > 12 * 1024 * 1024)
      throw new ApiError(
        422,
        "INVALID_FILE",
        "Kies een afbeelding van maximaal 12 MB.",
      );
    const meta = z
      .object({
        alt: z.string().trim().min(1).max(300),
        caption: z.string().max(500),
        focalX: z.coerce.number().min(0).max(100),
        focalY: z.coerce.number().min(0).max(100),
      })
      .parse(
        Object.fromEntries(
          ["alt", "caption", "focalX", "focalY"].map((key) => [
            key,
            form.get(key),
          ]),
        ),
      );
    const image = await editorialImageVariants(
      Buffer.from(await file.arrayBuffer()),
      file.type,
      meta.focalX,
      meta.focalY,
    );
    const id = randomUUID();
    const prefix = `${access.data.eventId}/${id}`;
    const paths: string[] = [];
    try {
      for (const variant of image.variants) {
        const path = `${prefix}/${variant.name}.webp`;
        const uploaded = await privileged.storage
          .from("editorial-media")
          .upload(path, variant.bytes, {
            contentType: "image/webp",
            cacheControl: "0",
            upsert: false,
          });
        if (uploaded.error)
          throw new ApiError(
            503,
            "UPLOAD_FAILED",
            "De afbeelding kon niet worden opgeslagen.",
          );
        paths.push(path);
      }
      const saved = await client
        .schema("api")
        .rpc("admin_editorial_media_register", {
          _event_slug: serverEnv().EVENT_SLUG,
          _id: id,
          _alt: meta.alt,
          _caption: meta.caption,
          _width: image.width,
          _height: image.height,
          _bytes: file.size,
          _focal_x: meta.focalX,
          _focal_y: meta.focalY,
        });
      if (saved.error) throw editorialError(saved.error);
      return apiSuccess({
        id,
        ...meta,
        width: image.width,
        height: image.height,
      });
    } catch (cause) {
      if (paths.length)
        await privileged.storage.from("editorial-media").remove(paths);
      throw cause;
    }
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
export async function DELETE(request: Request) {
  try {
    assertTrustedOrigin(request);
    if (!editorialEnabled() || !(await getActor()))
      throw new ApiError(403, "NOT_AUTHORIZED", "Geen toegang.");
    const { id } = z
      .object({ id: z.string().uuid() })
      .parse(await request.json());
    const client = await createClient();
    const privileged = createPrivilegedClient();
    if (!client || !privileged)
      throw new ApiError(503, "UNAVAILABLE", "Probeer het later opnieuw.");
    const { data, error } = await client
      .schema("api")
      .rpc("admin_editorial_media_delete", { _id: id });
    if (error) throw editorialError(error);
    const removed = await privileged.storage
      .from("editorial-media")
      .remove(
        Object.keys(mediaVariants).map(
          (variant) => `${data.eventId}/${id}/${variant}.webp`,
        ),
      );
    if (removed.error)
      throw new ApiError(
        503,
        "DELETE_FAILED",
        "De afbeelding is afgeschermd. Het verwijderen van de bestanden moet opnieuw worden geprobeerd.",
      );
    return apiSuccess({ deleted: true });
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
