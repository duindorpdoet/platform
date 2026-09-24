import { redirect } from "next/navigation";
import { PortalDashboard } from "@/components/portal/portal-dashboard";
import { SupportWidget } from "@/components/support/support-widget";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function MyPortalPage() {
  if (!await getActor()) redirect("/inloggen?next=/mijn-huis");
  const eventSlug = serverEnv().EVENT_SLUG;
  const client = await createClient();
  const { data } = client ? await client.schema("api").rpc("my_context", { _event_slug: eventSlug }) : { data: null };
  const portalId = ((data as { portalIds?: string[] } | null)?.portalIds ?? [])[0];
  return <><div className="page wrap"><div className="app-heading row-between"><div><p className="kicker">Poortomgeving</p><h1>Mijn plek</h1></div><SignOutButton /></div><PortalDashboard eventSlug={eventSlug} /></div>{portalId && <SupportWidget eventSlug={eventSlug} role="homeowner" portalId={portalId} />}</>;
}
