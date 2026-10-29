import Link from "next/link";
import { RegistrationWizard } from "@/components/registration/registration-wizard";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { registrationChannelIsOpen } from "@/lib/config/registration-mode";
import { createClient } from "@/lib/supabase/server";
import {RegistrationAuth} from '@/components/auth/registration-auth';
import {googleAvailability} from '@/lib/auth/providers';

export const dynamic = "force-dynamic";

export default async function RegistrationPage() {
  const actor = await getActor();
  const env = serverEnv();
  const client = await createClient();
  const publicSnapshot = client ? await client.schema("api").rpc("event_public_snapshot", { _event_slug: env.EVENT_SLUG }) : null;
  const groupRegistrationOpen = registrationChannelIsOpen(
    env.REGISTRATION_MODE,
    (publicSnapshot?.data as { groupRegistrationOpen?: boolean } | null)?.groupRegistrationOpen,
  );
  const registrationPanel = groupRegistrationOpen
    ? actor
      ? <RegistrationWizard eventSlug={env.EVENT_SLUG} canSubmit />
      : <RegistrationAuth googleAvailable={await googleAvailability()} />
    : <div className="panel auth-required"><p className="kicker">Inschrijvingen gesloten</p><h2>De inschrijvingen zijn gesloten.</h2><p>Nieuwe deelnemers kunnen zich niet meer aanmelden voor de Halloweenavond. Ben je al ingeschreven? Je kunt je inschrijving blijven bekijken in je persoonlijke omgeving.</p>{actor && <div className="actions"><Link className="btn outline" href="/mijn-inschrijving">Bekijk mijn inschrijving</Link></div>}</div>;
  return <div className="page wrap registration-page"><section className="registration-intro"><p className="kicker">Loop mee · 31 oktober 2026</p><h1>Word onderdeel van <em>het verhaal.</em></h1><p>Voor €2,50 per kind trekken jullie door een Duindorp vol lichtjes, iets lekkers en verrassende werelden. Met die bijdrage verdelen we snoep onder deelnemende huizen waar nodig. Een volwassene loopt gratis mee. De avond is van 17:00 tot 21:00 uur; jullie geven zelf start- en eindvoorkeuren door.</p><div className="registration-facts"><p><strong>Voor kinderen:</strong> spannende én rustige poorten.</p><p><strong>Voor ouders:</strong> een overzichtelijke avond met een vaste groep.</p><p><strong>Samen:</strong> verkleed komen, ontdekken en herinneringen maken.</p></div><figure className="editorial-photo registration-photo" data-halloween-photo="meelopen"><img src="/images/05-meelopen-samen-op-pad.webp" srcSet="/images/05-meelopen-samen-op-pad-960.webp 960w, /images/05-meelopen-samen-op-pad.webp 1672w" sizes="(max-width: 700px) calc(100vw - 36px), 45vw" width="1672" height="941" alt="AI-sfeerbeeld van een fictieve begeleide wandelgroep langs okergele Duindorpse gevels." loading="lazy" decoding="async" /></figure></section>{registrationPanel}</div>;
}
