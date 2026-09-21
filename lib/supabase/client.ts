"use client";

import { createBrowserClient } from "@supabase/ssr";
import { getPublicSupabaseConfig } from "@/lib/config/public-env";

let client: ReturnType<typeof createBrowserClient> | undefined;

export function createClient() {
  const config = getPublicSupabaseConfig();
  if (!config) return null;
  client ??= createBrowserClient(config.url, config.publishableKey);
  return client;
}
