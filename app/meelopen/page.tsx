import Link from "next/link";
import { RegistrationWizard } from "@/components/registration/registration-wizard";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function RegistrationPage() {
  const actor = await getActor();
  const env = serverEnv();
  return <div className="page wrap registration-page"><section className="registration-intro"><p className="kicker">Loop mee · 31 oktober 2026</p><h1>Word onderdeel van <em>het verhaal.</em></h1><p>Voor €2 per kind trekken jullie door een Duindorp vol lichtjes, iets lekkers en verrassende werelden. Een volwassene loopt mee en jullie bepalen samen wat goed voelt.</p><div className="registration-facts"><p><strong>Voor kinderen:</strong> spannende én rustige poorten.</p><p><strong>Voor ouders:</strong> een overzichtelijke avond met een vaste groep.</p><p><strong>Samen:</strong> verkleed komen, ontdekken en herinneringen maken.</p></div><figure className="editorial-photo registration-photo" data-halloween-photo="meelopen"><img src="/images/05-meelopen-samen-op-pad.webp" srcSet="/images/05-meelopen-samen-op-pad-960.webp 960w, /images/05-meelopen-samen-op-pad.webp 1672w" sizes="(max-width: 700px) calc(100vw - 36px), 45vw" width="1672" height="941" alt="AI-sfeerbeeld van een fictieve begeleide wandelgroep langs okergele Duindorpse gevels." loading="lazy" decoding="async" /></figure></section>{actor ? <RegistrationWizard eventSlug={env.EVENT_SLUG} canSubmit={env.REGISTRATION_MODE !== "closed"} /> : <div className="panel auth-required"><h2>Klaar voor het avontuur?</h2><p>Log in met je e-mailadres. Daarna vul je rustig jullie gezin en deelnemende kinderen in.</p><Link className="btn" href="/inloggen?next=/meelopen">Start met inschrijven</Link>{env.REGISTRATION_MODE === "closed" && <p className="note">De inschrijving opent zodra de avond en groepen definitief zijn.</p>}</div>}</div>;
}
