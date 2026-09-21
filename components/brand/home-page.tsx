"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { Compass, MapPin } from "lucide-react";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { HomeExperience } from "@/components/poorten-home";
import { faq } from "@/features/content/public-content";

function PrivacySafeMap() {
  return (
    <div className="map-surface map-public-preview" aria-label="Sfeerkaart van Duindorp zonder privé-adressen">
      <svg viewBox="0 0 900 600" preserveAspectRatio="none" aria-hidden="true">
        <defs>
          <pattern id="public-blocks" width="95" height="80" patternUnits="userSpaceOnUse" patternTransform="rotate(-24)">
            <rect width="95" height="80" fill="#0a1620" />
            <rect x="9" y="9" width="77" height="61" rx="3" fill="#132632" stroke="#27404b" />
          </pattern>
        </defs>
        <rect width="900" height="600" fill="url(#public-blocks)" />
        <path d="M0 85L170 0H900V45L650 87 420 140 170 175 0 250Z" fill="#122823" />
        <path d="M-10 410L180 315 420 260 700 115 920 25M120 620L400 410 730 310 960 180" stroke="#37515b" strokeWidth="12" fill="none" />
        <path d="M80 0L390 640M390 0L690 640" stroke="#344655" strokeWidth="8" />
      </svg>
      <span className="map-caption"><Compass size={14} /> Exacte poorten blijven privé</span>
      <span className="north">N</span>
      <span className="you public-area-marker"><MapPin size={15} /><span /> Duindorp</span>
    </div>
  );
}

function HomeFaq() {
  return (
    <Accordion type="single" collapsible className="faq">
      {faq.slice(0, 4).map(([question, answer], index) => (
        <AccordionItem key={question} value={String(index)}>
          <AccordionTrigger>{question}</AccordionTrigger>
          <AccordionContent>{answer}</AccordionContent>
        </AccordionItem>
      ))}
    </Accordion>
  );
}

export function HomePage() {
  const router = useRouter();

  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => entries.forEach((entry) => entry.isIntersecting && entry.target.classList.add("visible")),
      { threshold: 0.08 },
    );
    document.querySelectorAll(".reveal, .chapter").forEach((element) => observer.observe(element));
    return () => observer.disconnect();
  }, []);

  return (
    <HomeExperience
      go={(path) => router.push(path)}
      map={<PrivacySafeMap />}
      faq={<HomeFaq />}
    />
  );
}
