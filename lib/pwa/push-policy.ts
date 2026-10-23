export const PUSH_SECURITY_POLICY = Object.freeze({
  maxDevicesPerAccount: 5, writesPerMinute: 10, maxBatchTargets: 20,
  concurrency: 3, attemptTimeoutMs: 2_000, batchTimeoutMs: 8_000, maxEndpointLength: 4_096,
});
export const PUSH_PROVIDER_HOSTS = Object.freeze([
  "fcm.googleapis.com", "updates.push.services.mozilla.com", "web.push.apple.com",
]);

/** Exact origins, before any DNS or network operation. Never include input in errors. */
export function validatePushEndpoint(value: unknown): string | null {
  if (typeof value !== "string" || !value || value.length > PUSH_SECURITY_POLICY.maxEndpointLength
    || /[\s\u0000-\u0020\u007f\\]/u.test(value) || /%(?:0[0-9a-f]|1[0-9a-f]|20|5c|7f)/i.test(value)) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash
      || (url.port && url.port !== "443") || !PUSH_PROVIDER_HOSTS.includes(url.hostname)
      || url.pathname === "/" || !url.pathname || /[?#]/.test(value)) return null;
    return url.href;
  } catch { return null; }
}

export function validPushKeyShape(value: unknown, bytes: number) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return false;
  try {
    const decoded = Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
    return decoded.byteLength === bytes && (bytes !== 65 || decoded[0] === 4)
      && btoa(String.fromCharCode(...decoded)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"")===value;
  } catch { return false; }
}
