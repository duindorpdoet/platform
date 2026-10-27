import type { CookieOptions } from "@supabase/ssr";

export const REMEMBER_COOKIE = "poorten-remember";
export const AUTH_RETURN_COOKIE = "poorten-auth-next";
export const REMEMBER_SECONDS = 30 * 24 * 60 * 60;

export function sessionCookieOptions(name: string, options: CookieOptions, remember: boolean): CookieOptions {
  if (!name.includes("-auth-token") || options.maxAge === 0) return options;
  return { ...options, path: "/", sameSite: "lax", maxAge: remember ? REMEMBER_SECONDS : undefined, expires: undefined };
}
