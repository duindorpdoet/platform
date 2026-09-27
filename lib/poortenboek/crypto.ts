import "server-only";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import { CODE_ALPHABET, normalizeCode, SESSION_HOURS } from "./model";

export function generateChildCode() {
  return [...randomBytes(6)].map((byte) => CODE_ALPHABET[byte % 32]).join("");
}
export function secretBytes(value: string | undefined) {
  const key = Buffer.from(value ?? "", "base64");
  if (key.length !== 32 || key.toString("base64") !== value)
    throw new Error("Child credential configuration unavailable");
  return key;
}
export function codeDigest(code: string, pepper: string) {
  return createHmac("sha256", secretBytes(pepper))
    .update(`poortenboek-code-v1\0${normalizeCode(code)}`)
    .digest("hex");
}
export function subjectDigest(
  kind: "ip" | "device",
  value: string,
  pepper: string,
) {
  return createHmac("sha256", secretBytes(pepper))
    .update(`poortenboek-${kind}\0${value}`)
    .digest("hex");
}
export function safeDigestEqual(a: string, b: string) {
  if (!/^[a-f0-9]{64}$/.test(a) || !/^[a-f0-9]{64}$/.test(b)) return false;
  return timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex"));
}
export const newSessionToken = () => randomBytes(32).toString("base64url");
export const tokenHash = (token: string) =>
  createHash("sha256").update(token).digest("hex");
export const absoluteExpiry = (createdAt: number) =>
  createdAt + SESSION_HOURS * 60 * 60 * 1000;
export function encryptValue(value: string, key: string, context: string) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", secretBytes(key), nonce);
  cipher.setAAD(Buffer.from(`poortenboek-v1:${context}`));
  const encrypted = Buffer.concat([
    cipher.update(value, "utf8"),
    cipher.final(),
  ]);
  return [
    "v1",
    nonce.toString("base64url"),
    cipher.getAuthTag().toString("base64url"),
    encrypted.toString("base64url"),
  ].join(".");
}
export function decryptValue(envelope: string, key: string, context: string) {
  const [version, iv, tag, payload, extra] = envelope.split(".");
  if (version !== "v1" || !iv || !tag || !payload || extra)
    throw new Error("Invalid encrypted envelope");
  const decipher = createDecipheriv(
    "aes-256-gcm",
    secretBytes(key),
    Buffer.from(iv, "base64url"),
  );
  decipher.setAAD(Buffer.from(`poortenboek-v1:${context}`));
  decipher.setAuthTag(Buffer.from(tag, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(payload, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}
