import Link from "next/link";
import { ArrowRight } from "lucide-react";

export const metadata = { title: "Het verhaal · De Duindorpse Poorten" };

const chapters = [
  ["01", "Er brandt vreemd licht.", "Een paarse gloed onder de deur. Blauwe mist over de stoep. Op 31 oktober worden gewone huizen, portieken en buurtzaken poorten naar andere werelden.", 0],
  ["02", "Niet elke wereld is de onze.", "Achter iedere poort wacht iets anders. Soms magisch, soms spannend, maar altijd met een duidelijke keuze om over te slaan.", 4],
  ["03", "De nacht beleef je samen.", "Kinderen, volwassenen en buren maken de route tot één warm wijkverhaal. Poort voor poort, in het tempo van de groep.", 2],
] as const;

export default function StoryPage() {
  return (
    <div className="story-page">
      <div className="story-hero">
        <img src="/images/07-verhaal-wereld-achter-de-deur.webp" srcSet="/images/07-verhaal-wereld-achter-de-deur-960.webp 960w, /images/07-verhaal-wereld-achter-de-deur.webp 1672w" sizes="100vw" width="1672" height="941" alt="AI-sfeerbeeld van een modern Duindorps woonblok met warm licht bij een deur." />
        <div><p className="kicker">HET VERHAAL</p><h1>Werelden achter<br /><em>je voordeur.</em></h1><p>Duindorp. 31 oktober. Zodra de zon verdwijnt,<br />is niets meer zoals het was.</p></div>
      </div>
      <div className="story-chapters wrap">
        {chapters.map(([number, title, copy, image]) => (
          <section className="chapter visible" key={number}>
            <img src={`/images/world-${image}.webp`} alt="" />
            <div><p className="kicker">HOOFDSTUK {number}</p><h2>{title}</h2><p>{copy}</p></div>
          </section>
        ))}
        <div className="center"><h2>Durven jullie de eerste stap te zetten?</h2><Link className="btn" href="/meelopen">Bekijk deelname <ArrowRight /></Link></div>
      </div>
    </div>
  );
}
