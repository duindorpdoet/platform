import { createHmac, timingSafeEqual } from "node:crypto";
const TTL = 8 * 3600_000;
const slugPattern = /^frightnight-2027-test(?:-[a-z0-9-]{1,90})?$/;
export function createEditionInvitation(slug: string, secret: string, now = Date.now()) {
  if (!slugPattern.test(slug) || secret.length < 24) throw new Error("INVITATION_CONFIGURATION");
  const expiresAt = now + TTL;
  const payload = Buffer.from(JSON.stringify({ purpose: "frightnight-test-entry", slug, expiresAt })).toString("base64url");
  const signature = createHmac("sha256", secret).update(payload).digest("base64url");
  return { token: `${payload}.${signature}`, expiresAt: new Date(expiresAt).toISOString() };
}
export function verifyEditionInvitation(token: string, secret: string, now = Date.now()): string | null {
  if (token.length > 1024 || secret.length < 24) return null;
  try {
    const [payload, signature, extra] = token.split(".");
    if (!payload || !signature || extra) return null;
    const expected = createHmac("sha256", secret).update(payload).digest();
    const actual = Buffer.from(signature, "base64url");
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return null;
    const data = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return data.purpose === "frightnight-test-entry" && typeof data.slug === "string" && slugPattern.test(data.slug) && Number.isSafeInteger(data.expiresAt) && data.expiresAt > now && data.expiresAt <= now + TTL ? data.slug : null;
  } catch { return null; }
}
