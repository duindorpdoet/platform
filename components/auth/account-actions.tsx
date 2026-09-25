"use client";

import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { LogOut } from "lucide-react";

export function SignOutButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  async function signOut() {
    setBusy(true);
    clearPrivateSnapshots();
    if ("serviceWorker" in navigator && "PushManager" in window) {
      try {
        const registration = await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.getSubscription();
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
    await createClient()?.auth.signOut();
    router.replace("/");
    router.refresh();
  }
  return <button className="btn outline account-signout" type="button" disabled={busy} onClick={() => void signOut()}><LogOut size={17} aria-hidden="true" />{busy ? "Uitloggen…" : "Uitloggen"}</button>;
}
