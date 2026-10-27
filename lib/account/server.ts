import "server-only";
import { ApiError } from "@/lib/http/api";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import type { AccountSnapshot } from "./model";

export async function accountClient() {
  const client = await createClient();
  if (!client) throw new ApiError(503, "ACCOUNT_UNAVAILABLE", "Inloggen is tijdelijk niet bereikbaar.");
  const result = await client.auth.getUser();
  if (result.error && result.error.status !== 401 && result.error.status !== 403 && result.error.name !== "AuthSessionMissingError") {
    throw new ApiError(503, "ACCOUNT_UNAVAILABLE", "Maak verbinding om je account veilig te controleren.");
  }
  if (!result.data.user || result.error) throw new ApiError(401, "NOT_AUTHORIZED", "Log opnieuw in.");
  return { client, user: result.data.user };
}

export async function accountSnapshot(): Promise<AccountSnapshot> {
  const { client } = await accountClient();
  const result = await client.schema("api").rpc("account_app_snapshot", { _event_slug: serverEnv().EVENT_SLUG });
  if (result.error || !result.data) throw new ApiError(503, "ACCOUNT_UNAVAILABLE", "Je gekoppelde omgevingen konden niet worden opgehaald. Probeer opnieuw.");
  return result.data as AccountSnapshot;
}
