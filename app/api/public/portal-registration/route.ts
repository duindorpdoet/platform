import { z } from "zod";
import { ApiError, apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { opaqueSubjectHash } from "@/lib/http/request-hash";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

const schema = z.object({
  email: z.email().max(320),
  contactName: z.string().trim().min(2).max(120),
  phone: z.string().trim().min(6).max(32),
  website: z.string().max(0),
  startedAt: z.number().int(),
});

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = schema.parse(await request.json());
    if (input.startedAt > Date.now() + 60_000) throw new ApiError(422, "VALIDATION_ERROR", "Controleer de ingevulde gegevens.");

    const env = serverEnv();
    if (env.REGISTRATION_MODE === "closed") {
      throw new ApiError(409, "PORTAL_REGISTRATION_CLOSED", "De organisatie heeft nieuwe locatieaanmeldingen gepauzeerd.");
    }
    if (!env.ABUSE_HASH_SECRET) throw new Error("ABUSE_HASH_SECRET missing");
    const client = createPrivilegedClient();
    if (!client) throw new Error("Supabase missing");
    const normalizedEmail = input.email.trim().toLowerCase();
    const { data, error } = await client.schema("api").rpc("portal_registration_begin", {
      _event_slug: env.EVENT_SLUG,
      _email: normalizedEmail,
      _contact_name: input.contactName,
      _phone: input.phone,
      _street: "",
      _house_number: "",
      _addition: null,
      _postal_code: "",
      // A caller can influence forwarded network headers. Keep the mutation
      // limit stable for the target account regardless of proxy or IP changes.
      _opaque_subject_hash: opaqueSubjectHash(env.ABUSE_HASH_SECRET, "portal-registration", normalizedEmail),
    });
    if (error) {
      if (error.message.includes("PORTAL_REGISTRATION_CLOSED")) {
        throw new ApiError(409, "PORTAL_REGISTRATION_CLOSED", "De organisatie heeft nieuwe locatieaanmeldingen gepauzeerd.");
      }
      if (error.message.includes("RATE_LIMITED")) {
        throw new ApiError(429, "RATE_LIMITED", "Wacht even voordat je opnieuw een code aanvraagt.");
      }
      if (error.code === "22023") throw new ApiError(422, "VALIDATION_ERROR", "Controleer de ingevulde gegevens.");
      throw error;
    }
    return apiSuccess(data, 201);
  } catch (error) {
    return apiFailure(error, requestId);
  }
}
