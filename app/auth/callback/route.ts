import { NextResponse } from "next/server";
import { createServerClient, parseCookieHeader, type CookieOptions } from "@supabase/ssr";
import { serverEnv } from "@/lib/config/server-env";
import { safeReturnPath } from "@/lib/auth/redirect";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";
import { AUTH_RETURN_COOKIE, REMEMBER_COOKIE, sessionCookieOptions } from "@/lib/auth/session-lifetime";

export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const url = new URL(request.url);
  const origin = new URL(serverEnv().APP_URL).origin;
  const incoming = parseCookieHeader(request.headers.get("cookie") ?? "").map(cookie => ({ name: cookie.name, value: cookie.value ?? "" }));
  const next = safeReturnPath(url.searchParams.get("next") ?? incoming.find(cookie=>cookie.name===AUTH_RETURN_COOKIE)?.value, "/omgeving/kiezen");
  const remember = incoming.find(cookie => cookie.name === REMEMBER_COOKIE)?.value !== "0";
  const pending: Array<{ name: string; value: string; options: CookieOptions }> = [];
  const config = getPublicSupabaseConfig();
  let success = false;
  if (config && url.searchParams.get("code") && !url.searchParams.has("error")) {
    const client = createServerClient(config.url, config.publishableKey, { cookies: {
      getAll: () => incoming,
      setAll: updates => { for (const update of updates) pending.push({ ...update, options: sessionCookieOptions(update.name, update.options, remember) }); },
    } });
    try {
      const result = await client.auth.exchangeCodeForSession(url.searchParams.get("code")!);
      success = !result.error && Boolean(result.data.session && result.data.user);
    } catch { /* No provider errors, authorization codes or cookies in logs. */ }
  }
  const destination = success ? new URL(next, origin) : new URL("/inloggen", origin);
  if (!success) {
    destination.searchParams.set("error", url.searchParams.get("error") === "access_denied" ? "google_cancelled" : "callback");
    destination.searchParams.set("next", next);
  }
  const response = NextResponse.redirect(destination);
  response.headers.set("Cache-Control", "private, no-store");
  for (const cookie of pending) response.cookies.set(cookie.name, cookie.value, cookie.options);
  response.cookies.set(AUTH_RETURN_COOKIE,"",{path:"/",sameSite:"lax",secure:origin.startsWith("https:"),maxAge:0});
  return response;
}
