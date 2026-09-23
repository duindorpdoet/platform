import { createClient } from "@/lib/supabase/server";
import { PortalRegistration } from "@/components/registration/portal-registration";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function PortalRegistrationPage() {
  const actor = await getActor();
  const client = actor ? await createClient() : null;
  const snapshot = client ? await client.schema("api").rpc("portal_snapshot", { _event_slug: serverEnv().EVENT_SLUG }) : null;
  return <div className="page wrap"><div className="contact-grid"><div className="page-head"><p className="kicker">Jouw plek · één poort</p><h1>Open een wereld <em>bij jouw deur.</em></h1><p>Van woning en portiek tot winkel of bedrijf: maak van jullie plek een warme, spannende of grappige stop tijdens de Halloween-avond.</p><figure className="editorial-photo house-registration-photo" data-halloween-photo="huis-aanmelden"><img src="/images/06-huis-aanmelden-jouw-deur.webp" srcSet="/images/06-huis-aanmelden-jouw-deur-960.webp 960w, /images/06-huis-aanmelden-jouw-deur.webp 1672w" sizes="(max-width: 700px) calc(100vw - 36px), 52vw" width="1672" height="941" alt="AI-sfeerbeeld van een Duindorpse bakstenen hoekwoning met subtiele Halloweenversiering bij de deur." loading="lazy" decoding="async" /></figure><div className="panel"><h3>Hoe werkt het?</h3><p>Laat weten waar jullie zitten en wie we kunnen bereiken. Na de bevestiging werk je het idee rustig uit: kies een thema, vertel wat bezoekers kunnen verwachten en geef aan hoeveel kinderen welkom zijn. Wij helpen jullie op weg.</p></div></div><PortalRegistration eventSlug={serverEnv().EVENT_SLUG} email={actor?.email} hasApplication={Boolean(snapshot?.data?.application)} /></div></div>;
}
