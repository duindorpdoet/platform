import "server-only";
import { createClient } from "@/lib/supabase/server";

export type AuthenticatedActor = { userId: string; email?: string };

export async function getActor(): Promise<AuthenticatedActor | null> {
  const supabase = await createClient();
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getClaims();
  const claims = data?.claims;
  if (error || !claims?.sub) return null;
  return { userId: claims.sub, email: typeof claims.email === "string" ? claims.email : undefined };
}
