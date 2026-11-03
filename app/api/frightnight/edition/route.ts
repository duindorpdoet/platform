import { z } from "zod";
import { createHash } from "node:crypto";
import { apiFailure, apiSuccess, ApiError, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightActor, frightnightServiceRpc, rpcError, smallJson } from "@/lib/frightnight/server";
import { editionInvitationSecret, selectFrightnightSlug, validTestSlug } from "@/lib/frightnight/edition-context";
import { verifyEditionInvitationClaims } from "@/lib/frightnight/edition-invitation";
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
    const claims = invited ? verifyEditionInvitationClaims(values.invitation, editionInvitationSecret()) : null;
    const slug = invited ? claims?.slug : values.slug;
    if (!slug) throw new ApiError(403, "INVITATION_INVALID", "Deze testuitnodiging is ongeldig of verlopen. Vraag de organisator om een nieuwe link.");
    // The Data API independently checks edition entry. A signed browser cookie
    // cannot authorize a direct authenticated RPC against a private copy.
    if (invited && claims && slug !== "frightnight-2027-test") {
      await frightnightServiceRpc("frightnight_entry_grant", {
        p_slug: slug,
        p_actor: actor.userId,
        p_expires_at: claims.expiresAt,
        p_invitation_digest: createHash("sha256").update(values.invitation).digest("hex"),
      });
    }
    const client = await createClient();
    const { data, error } = await client!.schema("api").rpc("frightnight_snapshot", { p_slug: slug });
    if (error) rpcError(error);
    const snapshot = data as FrightnightSnapshot;
    if (!snapshot.event.test || snapshot.event.environment !== "staging" || (invited && snapshot.event.closed)) throw new ApiError(403, "EDITION_ACCESS_REQUIRED", "Je hebt geen actieve deelname, geldige uitnodiging of rol in deze testeditie.");
    await selectFrightnightSlug(actor.userId, slug);
    return apiSuccess({ selected: slug, snapshot });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
