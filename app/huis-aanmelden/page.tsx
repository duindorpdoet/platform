import { createClient } from "@/lib/supabase/server";
import { PortalRegistration } from "@/components/registration/portal-registration";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function PortalRegistrationPage() {
  const actor = await getActor();
  const client = actor ? await createClient() : null;
  const snapshot = client ? await client.schema("api").rpc("portal_snapshot", { _event_slug: serverEnv().EVENT_SLUG }) : null;
  return <div className="page wrap"><div className="contact-grid"><div className="page-head"><p className="kicker">Eén huis · één poort</p><h1>Open een wereld <em>in je portiek.</em></h1><p>Maak van jullie huis een warme, spannende of grappige stop tijdens de Halloween-avond. Kinderen ontdekken jullie poort samen met hun groep.</p><div className="panel"><h3>Hoe werkt het?</h3><p>1. Geef je e-mailadres, telefoonnummer, naam en adres. 2. Bevestig je e-mailadres. 3. Kies daarna een thema en vertel hoe jullie poort eruitziet. Wij helpen jullie op weg.</p></div></div><PortalRegistration eventSlug={serverEnv().EVENT_SLUG} email={actor?.email} hasApplication={Boolean(snapshot?.data?.application)} /></div></div>;
}
