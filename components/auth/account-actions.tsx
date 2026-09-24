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
    await createClient()?.auth.signOut();
    router.replace("/");
    router.refresh();
  }
  return <button className="btn outline account-signout" type="button" disabled={busy} onClick={() => void signOut()}><LogOut size={17} aria-hidden="true" />{busy ? "Uitloggen…" : "Uitloggen"}</button>;
}
