import { createHash } from "node:crypto";
import { Webhook } from "svix";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { boundedBody } from "@/lib/http/bounded-body";
import { resendEventSchema, safeEventCode } from "@/lib/mail/resend-events";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const env = serverEnv();
  if (!env.RESEND_WEBHOOK_SECRET) return new Response(null, { status: 503 });
  const id = request.headers.get("svix-id");
  const timestamp = request.headers.get("svix-timestamp");
  const signature = request.headers.get("svix-signature");
  if (!id || !timestamp || !signature || id.length > 200) return new Response(null, { status: 401 });
  let body: string;
  try { body = await boundedBody(request, 128000); }
  catch (error) { return new Response(null, { status: error instanceof RangeError ? 413 : 400 }); }
  let verified: unknown;
  try {
    // Default Svix tolerance is enforced against the signature timestamp. Old
    // business created_at values on a newly signed replay remain legitimate.
    new Webhook(env.RESEND_WEBHOOK_SECRET).verify(body, { "svix-id": id, "svix-timestamp": timestamp, "svix-signature": signature });
  } catch { return new Response(null, { status: 401 }); }
  // Svix 2.x verifies bytes without parsing or returning the payload.
  try { verified = JSON.parse(body); } catch { return new Response(null, { status: 400 }); }
  const parsed = resendEventSchema.safeParse(verified);
  if (!parsed.success) return new Response(null, { status: 400 });
  const client = createPrivilegedClient();
  if (!client) return new Response(null, { status: 503 });
  const event = parsed.data;
  try {
    const stored = await client.schema("api").rpc("worker_store_resend_event", {
      _environment: env.APP_ENVIRONMENT, _event_id: id, _provider_id: event.data.email_id ?? null,
      _kind: event.type, _occurred_at: event.created_at, _recipient: event.data.to?.length === 1 ? event.data.to[0] : null,
      _safe_code: safeEventCode(event.type, event.data),
      _verification_key_hash: createHash("sha256").update(env.RESEND_WEBHOOK_SECRET).digest("hex"),
    });
    if (stored.error) return new Response(null, { status: 503 });
  } catch { return new Response(null, { status: 503 }); }
  return new Response(null, { status: 204 });
}
