import { redirect } from "next/navigation";
import { AdminConsole } from "@/components/admin/admin-console";
import { getActor } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function AdminPage() {
  if (!await getActor()) redirect("/inloggen?next=/admin");
  const client = await createClient();
  const { data } = client ? await client.schema("api").rpc("my_context", { _event_slug: serverEnv().EVENT_SLUG }) : { data: null };
  const capabilities = (data as { capabilities?: string[] } | null)?.capabilities ?? [];
  if (!capabilities.some((capability) => ["event_admin", "registration_manage", "portals_manage", "groups_manage", "live_support"].includes(capability))) redirect("/mijn-inschrijving");
  return <div className="admin-page"><AdminConsole eventSlug={serverEnv().EVENT_SLUG} capabilities={capabilities} /></div>;
}
