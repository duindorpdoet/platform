import { apiFailure, apiSuccess, ApiError, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { frightnightConfig, frightnightSnapshot } from "@/lib/frightnight/server";
import { editionInvitationSecret } from "@/lib/frightnight/edition-context";
import { createEditionInvitation } from "@/lib/frightnight/edition-invitation";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const snapshot = await frightnightSnapshot();
    if (!snapshot.actor.capabilities.includes("event_admin") || snapshot.event.closed) throw new ApiError(403, "EVENT_ADMIN_REQUIRED", "Alleen de organisator kan een open testeditie delen.");
    const invitation = createEditionInvitation(snapshot.event.slug, editionInvitationSecret());
    const url = new URL("/nachtpas", frightnightConfig().APP_URL);
    url.hash = new URLSearchParams({ testinvite: invitation.token }).toString();
    return apiSuccess({ url: url.href, expiresAt: invitation.expiresAt, grants: "own-registration-only" });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
