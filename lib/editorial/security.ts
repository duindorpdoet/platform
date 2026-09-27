import { createHmac, timingSafeEqual } from "node:crypto";

export type EditorialPurpose = "unsubscribe" | "mail-media";
export function editorialToken(
  secret: string,
  purpose: EditorialPurpose,
  id: string,
): string {
  if (secret.length < 32 || !/^[a-zA-Z0-9-:]{36,110}$/.test(id))
    throw new Error("Invalid editorial token configuration");
  const payload = Buffer.from(id).toString("base64url");
  return `v1.${payload}.${createHmac("sha256", secret).update(`editorial:${purpose}:v1:${payload}`).digest("base64url")}`;
}
export function verifyEditorialToken(
  secret: string,
  purpose: EditorialPurpose,
  token: string,
): string | null {
  if (secret.length < 32 || token.length > 240) return null;
  const [version, payload, signature, extra] = token.split(".");
  if (
    version !== "v1" ||
    !payload ||
    !signature ||
    !/^[A-Za-z0-9_-]{43}$/.test(signature) ||
    extra !== undefined ||
    !/^[A-Za-z0-9_-]+$/.test(payload)
  )
    return null;
  const expected = createHmac("sha256", secret)
    .update(`editorial:${purpose}:v1:${payload}`)
    .digest();
  const given = Buffer.from(signature, "base64url");
  if (given.length !== expected.length || !timingSafeEqual(given, expected))
    return null;
  const id = Buffer.from(payload, "base64url").toString();
  return /^[a-zA-Z0-9-:]{36,110}$/.test(id) ? id : null;
}
export function editorialRecipientAllowed(
  environment: string,
  recipient: string,
  allowlist: Set<string>,
): boolean {
  return (
    environment === "production" ||
    allowlist.has(recipient.trim().toLowerCase())
  );
}
export function safeNewsDeepLink(input: string): string {
  return /^\/omgeving\/nieuws\/[a-z0-9]+(?:-[a-z0-9]+)*(?:\?push=[a-f0-9-]{36}(?:&device=[a-f0-9-]{36})?)?$/.test(
    input,
  )
    ? input
    : "/omgeving";
}
