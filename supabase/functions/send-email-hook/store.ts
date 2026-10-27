export type Rpc = <T>(name: string, args: Record<string, unknown>) => Promise<T>;

// Native Edge service credentials; never part of a signed browser request.
export function serviceRpc(url: string, secret: string, signal: AbortSignal, fetcher: typeof fetch = fetch): Rpc {
  return async <T>(name: string, args: Record<string, unknown>): Promise<T> => {
    if (!url || !secret) throw new Error("MAIL_STORE_NOT_CONFIGURED");
    const response = await fetcher(`${url.replace(/\/$/, "")}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: secret, Authorization: `Bearer ${secret}`, "Content-Type": "application/json", "Content-Profile": "api", "Accept-Profile": "api" },
      body: JSON.stringify(args), signal,
    });
    if (!response.ok) throw new Error("MAIL_STORE_UNAVAILABLE");
    return await response.json() as T;
  };
}

// Keyed hashes protect low entropy OTPs from offline guesses in database dumps.
export async function mailFingerprint(secret: string, value: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value))), n => n.toString(16).padStart(2, "0")).join("");
}
