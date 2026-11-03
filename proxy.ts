import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/proxy";
import { NextResponse } from "next/server";

export async function proxy(request: NextRequest) {
  if (process.env.FRIGHTNIGHT_ENABLED === "true") {
    const path = request.nextUrl.pathname;
    const destinations: [string, string][] = [["/admin", "/avondregie"], ["/omgeving", "/nachtpas"], ["/mijn-groep", "/nachtpas"], ["/mijn-huis", "/mijn-zone"], ["/huis-aanmelden", "/mijn-zone"], ["/inschrijven", "/nachtpas"], ["/app", "/nachtpas"]];
    const match = destinations.find(([prefix]) => path === prefix || path.startsWith(`${prefix}/`));
    if (match) return NextResponse.redirect(new URL(match[1], request.url));
    const publicDestinations: [string, string][] = [["/verhaal", "/#verhaal"], ["/werelden", "/#tochten"], ["/ontdek", "/#tochten"], ["/kaart", "/#tochten"], ["/deel-de-magie", "/"], ["/sponsoren", "/contact"], ["/meelopen", "/nachtpas"], ["/mijn-inschrijving", "/nachtpas"], ["/poortenboek", "/nachtpas"], ["/nieuws", "/#programma"]];
    const oldPublic = publicDestinations.find(([prefix]) => path === prefix || path.startsWith(`${prefix}/`));
    if (oldPublic) return NextResponse.redirect(new URL(oldPublic[1], request.url));
    // Public festival information and assets stay available when Auth is slow.
    // Refresh sessions on the private entries and authenticated API requests.
    if (["/", "/privacy", "/voorwaarden", "/contact", "/faq", "/toegankelijkheid", "/offline.html", "/api/health", "/api/frightnight/public"].includes(path) || path.startsWith("/frightnight/") || path.startsWith("/maps/") || path.startsWith("/maplibre/")) return NextResponse.next({ request });
  }
  // Child access never creates, refreshes or depends on an adult Auth session.
  if (request.nextUrl.pathname.startsWith("/poortenboek") || request.nextUrl.pathname.startsWith("/api/poortenboek")) return NextResponse.next();
  return updateSession(request);
}

export const config = {
  matcher: ["/((?!_next/|favicon.svg|manifest.webmanifest|sw.js|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
