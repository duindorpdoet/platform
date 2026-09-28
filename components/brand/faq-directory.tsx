"use client";
import { useState } from "react";
import Link from "next/link";
import { ArrowRight, Search } from "lucide-react";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { faqCategories } from "@/features/content/faq";
export function FaqDirectory() {
  const [query, setQuery] = useState("");
  const normalized = query.trim().toLocaleLowerCase("nl-NL");
  const categories = faqCategories.map(category => ({ ...category, questions: category.questions.filter(item => `${item.question} ${item.answer}`.toLocaleLowerCase("nl-NL").includes(normalized)) })).filter(category => category.questions.length);
  return <div className="faq-directory">
    <aside className="faq-directory-nav"><label className="faq-search"><Search size={18} /><span className="sr-only">Zoek in veelgestelde vragen</span><input type="search" placeholder="Waar zoek je naar?" value={query} onChange={e => setQuery(e.target.value)} /></label><nav aria-label="Onderwerpen">{faqCategories.map(category => <a key={category.id} href={`#${category.id}`}>{category.title}<ArrowRight size={14} /></a>)}</nav><div className="faq-help"><h2>Persoonlijk verder helpen?</h2><p>Open Hulp in je eigen omgeving of stuur ons een bericht.</p><Link className="btn outline" href="/contact">Contact met de organisatie</Link></div></aside>
    <div className="faq-directory-content">{normalized && <p role="status">{categories.reduce((sum, category) => sum + category.questions.length, 0)} antwoorden gevonden</p>}{categories.map(category => <section id={category.id} key={category.id} className="faq-category"><p className="kicker">Goed om te weten</p><h2>{category.title}</h2><p>{category.intro}</p><Accordion type="multiple" className="faq">{category.questions.map(item => <AccordionItem key={item.id} value={item.id}><AccordionTrigger>{item.question}</AccordionTrigger><AccordionContent>{item.answer}</AccordionContent></AccordionItem>)}</Accordion></section>)}</div>
  </div>;
}
