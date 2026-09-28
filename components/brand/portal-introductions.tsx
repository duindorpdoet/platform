import Image from "next/image";
import Link from "next/link";
import { ArrowRight, BookOpen, Check, DoorOpen } from "lucide-react";
export function PortalIntroductions() {
  return <section className="home-portals wrap" aria-labelledby="home-portals-title">
    <div className="home-portals-heading"><p className="kicker">De voorpret reist met je mee</p><h2 id="home-portals-title">Een eigen boek.<br /><em>Een kamer achter de poort.</em></h2><p>De avond begint al thuis. Kinderen ontdekken hun avontuur in het Poortenboek. Bewoners bereiden hun poort samen voor in de Poortkamer.</p></div>
    <div className="home-portal-grid">
      <article className="home-portal-card"><Image src="/images/poortenboek-v2/passport-cover.webp" width={900} height={540} alt="Een magisch Poortenboek tussen de verlichte straten" /><div><p className="kicker">Voor ieder ingeschreven kind</p><h3>Het Poortenboek</h3><p>Kies je verschijning en lantaarn, geef met je reisgenootjes jullie team een naam en verzamel de verhalen van de nacht.</p><ul><li><Check />Een eigen boek met je voornaam</li><li><Check />Samen een teamnaam en vaandel kiezen</li><li><Check />Poortzegels, hoofdstukken en een bewaarkaart</li></ul><div className="actions"><Link href="/poortenboek/inloggen" className="btn"><BookOpen size={18} />Open je Poortenboek</Link><Link href="/ontdek#poortenboek" className="text-link">Zo werkt het <ArrowRight size={16} /></Link></div></div></article>
      <article className="home-portal-card"><Image src="/images/poortkamer-v2/house-team-hero-wide.webp" width={900} height={540} alt="De warme ontmoetingsplek van een poortteam" /><div><p className="kicker">Voor bewoners en hun poortteam</p><h3>De Poortkamer</h3><p>Maak jullie poort samen klaar. Spreek af in de teamchat, wissel tips uit in de Praatkamer en zie tijdens de avond wie er onderweg is.</p><ul><li><Check />Je team uitnodigen en taken verdelen</li><li><Check />Chat, nieuws en updates van de organisatie</li><li><Check />Verwachte groepen en Open, Pauze of Gestopt</li></ul><div className="actions"><Link href="/mijn-huis" className="btn"><DoorOpen size={18} />Naar je Poortkamer</Link><Link href="/ontdek#poortkamer" className="text-link">Ontdek meer <ArrowRight size={16} /></Link></div></div></article>
    </div>
    <p className="home-portals-note">Geen eigen telefoon voor je kind nodig. Open elk Poortenboek rechtstreeks vanuit je ouderaccount.</p>
  </section>;
}
