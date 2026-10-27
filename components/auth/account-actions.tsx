"use client";

import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { LogOut } from "lucide-react";
import { prepareAccountLogout } from "@/lib/auth/account-transition";

export function SignOutButton({ label = "Uitloggen", destination = "/" }: { label?: string; destination?: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function signOut() {
    setBusy(true); setError("");
    clearPrivateSnapshots();
    if ("serviceWorker" in navigator && "PushManager" in window) {
      try {
        const registration = await navigator.serviceWorker.getRegistration();
        const subscription = await registration?.pushManager.getSubscription();
        if (subscription) {
          await fetch("/api/push/subscription", {
            method: "DELETE",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ endpoint: subscription.endpoint }),
            cache: "no-store",
          });
          await subscription.unsubscribe();
        }
      } catch {
        // Uitloggen gaat altijd door; een verlopen endpoint wordt bij aflevering opgeruimd.
      }
    }
    try {
      const child = await fetch("/api/poortenboek/logout", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", cache: "no-store" });
      if (!child.ok) throw new Error("LOGOUT_NOT_CONFIRMED");
      prepareAccountLogout(destination);
      const result = await createClient()?.auth.signOut({ scope: "local" });
      if (result?.error) throw result.error;
    } catch { setError("Uitloggen kon niet worden bevestigd. Maak verbinding en probeer opnieuw."); setBusy(false); return; }
    window.dispatchEvent(new Event("poorten-account-cleared"));
    router.replace(destination);
    router.refresh();
  }
  return <><button className="btn outline account-signout" type="button" disabled={busy} onClick={() => void signOut()}><LogOut size={17} aria-hidden="true" />{busy ? "Uitloggen…" : label}</button>{error && <span role="alert">{error}</span>}</>;
}
