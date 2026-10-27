export type MailVersion = { id: string; version: number; provider: "resend" | "sendgrid"; config_hash: string; from_email: string; from_name: string; reply_to: string };
export type MailCheck = { ready: boolean; code: string | null; configHash: string; checks: Record<string, boolean> };
export type MailSettingsSnapshot = {
  lastTest: { status: string; deliveryStatus: string; code: string | null; at: string; providerId: string | null; configId: string; simulated: boolean } | null;
  revision: number; draftTestVerified: boolean; active: MailVersion; draft: MailVersion | null; checkedAt: string | null; checkedId: string | null; checkResult: MailCheck | null;
  suppressionsImportedAt: string | null; lastWebhookAt: string | null; legacyReconciliation: number;
  attempts: Array<{ id: string; channel: string; message_type: string; provider: string; provider_id: string | null; status: string; delivery_status: string; error_code: string | null; first_attempt_at: string; delivered_at: string | null }>;
  events: Array<{ channel?: string; message_type?: string; provider_event_id: string; provider: string; provider_message_id: string | null; kind: string; occurred_at: string; safe_code: string | null }>;
};
export type MailSettings = MailSettingsSnapshot & {
  environment: string; webhookUrl: string; secrets: { apiKey: boolean; webhookSecret: boolean; administrationKey: boolean };
  modes: { mail: string; auth: string; newsletterEnabled: boolean; transactionalAllowlist: string[]; testRecipients: string[]; editorialAllowlist: string[] };
};
