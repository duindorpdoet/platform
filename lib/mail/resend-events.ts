import { z } from "zod";
export const resendEvents = ["email.sent", "email.delivered", "email.delivery_delayed", "email.bounced", "email.complained", "email.failed", "email.suppressed"] as const;
export const resendEventSchema = z.object({
  type: z.string().min(1).max(100), created_at: z.string().datetime({ offset: true }),
  data: z.object({ email_id: z.string().uuid().optional(), to: z.array(z.string().email().max(320)).max(50).optional(),
    bounce: z.object({ type: z.string().max(100).optional(), subType: z.string().max(100).optional() }).passthrough().optional(),
    suppressed: z.object({ type: z.string().max(100).optional() }).passthrough().optional(),
    failed: z.object({ reason: z.string().max(100).optional() }).passthrough().optional(),
  }).passthrough(),
}).passthrough().superRefine((event, ctx) => {
  if ((resendEvents as readonly string[]).includes(event.type) && (!event.data.email_id || event.data.to?.length !== 1)) ctx.addIssue({ code: "custom", message: "Missing provider ID or individual recipient" });
});
// Preserve documented reason classes without ever storing arbitrary SMTP text.
export function safeEventCode(type: string, data?: z.infer<typeof resendEventSchema>["data"]): string | null {
  if (type === "email.bounced") {
    const kind = ["Permanent", "Temporary", "Transient", "Undetermined"].includes(data?.bounce?.type ?? "") ? data!.bounce!.type!.toUpperCase() : "OTHER";
    const sub = ["Suppressed", "General", "MailboxFull", "MessageRejected", "ContentRejected", "MessageTooLarge", "NoEmail", "OnAccountSuppressionList"].includes(data?.bounce?.subType ?? "") ? data!.bounce!.subType!.toUpperCase() : "OTHER";
    return `RESEND_BOUNCED_${kind}_${sub}`;
  }
  if (type === "email.suppressed") return data?.suppressed?.type === "OnAccountSuppressionList" ? "RESEND_SUPPRESSED_ON_ACCOUNT_LIST" : "RESEND_SUPPRESSED_OTHER";
  if (type === "email.failed") {
    const known = ["reached_daily_quota", "reached_monthly_quota", "domain_not_verified", "invalid_recipient", "api_key_invalid", "domain_not_found", "sending_access_denied"];
    return known.includes(data?.failed?.reason ?? "") ? `RESEND_FAILED_${data!.failed!.reason!.toUpperCase()}` : "RESEND_FAILED_OTHER";
  }
  return type === "email.complained" ? "RESEND_COMPLAINED" : null;
}
