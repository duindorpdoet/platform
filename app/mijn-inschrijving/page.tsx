import { redirect } from "next/navigation";
import { RegistrationDashboard } from "@/components/registration/registration-dashboard";
import { SupportWidget } from "@/components/support/support-widget";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function MyRegistrationPage({ searchParams }: { searchParams: Promise<{ uitnodiging?: string }> }) {
  const inviteToken = (await searchParams).uitnodiging;
  const safeInviteToken = inviteToken && /^[a-f0-9]{64}$/.test(inviteToken) ? inviteToken : undefined;
  const actor = await getActor();
  if (!actor) {
    const destination = safeInviteToken ? `/mijn-inschrijving?uitnodiging=${safeInviteToken}` : "/mijn-inschrijving";
    redirect(`/inloggen?next=${encodeURIComponent(destination)}`);
  }
  const eventSlug = serverEnv().EVENT_SLUG;
  return <><div className="page wrap registration-account-page"><div className="app-heading row-between"><div><p className="kicker">Persoonlijke omgeving</p><h1>Mijn inschrijving</h1></div><SignOutButton /></div><RegistrationDashboard eventSlug={eventSlug} inviteToken={safeInviteToken} /></div><SupportWidget eventSlug={eventSlug} role="user" /></>;
}
