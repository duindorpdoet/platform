import { createPushBatchBudget } from "@/lib/pwa/push-security";
import { editorialTick } from "@/lib/editorial/worker";
import { renderNewsletter, type NewsletterMaterial } from "@/lib/editorial/mail";
import { deliverPortalPushBatch } from "@/lib/pwa/portal-push";
import { NextResponse } from "next/server";
import { mailAllowlist, serverEnv } from "@/lib/config/server-env";
import { ApiError } from "@/lib/http/api";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { renderTransactionalMail, UnknownMailTemplateError } from "@/lib/mail/templates";
import { MailGatewayError, sendMailViaGateway } from "@/lib/mail/gateway";
import { nextRetry, summarizeMailWorkerResults, type MailWorkerResultState } from "@/lib/mail/status";
import { cleanupSocialShareAssets } from "@/lib/social-share/cleanup";

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
      const probe = await sendMailViaGateway({
        to: probeRecipient,
        subject: "Transactionele mailgateway runtimecontrole",
        text: "Geautomatiseerde runtimecontrole van de transactionele mailgateway.",
        html: "<p>Geautomatiseerde runtimecontrole van de transactionele mailgateway.</p>",
        sandbox: true,
      });
      return NextResponse.json({ probe: "transactional_gateway", validated: probe.validated, accepted: false });
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

  const pushBudget=createPushBatchBudget();
  await editorialTick(pushBudget).catch(() => console.error("editorial_worker_failed", { code: "WORKER_UNAVAILABLE" }));
  await deliverPortalPushBatch(pushBudget).catch(() => console.error("portal_push_worker_failed", { code: "DELIVERY_UNAVAILABLE" }));
  await cleanupSocialShareAssets().catch(() => console.error("social_share_cleanup_failed", { code: "CLEANUP_UNAVAILABLE" }));
  if (env.MAIL_MODE === "disabled") {
    return NextResponse.json({ claimed: 0, reason: "mail-disabled" });
  }

  const supabase = createPrivilegedClient();
  if (!supabase) {
    return NextResponse.json({ error: "service-not-configured" }, { status: 503 });
  }

  async function updateOutbox(args: Record<string, unknown>) {
    const stored = await supabase!.schema("api").rpc("worker_update_outbox", args);
    if (stored.error) throw new ApiError(503, "MAIL_STATUS_STORE_FAILED", "De mailstatus kon niet worden opgeslagen.");
  }

  const { data, error } = await supabase
    .schema("api")
    .rpc("worker_claim_outbox", { _batch_size: 10, _lease_seconds: 300, _environment: env.APP_ENVIRONMENT });

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

  const results: Array<{ id: string; status: MailWorkerResultState; errorCode?: string }> = [];

  for (const row of rows) {
    try {
      if (["group_schedule_published", "group_schedule_corrected", "group_composition_confirmed", "group_assignment_withdrawn"].includes(row.message_type)) {
        const appointment = await supabase.schema("api").rpc("worker_group_schedule_mail_payload", { _outbox_id: row.id });
        if (appointment.error) throw new ApiError(503, "APPOINTMENT_MATERIAL_UNAVAILABLE", "Probeer het later opnieuw.");
        if (!appointment.data) {
          await updateOutbox( { _id: row.id, _status: "suppressed", _provider_id: null, _error_code: "APPOINTMENT_SUPERSEDED", _next_attempt_at: null });
          continue;
        }
        row.payload = appointment.data;
        if (typeof appointment.data.messageType === "string") row.message_type = appointment.data.messageType;
      }
      if (row.message_type === "portal_manual_instructions") {
        const material = await supabase.schema("api").rpc("worker_manual_portal_instructions", { _outbox_id: row.id });
        if (material.error) throw material.error;
        if (!material.data) {
          await updateOutbox( { _id: row.id, _status: "suppressed", _provider_id: null, _error_code: "INVITATION_UNAVAILABLE", _next_attempt_at: null });
          continue;
        }
        row.payload = material.data;
      }
      if (row.message_type === "portal_team_invite") {
        const material = await supabase.schema("api").rpc("portal_invitation_mail_payload", { _invite_id: row.payload.inviteId });
        if (material.error) throw material.error;
        if (!material.data) {
          await updateOutbox( { _id: row.id, _status: "suppressed", _provider_id: null, _error_code: "INVITATION_UNAVAILABLE", _next_attempt_at: null });
          continue;
        }
        row.payload = material.data;
      }
      let rendered;
      if (row.message_type === "nachtpost") {
        if (env.NEWSLETTER_SENDING_ENABLED !== "true") {
          await updateOutbox( { _id: row.id, _status: "deferred", _provider_id: null, _error_code: "NEWSLETTER_DISABLED", _next_attempt_at: new Date(Date.now() + 300000).toISOString() });
          continue;
        }
        const material = await supabase.schema("api").rpc("worker_newsletter_material", { _outbox: row.id });
        if (material.error) throw new ApiError(503, "NEWSLETTER_MATERIAL_UNAVAILABLE", "Probeer het later opnieuw.");
        if (!material.data) {
          await updateOutbox( { _id: row.id, _status: "suppressed", _provider_id: null, _error_code: "EDITORIAL_CONSENT_OR_ACCESS_REVOKED", _next_attempt_at: null });
          continue;
        }
        rendered = renderNewsletter(material.data as NewsletterMaterial);
      } else rendered = renderTransactionalMail({ messageType: row.message_type, payload: row.payload });
      const sent = await sendMailViaGateway({
        to: row.recipient_email,
        ...rendered,
        outboxId: row.id,
        messageType: row.message_type,
        ...(row.message_type === "mail_provider_test" ? { testConfigId: String(row.payload.configId) } : {}),
        editorial: row.message_type === "nachtpost",
      });

      await updateOutbox( {
        _id: row.id,
        _status: sent.validated ? "validated" : "accepted",
        _provider_id: sent.providerId,
        _error_code: null,
        _next_attempt_at: null,
      });

      results.push({ id: row.id, status: sent.validated ? "validated" : "accepted" });
    } catch (cause) {
      const unknownTemplate = cause instanceof UnknownMailTemplateError;
      const uncertain = cause instanceof MailGatewayError ? cause.outcome === "unknown" : cause instanceof ApiError && ["MAIL_GATEWAY_NETWORK", "MAIL_PROVIDER_TIMEOUT", "MAIL_ACCEPTANCE_UNCERTAIN", "MAIL_STATUS_STORE_FAILED", "MAIL_RECONCILIATION_REQUIRED"].includes(cause.code);
      const terminal = unknownTemplate || (cause instanceof ApiError && ["MAIL_PROVIDER_REJECTED", "RECIPIENT_NOT_ALLOWED"].includes(cause.code)) || (!uncertain && row.attempts >= 8);
      const errorCode = unknownTemplate
        ? cause.code
        : cause instanceof ApiError
          ? cause.code.slice(0, 100)
          : cause instanceof Error
            ? cause.name.slice(0, 100)
            : "UNKNOWN";

      await updateOutbox( {
        _id: row.id,
        _status: uncertain ? "unknown" : terminal ? "failed" : "deferred",
        _provider_id: null,
        _error_code: errorCode,
        _next_attempt_at: terminal ? null : cause instanceof MailGatewayError ? new Date(Date.now() + cause.retryAfterSeconds * 1000).toISOString() : nextRetry(row.attempts).toISOString(),
      });

      results.push({
        id: row.id,
        status: uncertain ? "unknown" : terminal ? "failed" : "deferred",
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
