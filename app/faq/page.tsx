import Link from "next/link";
import { Mail } from "lucide-react";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { PageHeading } from "@/components/brand/public-page";
import { faq } from "@/features/content/public-content";

export const metadata = { title: "Veelgestelde vragen · De Duindorpse Poorten" };

export default function FaqPage() {
  return (
    <div className="wrap page">
      <PageHeading eyebrow="WE HELPEN JE OP WEG" title="Een antwoord op je vragen." intro="Praktische informatie voor kinderen, begeleiders en bewoners." />
      <div className="contact-grid">
        <Accordion type="single" collapsible className="faq panel">
          {faq.map(([question, answer], index) => <AccordionItem value={String(index)} key={question}><AccordionTrigger>{question}</AccordionTrigger><AccordionContent>{answer}</AccordionContent></AccordionItem>)}
        </Accordion>
        <aside className="panel"><Mail size={30} /><h2>Nog iets vragen?</h2><p>Stuur de organisatie een bericht. Opslag lukt ook als de mailprovider tijdelijk niet beschikbaar is.</p><Link className="btn outline" href="/contact">Neem contact op</Link></aside>
      </div>
    </div>
  );
}
