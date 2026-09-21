"use client";

import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots } from "@/lib/pwa/private-snapshot";
import { useRouter } from "next/navigation";

export function SignOutButton() {
  const router = useRouter();
  async function signOut() {
    clearPrivateSnapshots();
    await createClient()?.auth.signOut();
    router.replace("/");
    router.refresh();
  }
  return <button className="btn outline" type="button" onClick={() => void signOut()}>Uitloggen</button>;
}
