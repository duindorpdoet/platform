import { z } from "zod";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
import { opaqueSubjectHash } from "@/lib/http/request-hash";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

const schema = z.object({ name: z.string().trim().min(1).max(120), email: z.email(), subject: z.string().trim().min(3).max(160), body: z.string().trim().min(3).max(4000), website: z.string().max(0), startedAt: z.number().int() });

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
    const { data, error } = await client.schema("api").rpc("submit_public_contact", {
      _event_slug: env.EVENT_SLUG, _sender_name: input.name, _sender_email: input.email, _subject: input.subject,
      _body: input.body, _opaque_subject_hash: opaqueSubjectHash(env.ABUSE_HASH_SECRET, forwarded, input.email),
    });
    if (error) throw error;
    return apiSuccess(data, 201);
  } catch (error) { return apiFailure(error, requestId); }
}
