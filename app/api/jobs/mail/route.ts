import { NextResponse } from "next/server";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { renderTransactionalMail } from "@/lib/mail/templates";
import { sendSendGrid } from "@/lib/mail/sendgrid";
import { nextRetry } from "@/lib/mail/status";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const env = serverEnv();
  if (!env.CRON_SECRET || request.headers.get("authorization") !== `Bearer ${env.CRON_SECRET}`) return new NextResponse(null, { status: 401 });
  if (env.MAIL_MODE === "disabled") return NextResponse.json({ claimed: 0, reason: "mail-disabled" });
  const supabase = createPrivilegedClient();
  if (!supabase) return NextResponse.json({ error: "service-not-configured" }, { status: 503 });
  const { data, error } = await supabase.schema("api").rpc("worker_claim_outbox", { _batch_size: 20, _lease_seconds: 120 });
  if (error) return NextResponse.json({ error: "claim-failed" }, { status: 500 });
  const rows = (data ?? []) as Array<{ id: string; message_type: string; recipient_email: string; payload: Record<string, unknown>; attempts: number }>;
  const results = [];
  for (const row of rows) {
    try {
      const rendered = renderTransactionalMail({ messageType: row.message_type, payload: row.payload });
      const sent = await sendSendGrid({ to: row.recipient_email, ...rendered, outboxId: row.id });
      await supabase.schema("api").rpc("worker_update_outbox", { _id: row.id, _status: "accepted", _provider_id: sent.providerId, _error_code: null, _next_attempt_at: null });
      results.push({ id: row.id, status: "accepted" });
    } catch (cause) {
      const terminal = row.attempts >= 8;
      await supabase.schema("api").rpc("worker_update_outbox", {
        _id: row.id,
        _status: terminal ? "failed" : "deferred",
        _provider_id: null,
        _error_code: cause instanceof Error ? cause.name.slice(0, 100) : "UNKNOWN",
        _next_attempt_at: terminal ? null : nextRetry(row.attempts).toISOString(),
      });
      results.push({ id: row.id, status: terminal ? "failed" : "deferred" });
    }
  }
  return NextResponse.json({ claimed: rows.length, results });
}
