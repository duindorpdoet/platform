import { ApiError } from "@/lib/http/api";

/** Enforce limits while reading: chunked requests must not bypass the byte cap. */
export async function boundedRequestBytes(request: Request, maximum: number, timeoutMs = 5_000): Promise<Uint8Array> {
  if (Number(request.headers.get("content-length")) > maximum) throw new ApiError(413, "BODY_TOO_LARGE", "Het verzoek bevat te veel gegevens.");
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const parts: Uint8Array[] = [];
  let size = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const cancel = () => { void reader.cancel().catch(() => {}); };
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { reject(new ApiError(408, "BODY_TIMEOUT", "Het verzoek duurde te lang. Probeer opnieuw.")); cancel(); }, timeoutMs);
  });
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      size += value.byteLength;
      if (size > maximum) throw new ApiError(413, "BODY_TOO_LARGE", "Het verzoek bevat te veel gegevens.");
      parts.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
    return bytes;
  } catch (error) { cancel(); throw error; }
  finally { clearTimeout(timer); reader.releaseLock(); }
}

export async function boundedRequestText(request: Request, maximum: number): Promise<string> {
  const bytes = await boundedRequestBytes(request, maximum);
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { throw new ApiError(400, "INVALID_BODY", "Het verzoek bevat geen geldige gegevens."); }
}
