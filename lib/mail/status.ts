export type MailState = "pending" | "processing" | "accepted" | "delivered" | "deferred" | "failed" | "unknown" | "suppressed" | "validated";
export type MailWorkerResultState = "accepted" | "deferred" | "failed" | "validated" | "unknown";

export function summarizeMailWorkerResults(results: Array<{ status: MailWorkerResultState }>) {
  return results.reduce(
    (summary, result) => ({
      ...summary,
      [result.status]: summary[result.status] + 1,
    }),
    { accepted: 0, deferred: 0, failed: 0, validated: 0, unknown: 0 },
  );
}

// Legacy SendGrid outbox projection helper. Resend retains independent delivery,
// complaint and suppression fields in the authoritative database projection.
export function statusForProviderEvent(current: MailState, event: string): MailState {
  if (current === "delivered" || current === "failed") return current;
  if (event === "delivered") return "delivered";
  if (["bounce", "dropped", "spamreport"].includes(event)) return "failed";
  if (event === "deferred") return "deferred";
  return current;
}

export function nextRetry(attempt: number, now = Date.now()) {
  const seconds = Math.min(3600, 15 * 2 ** Math.max(0, attempt - 1));
  return new Date(now + seconds * 1000);
}
