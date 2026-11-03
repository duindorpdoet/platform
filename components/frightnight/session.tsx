"use client";
import { useEffect } from "react";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";
const ACTOR_KEY = "frightnight-active-actor";
const PRIVATE_PATH = /^\/(nachtpas|mijn-zone|avondregie|testcentrum)(\/|$)/;

export function FrightNightSession() {
  useEffect(() => {
    const client = createClient();
    if (!client) return;
    let identity: string | null | undefined;
    let changing = false;
    let previousActor: string | null = null;
    try { previousActor = sessionStorage.getItem(ACTOR_KEY); } catch { /* Optional identity marker, never an access grant. */ }
    const privatePath = () => PRIVATE_PATH.test(location.pathname);
    const conceal = () => { if (privatePath()) document.documentElement.dataset.accountChanging = "true"; };
    function invalidate(next: string | null) {
      clearPrivateSnapshots();
      window.dispatchEvent(new Event("frightnight:identity-changed"));
      if (!privatePath() || changing) return;
      changing = true; conceal();
      // Navigation stays outside Supabase's synchronous Auth callback and refresh lock.
      setTimeout(() => {
        if (next) location.reload();
        else location.replace("/inloggen?next=" + encodeURIComponent(location.pathname));
      }, 0);
    }
    const { data } = client.auth.onAuthStateChange((event: AuthChangeEvent, session: Session | null) => {
      const next = session?.user.id ?? null;
      const previous = identity === undefined ? previousActor : identity;
      if (event === "SIGNED_OUT") { try { sessionStorage.removeItem("frightnight-pending-test-invite"); } catch { /* Optional transient invitation. */ } }
      if (event === "SIGNED_OUT" || (previous && previous !== next)) invalidate(next);
      try {
        if (next && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) sessionStorage.setItem(ACTOR_KEY, next);
        else sessionStorage.removeItem(ACTOR_KEY);
      } catch { /* Storage refusal never prevents logout or server revalidation. */ }
      identity = next;
    });
    const foreground = () => {
      if (document.visibilityState === "visible") void client.auth.getUser().catch(() => {});
    };
    const restore = (event: PageTransitionEvent) => { if (event.persisted && privatePath()) { conceal(); location.reload(); } };
    window.addEventListener("pagehide", conceal);
    window.addEventListener("pageshow", restore);
    document.addEventListener("visibilitychange", foreground);
    return () => {
      data.subscription.unsubscribe();
      window.removeEventListener("pagehide", conceal);
      window.removeEventListener("pageshow", restore);
      document.removeEventListener("visibilitychange", foreground);
    };
  }, []);
  return null;
}
