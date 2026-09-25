import Link from "next/link";
import { ArrowUpRight, Flame, House, Palette, ShieldCheck, Sparkles } from "lucide-react";
import { PageHeading } from "@/components/brand/public-page";
import { worlds } from "@/features/content/public-content";

export const metadata = { title: "Werelden · De Duindorpse Poorten" };

export default function WorldsPage() {
  return (
    <div className="wrap page worlds-page">
      <PageHeading eyebrow="ZES HOOFDTHEMA’S. TALLOZE EIGEN VERHALEN." title="Welke wereld durf jij te betreden?" intro="Van zachte magie tot spannende schaduwen: deze zes werelden geven de avond kleur en helpen bezoekers kiezen wat bij hen past." />
      <section className="worlds-guidance panel" aria-labelledby="worlds-guidance-title">
        <div className="worlds-guidance-copy">
          <p className="kicker"><Sparkles size={15} aria-hidden="true" /> RUIMTE VOOR EIGEN FANTASIE</p>
          <h2 id="worlds-guidance-title">Hoofdthema’s ter inspiratie, geen vast draaiboek.</h2>
          <p>De werelden hieronder zijn mogelijke richtingen voor de avond en geen garantie dat iedere wereld of ieder voorbeeld precies zo terugkomt. Elk deelnemend huis kiest zelf een thema, aankleding en verhaal. Een poort mag aansluiten bij een hoofdthema, thema’s combineren of een compleet eigen idee tot leven brengen.</p>
        </div>
        <div className="worlds-guidance-facts">
          <span><Palette aria-hidden="true" /><b>Zes hoofdthema’s</b><small>voor herkenning en inspiratie</small></span>
          <span><House aria-hidden="true" /><b>Ieder huis is vrij</b><small>in thema en uitvoering</small></span>
          <span><Sparkles aria-hidden="true" /><b>Geen vaste belofte</b><small>de echte verrassing volgt op de avond</small></span>
        </div>
      </section>
      <div className="world-grid all-worlds" aria-label="De zes mogelijke hoofdthema’s">
        {worlds.map((world, index) => (
          <Link className="world-card" href={`/werelden/${world.slug}`} key={world.slug} style={{ "--world": world.color } as React.CSSProperties}>
            <img src={`/images/world-${index}.webp`} alt={world.name} />
            <span className="world-no">HOOFDTHEMA {String(index + 1).padStart(2, "0")}</span>
            <span className="world-content"><strong>{world.name}</strong><span>{world.subtitle}</span><span className="world-explore">Ontdek <ArrowUpRight size={16} /></span></span>
            <span className="threat"><Flame size={15} /> {world.intensity}/4</span>
          </Link>
        ))}
      </div>
      <div className="worlds-safety-note"><ShieldCheck size={19} aria-hidden="true" /><p><strong>Iedere poort blijft een verrassing.</strong> Te spannend? Overslaan mag altijd. Jullie plezier en gevoel van veiligheid komen eerst.</p></div>
    </div>
  );
}
