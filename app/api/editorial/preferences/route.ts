import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { serverEnv } from "@/lib/config/server-env";
import {
  apiFailure,
  apiSuccess,
  ApiError,
  assertTrustedOrigin,
  correlationId,
} from "@/lib/http/api";
import { editorialError } from "@/lib/editorial/server";
export async function GET(request: Request) {
  try {
    const client = await createClient();
    if (!client)
      throw new ApiError(503, "UNAVAILABLE", "Probeer het later opnieuw.");
    const { data, error } = await client
      .schema("api")
      .rpc("editorial_preferences", { _event_slug: serverEnv().EVENT_SLUG });
    if (error) throw editorialError(error);
    return apiSuccess(data);
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const command = z
      .object({
        email: z.boolean(),
        parentsPush: z.boolean(),
        housesPush: z.boolean(),
      })
      .strict()
      .parse(await request.json());
    const client = await createClient();
    if (!client)
      throw new ApiError(503, "UNAVAILABLE", "Probeer het later opnieuw.");
    const { data, error } = await client
      .schema("api")
      .rpc("editorial_preferences_set", {
        _event_slug: serverEnv().EVENT_SLUG,
        _email: command.email,
        _parents_push: command.parentsPush,
        _houses_push: command.housesPush,
      });
    if (error) throw editorialError(error);
    return apiSuccess(data);
  } catch (cause) {
    return apiFailure(cause, correlationId(request));
  }
}
