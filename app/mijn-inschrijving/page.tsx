import { redirect } from "next/navigation";
import { RegistrationDashboard } from "@/components/registration/registration-dashboard";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function MyRegistrationPage() {
  const actor = await getActor();
  if (!actor) redirect("/inloggen?next=/mijn-inschrijving");
  return <div className="page wrap"><div className="app-heading row-between"><div><p className="kicker">Persoonlijke omgeving</p><h1>Mijn inschrijving</h1></div><SignOutButton /></div><RegistrationDashboard eventSlug={serverEnv().EVENT_SLUG} /></div>;
}
