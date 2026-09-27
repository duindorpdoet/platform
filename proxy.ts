import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/proxy";
import { NextResponse } from "next/server";

export async function proxy(request: NextRequest) {
  // Child access never creates, refreshes or depends on an adult Auth session.
  if (request.nextUrl.pathname.startsWith("/poortenboek") || request.nextUrl.pathname.startsWith("/api/poortenboek")) return NextResponse.next();
  return updateSession(request);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.svg|manifest.webmanifest|sw.js|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
