export type TransactionalHookMessage = {
  to: string;
  subject: string;
  text: string;
  html: string;
  outboxId?: string;
  replyTo?: string;
  providerProbe?: boolean;
};

export type TransactionalHookPayload = {
  kind: "transactional";
  message: TransactionalHookMessage;
};

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function boundedString(value: unknown, min: number, max: number): value is string {
  return typeof value === "string" && value.length >= min && value.length <= max;
}

export function transactionalMessageForPayload(payload: unknown): TransactionalHookMessage | null {
  if (!payload || typeof payload !== "object") return null;
  const candidate = payload as { kind?: unknown; message?: unknown };
  if (candidate.kind !== "transactional" || !candidate.message || typeof candidate.message !== "object") return null;

  const message = candidate.message as Record<string, unknown>;
  if (!boundedString(message.to, 3, 320) || !emailPattern.test(message.to)) return null;
  if (!boundedString(message.subject, 1, 200)) return null;
  if (!boundedString(message.text, 1, 100_000)) return null;
  if (!boundedString(message.html, 1, 100_000)) return null;
  if (message.outboxId !== undefined && !boundedString(message.outboxId, 1, 100)) return null;
  if (message.replyTo !== undefined && (!boundedString(message.replyTo, 3, 320) || !emailPattern.test(message.replyTo))) return null;
  if (message.providerProbe !== undefined && typeof message.providerProbe !== "boolean") return null;

  return {
    to: message.to.trim().toLowerCase(),
    subject: message.subject,
    text: message.text,
    html: message.html,
    outboxId: message.outboxId as string | undefined,
    replyTo: message.replyTo as string | undefined,
    providerProbe: message.providerProbe as boolean | undefined,
  };
}
