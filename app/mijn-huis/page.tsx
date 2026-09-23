import { redirect } from "next/navigation";
import { PortalDashboard } from "@/components/portal/portal-dashboard";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function MyPortalPage() {
  if (!await getActor()) redirect("/inloggen?next=/mijn-huis");
  return <div className="page wrap"><div className="app-heading row-between"><div><p className="kicker">Poortomgeving</p><h1>Mijn plek</h1></div><SignOutButton /></div><PortalDashboard eventSlug={serverEnv().EVENT_SLUG} /></div>;
}
