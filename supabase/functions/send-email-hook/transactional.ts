export type TransactionalHookMessage = {
  to: string;
  subject: string;
  text: string;
  html: string;
  outboxId?: string;
  replyTo?: string;
  providerProbe?: boolean;
  editorial?: boolean;
  senderName?: string;
  unsubscribeUrl?: string;
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
  if (
    candidate.kind !== "transactional" ||
    !candidate.message ||
    typeof candidate.message !== "object"
  ) {
    return null;
  }

  const message = candidate.message as Record<string, unknown>;

  const to =
    typeof message.to === "string"
      ? message.to.trim().toLowerCase()
      : "";

  const replyTo =
    typeof message.replyTo === "string"
      ? message.replyTo.trim().toLowerCase()
      : undefined;

  if (!boundedString(to, 3, 320) || !emailPattern.test(to)) return null;
  if (!boundedString(message.subject, 1, 200)) return null;
  if (!boundedString(message.text, 1, 100_000)) return null;
  if (!boundedString(message.html, 1, 100_000)) return null;

  if (
    message.outboxId !== undefined &&
    !boundedString(message.outboxId, 1, 100)
  ) {
    return null;
  }

  if (
    message.replyTo !== undefined &&
    (!replyTo || !boundedString(replyTo, 3, 320) || !emailPattern.test(replyTo))
  ) {
    return null;
  }

  if (
    message.providerProbe !== undefined &&
    typeof message.providerProbe !== "boolean"
  ) {
    return null;
  }

  if (message.editorial !== undefined && typeof message.editorial !== "boolean") return null;
  if (message.senderName !== undefined && (!boundedString(message.senderName, 1, 120) || /[\r\n]/.test(message.senderName))) return null;
  if (message.unsubscribeUrl !== undefined) {
    if (!boundedString(message.unsubscribeUrl, 1, 2000)) return null;
    try {
      const url = new URL(message.unsubscribeUrl);
      if (url.protocol !== "https:" || url.username || url.password || /[\r\n]/.test(message.unsubscribeUrl)) return null;
    } catch { return null; }
  }
  return {
    ...(message.editorial === true ? { editorial: true, senderName: message.senderName as string | undefined, unsubscribeUrl: message.unsubscribeUrl as string | undefined } : {}),
    to,
    subject: message.subject,
    text: message.text,
    html: message.html,
    outboxId: message.outboxId as string | undefined,
    replyTo,
    providerProbe: message.providerProbe as boolean | undefined,
  };
}
