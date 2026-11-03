import { z } from "zod";
import { apiFailure, apiSuccess, ApiError, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightActor, rpcError, smallJson } from "@/lib/frightnight/server";
import { editionInvitationSecret, selectFrightnightSlug, validTestSlug } from "@/lib/frightnight/edition-context";
import { verifyEditionInvitation } from "@/lib/frightnight/edition-invitation";
import { createClient } from "@/lib/supabase/server";
import type { FrightnightSnapshot } from "@/lib/frightnight/model";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const actor = await frightnightActor();
    const values = z.union([
      z.object({ slug: z.string().refine(validTestSlug) }).strict(),
      z.object({ invitation: z.string().min(30).max(1024), consent: z.literal(true) }).strict(),
    ]).parse(await smallJson(request));
    const invited = "invitation" in values;
    const slug = invited ? verifyEditionInvitation(values.invitation, editionInvitationSecret()) : values.slug;
    if (!slug) throw new ApiError(403, "INVITATION_INVALID", "Deze testuitnodiging is ongeldig of verlopen. Vraag de organisator om een nieuwe link.");
    const client = await createClient();
    const { data, error } = await client!.schema("api").rpc("frightnight_snapshot", { p_slug: slug });
    if (error) rpcError(error);
    const snapshot = data as FrightnightSnapshot;
    if (!snapshot.event.test || snapshot.event.environment !== "staging" || (invited && snapshot.event.closed) || (!invited && !snapshot.registration && !snapshot.ownZones.length && !snapshot.actor.capabilities.length)) throw new ApiError(403, "EDITION_ACCESS_REQUIRED", "Je hebt geen actieve deelname, geldige uitnodiging of rol in deze testeditie.");
    await selectFrightnightSlug(actor.userId, slug);
    return apiSuccess({ selected: slug, snapshot });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
