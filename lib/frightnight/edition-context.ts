import "server-only";
import { createHmac, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";
import { serverEnv } from "@/lib/config/server-env";
const COOKIE = "frightnight-edition";
function secret() { const env = serverEnv(); return env.SUPABASE_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? env.CHILD_CODE_ENCRYPTION_KEY; }
export function editionInvitationSecret() { const key = secret(); if (!key) throw new Error("EDITION_CONTEXT_CONFIGURATION"); return `frightnight-test-entry:${key}`; }
export function validTestSlug(slug: string) { return /^frightnight-2027-test(?:-[a-z0-9-]{1,90})?$/.test(slug); }
export async function activeFrightnightSlug(actorId: string) {
  const fallback = serverEnv().EVENT_SLUG;
  const value = (await cookies()).get(COOKIE)?.value;
  const key = secret(); if (!value || !key) return fallback;
  try {
    const [payload, signature] = value.split(".");
    const expected = createHmac("sha256", key).update(payload).digest();
    const received = Buffer.from(signature, "base64url");
    if (expected.length !== received.length || !timingSafeEqual(expected, received)) return fallback;
    const data = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { actor: string; slug: string; expires: number };
    if (data.actor !== actorId || data.expires < Date.now() || !validTestSlug(data.slug)) return fallback;
    return data.slug;
  } catch { return fallback; }
}
export async function selectFrightnightSlug(actorId: string, slug: string) {
  const key = secret(); if (!key || !validTestSlug(slug)) throw new Error("EDITION_CONTEXT_CONFIGURATION");
  const payload = Buffer.from(JSON.stringify({ actor: actorId, slug, expires: Date.now() + 8 * 3600_000 })).toString("base64url");
  const signature = createHmac("sha256", key).update(payload).digest("base64url");
  (await cookies()).set(COOKIE, `${payload}.${signature}`, { httpOnly: true, sameSite: "lax", secure: serverEnv().APP_ENVIRONMENT === "staging", path: "/", maxAge: 8 * 3600 });
  // This hint is only a browser-cache partition, never an authorization source.
  (await cookies()).set("frightnight-edition-cache", `${actorId}:${slug}`, { httpOnly: false, sameSite: "lax", secure: serverEnv().APP_ENVIRONMENT === "staging", path: "/", maxAge: 8 * 3600 });
}
