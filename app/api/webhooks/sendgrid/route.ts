import { NextResponse } from "next/server";
import { EventWebhook } from "@sendgrid/eventwebhook";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

export const runtime = "nodejs";

type SendGridEvent = { sg_event_id?: string; event?: string; timestamp?: number; outbox_id?: string; [key: string]: unknown };

export async function POST(request: Request) {
  const env = serverEnv();
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 1_000_000) return new NextResponse(null, { status: 413 });
  const signature = request.headers.get("x-twilio-email-event-webhook-signature") ?? "";
  const timestamp = request.headers.get("x-twilio-email-event-webhook-timestamp") ?? "";
  const body = await request.text();
  if (body.length > 1_000_000) return new NextResponse(null, { status: 413 });
  if (!env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY || !signature || !timestamp) return new NextResponse(null, { status: 401 });
  const eventTime = Number(timestamp);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(eventTime) || now - eventTime > env.SENDGRID_EVENT_MAX_AGE_SECONDS || eventTime - now > env.SENDGRID_EVENT_MAX_FUTURE_SKEW_SECONDS) return new NextResponse(null, { status: 401 });
  const verifier = new EventWebhook();
  const key = verifier.convertPublicKeyToECDSA(env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY);
  if (!verifier.verifySignature(key, body, signature, timestamp)) return new NextResponse(null, { status: 401 });

  let events: SendGridEvent[];
  try { events = JSON.parse(body) as SendGridEvent[]; } catch { return new NextResponse(null, { status: 400 }); }
  if (!Array.isArray(events)) return new NextResponse(null, { status: 400 });
  const supabase = createPrivilegedClient();
  if (!supabase) return new NextResponse(null, { status: 503 });
  for (const event of events.slice(0, 1000)) {
    if (!event.sg_event_id || !event.event || !event.timestamp || typeof event.outbox_id !== "string" || !/^[0-9a-f-]{36}$/i.test(event.outbox_id)) continue;
    const stored = await supabase.schema("api").rpc("worker_store_email_event", {
      _provider_event_id: event.sg_event_id,
      _outbox_id: event.outbox_id,
      _kind: event.event,
      _occurred_at: new Date(event.timestamp * 1000).toISOString(),
    });
    if (stored.error) return new NextResponse(null, { status: 503 });
  }
  return new NextResponse(null, { status: 204 });
}
