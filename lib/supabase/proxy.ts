import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";
import { REMEMBER_COOKIE, sessionCookieOptions } from "@/lib/auth/session-lifetime";

export async function updateSession(request: NextRequest) {
  const config = getPublicSupabaseConfig();
  if (!config) return NextResponse.next({ request });

  let response = NextResponse.next({ request });
  const supabase = createServerClient(config.url, config.publishableKey, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, sessionCookieOptions(name, options, request.cookies.get(REMEMBER_COOKIE)?.value !== "0")));
      },
    },
  });

  try { await supabase.auth.getClaims(); }
  catch { /* A temporary connection failure does not revoke the browser session. */ }
  return response;
}
