import { z } from "zod";
import {
  ApiError,
  apiFailure,
  apiSuccess,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
const input = z.object({
  token: z.string().regex(/^[a-f0-9]{64}$/),
  email: z.email().max(254),
});
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const value = input.parse(await request.json());
    const client = createPrivilegedClient();
    if (!client)
      throw new ApiError(503, "UNAVAILABLE", "Probeer het later opnieuw.");
    const result = await client
      .schema("api")
      .rpc("portal_invitation_check", {
        _token: value.token,
        _email: value.email,
      });
    if (result.error || result.data !== true)
      throw new ApiError(
        403,
        "INVITATION_UNAVAILABLE",
        "Controleer de uitnodiging en het e-mailadres.",
      );
    return apiSuccess({ valid: true });
  } catch (error) {
    return apiFailure(error, correlationId(request));
  }
}
