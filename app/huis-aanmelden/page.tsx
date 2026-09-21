import Link from "next/link";
import { PortalWizard } from "@/components/registration/portal-wizard";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function PortalRegistrationPage() {
  const actor = await getActor();
  return <div className="page wrap"><div className="contact-grid"><div className="page-head"><p className="kicker">Eén huis · één poort</p><h1>Open een wereld <em>in je portiek.</em></h1><p>Bewoners melden hun eigen huis aan. De organisatie beoordeelt thema, veiligheid, capaciteit en locatie voordat een poort wordt ingepland.</p><div className="panel"><h3>Wat je nodig hebt</h3><p>Een volwassen contactpersoon, toestemming voor het adres, beschikbaarheid op de avond en een plan dat veilig blijft voor kinderen en buren.</p></div></div>{actor ? <PortalWizard eventSlug={serverEnv().EVENT_SLUG} /> : <div className="panel auth-required"><h2>Eerst veilig inloggen</h2><p>Zo blijft je adres uit openbare formulieren en URL’s.</p><Link className="btn" href="/inloggen?next=/huis-aanmelden">Inloggen met e-mailcode</Link></div>}</div></div>;
}
