import "server-only";
import { createHash, createHmac } from "node:crypto";

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function requestHash(value: unknown) {
  return createHash("sha256").update(canonical(value)).digest("hex");
}

export function opaqueSubjectHash(secret: string, ...parts: string[]) {
  return createHmac("sha256", secret).update(parts.map((part) => part.trim().toLowerCase()).join("\u0000")).digest("hex");
}
