import "server-only";
import { createClient } from "@supabase/supabase-js";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";
import { serverEnv } from "@/lib/config/server-env";

export function createPrivilegedClient() {
  const publicConfig = getPublicSupabaseConfig();
  const env = serverEnv();
  const secret = env.SUPABASE_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY;
  if (!publicConfig || !secret) return null;
  return createClient(publicConfig.url, secret, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
