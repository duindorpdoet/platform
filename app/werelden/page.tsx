import Link from "next/link";
import { ArrowUpRight, Flame, ShieldCheck } from "lucide-react";
import { PageHeading } from "@/components/brand/public-page";
import { worlds } from "@/features/content/public-content";

export const metadata = { title: "Werelden · De Duindorpse Poorten" };

export default function WorldsPage() {
  return (
    <div className="wrap page">
      <PageHeading eyebrow="ZES WERELDEN. TALLOZE POORTEN." title="Welke wereld durf jij te betreden?" intro="Van zachte magie tot spannende schaduwen: ontdek de zes thema’s en kies samen wat bij jullie past." />
      <div className="all-worlds">
        {worlds.map((world, index) => (
          <Link className="world-card" href={`/werelden/${world.slug}`} key={world.slug} style={{ "--world": world.color } as React.CSSProperties}>
            <img src={`/images/world-${index}.webp`} alt={world.name} />
            <span className="world-no">WERELD {String(index + 1).padStart(2, "0")}</span>
            <span className="world-content"><strong>{world.name}</strong><span>{world.subtitle}</span><span className="world-explore">Ontdek <ArrowUpRight size={16} /></span></span>
            <span className="threat"><Flame size={15} /> {world.intensity}/4</span>
          </Link>
        ))}
      </div>
      <p className="note"><ShieldCheck size={17} /> Te spannend? Overslaan mag altijd. Jullie plezier en gevoel van veiligheid komen eerst.</p>
    </div>
  );
}
