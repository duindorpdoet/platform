import Link from "next/link";
import { Mail } from "lucide-react";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { PageHeading } from "@/components/brand/public-page";
import { faq } from "@/features/content/public-content";

export const metadata = { title: "Veelgestelde vragen · De Duindorpse Poorten" };

export default function FaqPage() {
  return (
    <div className="wrap page">
      <PageHeading eyebrow="WE HELPEN JE OP WEG" title="Alles voor een fijne avond." intro="Heldere antwoorden voor kinderen, ouders, begeleiders, bewoners en ondernemers." />
      <div className="contact-grid">
        <Accordion type="single" collapsible className="faq panel">
          {faq.map(([question, answer], index) => <AccordionItem value={String(index)} key={question}><AccordionTrigger>{question}</AccordionTrigger><AccordionContent>{answer}</AccordionContent></AccordionItem>)}
        </Accordion>
        <aside className="panel"><Mail size={30} /><h2>Nog iets vragen?</h2><p>Twijfel je over de leeftijd, spanning of praktische afspraken? Stuur ons gerust een bericht. We denken graag mee met jullie gezin.</p><Link className="btn outline" href="/contact">Stel je vraag</Link></aside>
      </div>
    </div>
  );
}
