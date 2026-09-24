"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { HomeExperience } from "@/components/poorten-home";
import { PublicMap } from "@/components/maps/public-map";
import { faq } from "@/features/content/public-content";

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
      map={<PublicMap compact />}
      faq={<HomeFaq />}
    />
  );
}
