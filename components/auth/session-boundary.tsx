"use client";
import { useEffect } from "react";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import { accountLogoutDestination } from "@/lib/auth/account-transition";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";

export function SessionBoundary() {
  useEffect(() => {
    const client = createClient();
    if (!client) return;
    let userId: string | null | undefined;
    let leaving = false;
    const privatePath = () => /^\/(?:omgeving|mijn-|admin|app(?:\/|$)|poortenboek)/.test(location.pathname);
    async function changed(destination: string) {
      if (leaving) return;
      leaving = true;
      document.documentElement.dataset.accountChanging = "true";
      clearPrivateSnapshots();
      try { await fetch("/api/poortenboek/logout", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", cache: "no-store", signal: AbortSignal.timeout(4000) }); } catch { /* The next document still revalidates all access. */ }
      window.location.replace(destination);
    }
    const listener = client.auth.onAuthStateChange((event: AuthChangeEvent, session: Session | null) => {
      const nextId = session?.user.id ?? null;
      const previous = userId;
      userId = nextId;
      // Defer work outside the Auth callback to avoid its internal refresh lock.
      if (event === "SIGNED_OUT") {
        clearPrivateSnapshots();
        if (previous && privatePath()) setTimeout(() => void changed(accountLogoutDestination() ?? "/inloggen?next=/omgeving/kiezen"), 0);
      } else if (previous && nextId && previous !== nextId) {
        setTimeout(() => void changed("/omgeving/kiezen"), 0);
      }
    });
    const foreground = () => {
      if (document.visibilityState === "visible") void client.auth.getUser().catch(() => {});
    };
    const hide = () => { if (privatePath()) document.documentElement.dataset.accountChanging = "true"; };
    const restore = (event: PageTransitionEvent) => { if (event.persisted && privatePath()) location.reload(); };
    document.addEventListener("visibilitychange", foreground);
    window.addEventListener("pagehide", hide);
    window.addEventListener("pageshow", restore);
    return () => { listener.data.subscription.unsubscribe(); document.removeEventListener("visibilitychange", foreground); window.removeEventListener("pagehide", hide); window.removeEventListener("pageshow", restore); };
  }, []);
  return null;
}
