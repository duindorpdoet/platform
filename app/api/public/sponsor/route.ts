import { z } from "zod";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { opaqueSubjectHash } from "@/lib/http/request-hash";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

const schema = z.object({ name: z.string().trim().min(1).max(120), email: z.email(), contributionType: z.enum(["geld", "materiaal", "dienst", "anders"]), amountEuros: z.number().int().min(0).max(100000), message: z.string().trim().max(4000), website: z.string().max(0), startedAt: z.number().int() });

export async function POST(request: Request) {
  const requestId = correlationId(request);
  try {
    assertTrustedOrigin(request);
    const input = schema.parse(await request.json());
    if (Date.now() - input.startedAt < 1500) return apiSuccess({ accepted: true });
    const env = serverEnv();
    if (!env.ABUSE_HASH_SECRET) throw new Error("ABUSE_HASH_SECRET missing");
    const client = createPrivilegedClient();
    if (!client) throw new Error("Supabase missing");
    const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0] ?? "unknown";
    const { data, error } = await client.schema("api").rpc("submit_public_sponsor", {
      _event_slug: env.EVENT_SLUG, _contact_name: input.name, _contact_email: input.email,
      _contribution_type: input.contributionType, _proposed_amount_cents: input.amountEuros * 100,
      _message: input.message, _opaque_subject_hash: opaqueSubjectHash(env.ABUSE_HASH_SECRET, forwarded, input.email),
    });
    if (error) throw error;
    return apiSuccess(data, 201);
  } catch (error) { return apiFailure(error, requestId); }
}
