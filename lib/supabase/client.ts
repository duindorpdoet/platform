"use client";

import { createBrowserClient, parseCookieHeader, serializeCookieHeader } from "@supabase/ssr";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";
import { AUTH_RETURN_COOKIE, REMEMBER_COOKIE, REMEMBER_SECONDS, sessionCookieOptions } from "@/lib/auth/session-lifetime";
import { safeReturnPath } from "@/lib/auth/redirect";

let client: ReturnType<typeof createBrowserClient> | undefined;

export function createClient() {
  const config = getPublicSupabaseConfig();
  if (!config) return null;
  client ??= createBrowserClient(config.url, config.publishableKey, { cookies: {
    getAll: () => typeof document === "undefined" ? [] : parseCookieHeader(document.cookie).map(cookie => ({ name: cookie.name, value: cookie.value ?? "" })),
    setAll: cookies => {
      if (typeof document === "undefined") return;
      const remember = parseCookieHeader(document.cookie).find(cookie => cookie.name === REMEMBER_COOKIE)?.value !== "0";
      for (const cookie of cookies) document.cookie = serializeCookieHeader(cookie.name, cookie.value, sessionCookieOptions(cookie.name, cookie.options, remember));
    },
  } });
  return client;
}

export function setSessionRememberPreference(remember: boolean) {
  document.cookie = serializeCookieHeader(REMEMBER_COOKIE, remember ? "1" : "0", { path: "/", sameSite: "lax", secure: location.protocol === "https:", maxAge: remember ? REMEMBER_SECONDS : undefined });
}
export function setAuthReturnDestination(path: string) {
  document.cookie=serializeCookieHeader(AUTH_RETURN_COOKIE,safeReturnPath(path,"/omgeving/kiezen"),{path:"/",sameSite:"lax",secure:location.protocol==="https:",maxAge:600});
}
