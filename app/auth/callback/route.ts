import { NextResponse } from "next/server";
import { randomUUID } from "node:crypto";
import { createClient } from "@/lib/supabase/server";
import { safeReturnPath } from "@/lib/auth/redirect";
import { analyticsSurfaceForPath } from "@/lib/analytics/client";
import { serverEnv } from "@/lib/config/server-env";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = safeReturnPath(url.searchParams.get("next"));
  const supabase = await createClient();
  if (code && supabase) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      await supabase.schema("api").rpc("analytics_track", {
        _event_slug: serverEnv().EVENT_SLUG,
        _event_type: "login_completed",
        _surface: analyticsSurfaceForPath(next),
        _session_id: randomUUID(),
        _metadata: {},
      });
      return NextResponse.redirect(new URL(next, url.origin));
    }
  }
  return NextResponse.redirect(new URL("/inloggen?error=callback", url.origin));
}
