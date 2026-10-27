// Fixed endpoint: credentials must never be forwarded to a configurable host.
export type ResendMessage = {
  from: string;
  to: string[];
  reply_to?: string;
  subject: string;
  text: string;
  html: string;
  headers?: Record<string, string>;
  tags: Array<{ name: string; value: string }>;
};

export type SendResult = {
  status: "accepted" | "unknown" | "deferred" | "failed";
  providerId?: string;
  code?: string;
  retryAfterSeconds?: number;
};

export const providerIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function acceptanceBody(response: Response): Promise<{ id?: unknown } | null> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const chunks: Uint8Array[] = []; let length = 0;
  try {
    while (true) {
      const part = await reader.read(); if (part.done) break;
      length += part.value.byteLength;
      if (length > 8192) { await reader.cancel(); return null; }
      chunks.push(part.value);
    }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch { return null; }
}

export async function sendResend(message: ResendMessage, key: string, apiKey: string, options: { fetcher?: typeof fetch; signal?: AbortSignal } = {}): Promise<SendResult> {
  if (!apiKey) return { status: "failed", code: "RESEND_API_KEY_MISSING" };
  if (!key || key.length > 256 || message.to.length !== 1) return { status: "failed", code: "INVALID_ENVELOPE" };
  let response: Response;
  try {
    response = await (options.fetcher ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(message),
      signal: options.signal ?? AbortSignal.timeout(2500),
    });
    if (response.ok) {
      // A broken success response may follow acceptance. Never create a new key.
      const body = await acceptanceBody(response);
      return typeof body?.id === "string" && providerIdPattern.test(body.id)
        ? { status: "accepted", providerId: body.id }
        : { status: "unknown", code: "RESEND_ACCEPTANCE_UNCERTAIN" };
    }
  } catch {
    return { status: "unknown", code: "RESEND_NETWORK_UNCERTAIN" };
  }
  // Discard provider bodies: they can contain recipients, content or credentials.
  await response.body?.cancel().catch(() => {});
  if (response.status === 429) {
    const raw = response.headers.get("retry-after");
    const seconds = raw && /^\d+$/.test(raw) ? Number(raw) : raw ? Math.ceil((Date.parse(raw) - Date.now()) / 1000) : 60;
    return { status: "deferred", code: "RESEND_RATE_LIMIT", retryAfterSeconds: Number.isFinite(seconds) ? Math.min(86400, Math.max(1, seconds)) : 60 };
  }
  // 5xx and concurrent idempotency conflicts may follow a committed send.
  if (response.status >= 500 || response.status === 409) return { status: "unknown", code: `RESEND_HTTP_${response.status}` };
  if (response.status === 401 || response.status === 403) return { status: "failed", code: "RESEND_CREDENTIALS_OR_DOMAIN" };
  return { status: "failed", code: `RESEND_HTTP_${response.status}` };
}
