export type MailState = "pending" | "processing" | "accepted" | "delivered" | "deferred" | "failed" | "unknown" | "suppressed" | "validated";

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
