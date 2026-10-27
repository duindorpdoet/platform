type SuppressionReason = "unsubscribe" | "invalid" | "bounce" | "spamreport";

export class SuppressionSyncError extends Error {}

export function syncSendGridSuppressions(options: {
  environment: string;
  apiKey: string;
  apiBaseUrl?: string;
  rpc: (name: "worker_import_mail_suppressions", args: {
    _environment: string;
    _entries: Array<{ emailHash: string; reason: SuppressionReason }>;
    _source_hash: string;
    _complete: boolean;
  }) => Promise<unknown>;
  fetchImpl?: (url: URL, init: RequestInit) => Promise<Response>;
  pause?: (milliseconds: number) => Promise<void>;
}): Promise<Record<SuppressionReason, number>>;
