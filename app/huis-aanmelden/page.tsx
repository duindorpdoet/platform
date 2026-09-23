import { createClient } from "@/lib/supabase/server";
import { PortalRegistration } from "@/components/registration/portal-registration";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function PortalRegistrationPage() {
  const actor = await getActor();
  const client = actor ? await createClient() : null;
  const snapshot = client ? await client.schema("api").rpc("portal_snapshot", { _event_slug: serverEnv().EVENT_SLUG }) : null;
  return <div className="page wrap"><div className="contact-grid"><div className="page-head"><p className="kicker">Eén huis · één poort</p><h1>Open een wereld <em>in je portiek.</em></h1><p>Bewoners melden hun eigen huis aan. De organisatie beoordeelt thema, veiligheid, capaciteit en locatie voordat een poort wordt ingepland.</p><div className="panel"><h3>Wat je nodig hebt</h3><p>Begin met je e-mailadres, telefoonnummer, naam en adres. Na de e-mailbevestiging voeg je de beleving, beschikbaarheid en andere huisdetails toe.</p></div></div><PortalRegistration eventSlug={serverEnv().EVENT_SLUG} email={actor?.email} hasApplication={Boolean(snapshot?.data?.application)} /></div></div>;
}
