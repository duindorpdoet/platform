import { PageHeading } from "@/components/brand/public-page";
import { FaqDirectory } from "@/components/brand/faq-directory";
export const metadata = { title: "Veelgestelde vragen · De Duindorpse Poorten", description: "Uitleg over meedoen, samenlopen, het Poortenboek, de Poortkamer, betalen, de app en hulp tijdens Halloween in Duindorp." };
export default function FaqPage() {
  return <div className="wrap page"><PageHeading eyebrow="WE HELPEN JE OP WEG" title="Een antwoord voor iedere avonturier." intro="Voor ouders, kinderen en Poortwachters. Kies een onderwerp of zoek direct naar jouw vraag." /><FaqDirectory /></div>;
}
