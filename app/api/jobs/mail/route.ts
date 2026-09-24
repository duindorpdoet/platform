import { NextResponse } from "next/server";
import { mailAllowlist, serverEnv } from "@/lib/config/server-env";
import { ApiError } from "@/lib/http/api";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { renderTransactionalMail, UnknownMailTemplateError } from "@/lib/mail/templates";
import { sendSendGrid } from "@/lib/mail/sendgrid";
import { nextRetry, summarizeMailWorkerResults } from "@/lib/mail/status";

export const runtime = "nodejs";

async function commandFor(request: Request) {
  try {
    return await request.json() as { probe?: string };
  } catch {
    return {};
  }
}

export async function POST(request: Request) {
  const env = serverEnv();
  if (!env.CRON_SECRET || request.headers.get("authorization") !== `Bearer ${env.CRON_SECRET}`) {
    return new NextResponse(null, { status: 401 });
  }

  const command = await commandFor(request);
  if (command.probe === "transactional_gateway") {
    if (env.MAIL_MODE === "disabled") {
      return NextResponse.json({ error: "mail-disabled" }, { status: 503 });
    }

    const probeRecipient = [...mailAllowlist()][0] ?? env.ORGANIZATION_SUPPORT_EMAIL;
    try {
      await sendSendGrid({
        to: probeRecipient,
        subject: "Transactionele mailgateway runtimecontrole",
        text: "Geautomatiseerde runtimecontrole van de transactionele mailgateway.",
        html: "<p>Geautomatiseerde runtimecontrole van de transactionele mailgateway.</p>",
        sandbox: true,
      });
      return NextResponse.json({ probe: "transactional_gateway", accepted: true });
    } catch (cause) {
      const status = cause instanceof ApiError ? cause.status : 502;
      const code = cause instanceof ApiError
        ? cause.code
        : cause instanceof Error
          ? cause.name.slice(0, 100)
          : "UNKNOWN";
      console.error("mail_gateway_runtime_probe_failed", { code });
      return NextResponse.json({ error: "mail-gateway-runtime-probe-failed", code }, { status });
    }
  }

  if (env.MAIL_MODE === "disabled") {
    return NextResponse.json({ claimed: 0, reason: "mail-disabled" });
  }

  const supabase = createPrivilegedClient();
  if (!supabase) {
    return NextResponse.json({ error: "service-not-configured" }, { status: 503 });
  }

  const { data, error } = await supabase
    .schema("api")
    .rpc("worker_claim_outbox", { _batch_size: 20, _lease_seconds: 120 });

  if (error) {
    return NextResponse.json({ error: "claim-failed" }, { status: 500 });
  }

  const rows = (data ?? []) as Array<{
    id: string;
    message_type: string;
    recipient_email: string;
    payload: Record<string, unknown>;
    attempts: number;
  }>;

  const results: Array<{ id: string; status: "accepted" | "deferred" | "failed"; errorCode?: string }> = [];

  for (const row of rows) {
    try {
      const rendered = renderTransactionalMail({
        messageType: row.message_type,
        payload: row.payload,
      });
      const sent = await sendSendGrid({
        to: row.recipient_email,
        ...rendered,
        outboxId: row.id,
      });

      await supabase.schema("api").rpc("worker_update_outbox", {
        _id: row.id,
        _status: "accepted",
        _provider_id: sent.providerId,
        _error_code: null,
        _next_attempt_at: null,
      });

      results.push({ id: row.id, status: "accepted" });
    } catch (cause) {
      const unknownTemplate = cause instanceof UnknownMailTemplateError;
      const terminal = unknownTemplate || row.attempts >= 8;
      const errorCode = unknownTemplate
        ? cause.code
        : cause instanceof ApiError
          ? cause.code.slice(0, 100)
          : cause instanceof Error
            ? cause.name.slice(0, 100)
            : "UNKNOWN";

      await supabase.schema("api").rpc("worker_update_outbox", {
        _id: row.id,
        _status: terminal ? "failed" : "deferred",
        _provider_id: null,
        _error_code: errorCode,
        _next_attempt_at: terminal ? null : nextRetry(row.attempts).toISOString(),
      });

      results.push({
        id: row.id,
        status: terminal ? "failed" : "deferred",
        errorCode,
      });
    }
  }

  // Every row outcome above is persisted in the outbox. A deferred or terminally
  // failed message is a handled delivery result, not an outage of this worker.
  // Returning 5xx here would make the scheduler retry the whole HTTP batch while
  // the outbox already owns the retry policy and lease state.
  return NextResponse.json({
    claimed: rows.length,
    ...summarizeMailWorkerResults(results),
    results,
  });
}
