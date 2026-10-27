import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";
import { REMEMBER_COOKIE, sessionCookieOptions } from "@/lib/auth/session-lifetime";

export async function createClient() {
  const config = getPublicSupabaseConfig();
  if (!config) return null;
  const cookieStore = await cookies();
  return createServerClient(config.url, config.publishableKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, sessionCookieOptions(name, options, cookieStore.get(REMEMBER_COOKIE)?.value !== "0")));
        } catch {
          // Server Components mogen geen cookies schrijven; proxy.ts verzorgt refresh.
        }
      },
    },
  });
}
