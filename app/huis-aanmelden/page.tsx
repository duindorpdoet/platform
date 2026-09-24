import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PortalRegistration } from "@/components/registration/portal-registration";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function PortalRegistrationPage() {
  const actor = await getActor();
  const env = serverEnv();
  const client = await createClient();
  const [publicSnapshot, portalSnapshot] = await Promise.all([
    client?.schema("api").rpc("event_public_snapshot", { _event_slug: env.EVENT_SLUG }),
    actor ? client?.schema("api").rpc("portal_snapshot", { _event_slug: env.EVENT_SLUG }) : null,
  ]);
  const portalRegistrationOpen = (publicSnapshot?.data as { portalRegistrationOpen?: boolean } | null)?.portalRegistrationOpen ?? env.REGISTRATION_MODE !== "closed";
  const hasApplication = Boolean(portalSnapshot?.data?.application);
  const form = portalRegistrationOpen
    ? <PortalRegistration eventSlug={env.EVENT_SLUG} email={actor?.email} hasApplication={hasApplication} />
    : <div className="panel auth-required"><p className="kicker">Aanmelden gepauzeerd</p><h2>Nieuwe plekken kunnen zich nu niet aanmelden.</h2><p>De organisatie opent deze aanmelding weer zodra er ruimte is voor meer woningen, portieken en buurtbedrijven.</p>{hasApplication && <Link className="btn" href="/mijn-huis">Bekijk mijn aanmelding</Link>}</div>;
  return <div className="page wrap"><div className="contact-grid"><div className="page-head"><p className="kicker">Jouw plek · één poort</p><h1>Open een wereld <em>bij jouw deur.</em></h1><p>Van woning en portiek tot winkel of bedrijf: maak van jullie plek een warme, spannende of grappige stop tijdens de Halloween-avond.</p><figure className="editorial-photo house-registration-photo" data-halloween-photo="huis-aanmelden"><img src="/images/06-huis-aanmelden-jouw-deur.webp" srcSet="/images/06-huis-aanmelden-jouw-deur-960.webp 960w, /images/06-huis-aanmelden-jouw-deur.webp 1672w" sizes="(max-width: 700px) calc(100vw - 36px), 52vw" width="1672" height="941" alt="AI-sfeerbeeld van een Duindorpse bakstenen hoekwoning met subtiele Halloweenversiering bij de deur." loading="lazy" decoding="async" /></figure><div className="panel"><h3>Hoe werkt het?</h3><p>Laat hier alleen weten waar jullie zitten en wie we kunnen bereiken. We bewaren meteen een privéconcept en sturen een eenmalige inlogcode. Na bevestiging vul je in Mijn huis de beleving, veiligheid en beschikbaarheid verder aan.</p></div></div>{form}</div></div>;
}
