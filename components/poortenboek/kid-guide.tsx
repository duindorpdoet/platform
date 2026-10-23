"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { Dialog as Primitive } from "radix-ui";
import { ArrowLeft, ArrowRight, BookOpen, Check, HelpCircle, Sparkles, X } from "lucide-react";
import type { BookSection, BookSnapshot } from "@/lib/poortenboek/model";
import "../../modern/book-kid-guide.css";

const VERSION = 1;
type TutorialSnapshot = BookSnapshot & { childId?: string; tutorial?: { version: number; completedAt: string | null; lastStep?: number } };
type Step = { label: string; title: string; copy: string; tip: string; path: string; target: string; teamTab?: string; profileTab?: string };
const steps: Step[] = [
  { label: "Welkom", title: "Dit boek is van jou!", copy: "Hier begint jouw avontuur door Duindorp. We kijken samen waar alles staat.", tip: "Je hoeft nog niets te kiezen. Dat mag straks rustig met een volwassene erbij.", path: "/poortenboek", target: ".pb-hero" },
  { label: "Jouw team", title: "Je gaat samen op pad", copy: "In Team ontmoet je jouw reisgenootjes. Daar mag je ook stemmen op jullie teamnaam.", tip: "De naam is pas gekozen als de stemronde klaar is. Vraag gerust hulp bij het lezen.", path: "/poortenboek/team", target: ".pb-team-hero, .pb-companions", teamTab: "friends" },
  { label: "Jouw licht", title: "Kies jouw verschijning", copy: "Bij Ik kies je een avonturenrol en een mooie lantaarn. Probeer een vorm en kleur en bewaar wat jij het mooist vindt.", tip: "Het is jouw keuze. Er bestaat geen verkeerde kleur!", path: "/poortenboek/ik", target: ".pb-v2-workshop", profileTab: "appearance" },
  { label: "Jullie vaandel", title: "Maak samen iets bijzonders", copy: "In Team stemmen jullie op kleuren en tekens voor het vaandel. Zo krijgt jullie groep een eigen herkenbaar symbool.", tip: "Jouw stem telt mee. De uiteindelijke keuze kan anders zijn dan jouw eigen favoriet.", path: "/poortenboek/team", target: ".pb-v2-banner-workshop, .pb-v2-workshop", teamTab: "banner" },
  { label: "Eerst oefenen", title: "Open de oefenpoort", copy: "Bij de Oefenpoort mag je de magie alvast proberen. Houd de knop even vast en kijk wat er gebeurt.", tip: "Het oefenzegel is voor de voorpret. Een echte poortzegel krijg je tijdens de tocht.", path: "/poortenboek/team", target: ".pb-practice", teamTab: "practice" },
  { label: "Jouw verhaal", title: "Lees wat er achter de poorten gebeurt", copy: "In Mijn boek vind je de hoofdstukken van jouw verhaal. Een wakker hoofdstuk kun je openen en lezen.", tip: "Sommige hoofdstukken slapen nog. Ze worden tijdens jouw avontuur wakker.", path: "/poortenboek/boek", target: ".pb-story-library" },
  { label: "Jouw zegels", title: "Bij iedere aankomst een zegel", copy: "Kom je met je groep bij een poort aan? Na de scan krijg je een zegel, ook als je buiten blijft.", tip: "Je hoeft niet naar binnen of mee te doen als je dat spannend vindt. Vertel het aan je volwassene en blijf bij elkaar.", path: "/poortenboek/boek", target: ".pb-v2-passport" },
  { label: "Voor vertrek", title: "Ben je klaar voor de nacht?", copy: "Bij Nu staat een lijstje met spullen en afspraken. Kijk samen of je warme kleding, een lampje en een snoeptas hebt.", tip: "De echte startplek en starttijd staan in de ouderomgeving. Loop altijd met je eigen groep mee.", path: "/poortenboek", target: "#voorbereiding" },
  { label: "Hulp & klaar", title: "Veel plezier, avonturier!", copy: "Kom je er niet uit? Vraag het aan de volwassene die met je meeloopt.", tip: "Met Zo werkt mijn boek kun je deze uitleg altijd opnieuw bekijken. Jouw boek blijft op je wachten.", path: "/poortenboek/ik", target: ".pb-profile", profileTab: "settings" },
];

type Session = { active: boolean; mandatory: boolean; index: number; returnHash: string; completed?: boolean };
function sessionKey(childId: string) { return `poortenboek-kid-guide:${VERSION}:${childId}`; }
function readSession(childId: string): Session | null {
  try { const value = JSON.parse(sessionStorage.getItem(sessionKey(childId)) || "null"); if (value && typeof value.active === "boolean" && typeof value.mandatory === "boolean" && Number.isInteger(value.index) && value.index >= 0 && value.index < steps.length && typeof value.returnHash === "string" && value.returnHash.startsWith("/poortenboek") && value.returnHash.length < 2048) return value; } catch { /* No browser storage: the current mounted guide still works. */ }
  return null;
}
function storeSession(childId: string, value: Session) { try { sessionStorage.setItem(sessionKey(childId), JSON.stringify(value)); } catch { /* In-memory progress remains available. */ } }
function currentHash() { const hash = window.location.pathname + window.location.search; return hash.startsWith("/poortenboek") ? hash : "/poortenboek"; }

function initialTour(snapshot: TutorialSnapshot, childId: string): Session {
  const session = readSession(childId);
  if (session?.active && snapshot.tutorial?.completedAt) return {...session,mandatory:false};
  const complete = snapshot.tutorial?.version === VERSION && Boolean(snapshot.tutorial.completedAt);
  const resumable = snapshot.tutorial?.version === VERSION && Number.isInteger(snapshot.tutorial.lastStep);
  return { active: !complete, mandatory: !complete, index: resumable ? Math.max(0, Math.min(steps.length - 1, snapshot.tutorial?.lastStep ?? 0)) : 0, returnHash: currentHash(), completed: complete };
}

export function KidGuide({ snapshot, section, onComplete }: { snapshot: TutorialSnapshot; section: BookSection; onComplete?: () => void | Promise<void> }) {
  const childId = snapshot.childId || `child-${snapshot.medallion}`;
  return <ChildGuide key={childId} snapshot={snapshot} section={section} childId={childId} onComplete={onComplete}/>;
}

function ChildGuide({ snapshot, section, childId, onComplete }: { snapshot: TutorialSnapshot; section: BookSection; childId: string; onComplete?: () => void | Promise<void> }) {
  const router=useRouter();
  const go=useCallback((path:string)=>{if(currentHash().split("?")[0]!==path)router.push(path);},[router]);
  const [tour, setTour] = useState<Session>(() => initialTour(snapshot, childId));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [targetVisible, setTargetVisible] = useState(false);
  const title = useRef<HTMLHeadingElement>(null);
  const step = steps[tour.index];
  useEffect(() => { storeSession(childId, tour); }, [childId, tour]);
  useEffect(() => {
    if (!tour.active) return;
    go(step.path);
    let attempts = 0;
    const show = () => {
      window.dispatchEvent(new CustomEvent("poortenboek-guide-navigate", { detail: { teamTab: step.teamTab, profileTab: step.profileTab } }));
      const target = document.querySelector<HTMLElement>(step.target);
      if (target && target.getBoundingClientRect().width > 0) { target.scrollIntoView({ behavior: "instant", block: "center" }); setTargetVisible(true); } else setTargetVisible(false);
    };
    const tick = window.setTimeout(() => { show(); title.current?.focus(); }, 100);
    const retry = window.setInterval(() => { show(); if (++attempts >= 6) window.clearInterval(retry); }, 180);
    return () => { window.clearTimeout(tick); window.clearInterval(retry); };
  }, [tour.active, tour.index, section, step.path, step.profileTab, step.target, step.teamTab,go]);

  async function persist(index: number, completed = false) {
    if (!tour.mandatory) return true;
    try {
      const response = await fetch("/api/poortenboek/tutorial", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ step: index, completed, version: VERSION }), cache: "no-store" });
      if (!response.ok) throw new Error("save");
      return true;
    } catch { setError("Dat lukte nog niet. Probeer opnieuw, of vraag een volwassene om hulp."); return false; }
  }
  async function move(index: number) {
    if (busy || index < 0 || index >= steps.length) return;
    setBusy(true); setError("");
    const ok = await persist(index);
    if (ok) { const next = { ...tour, index }; storeSession(childId, next); setTour(next); }
    setBusy(false);
  }
  async function finish() {
    if (busy || tour.index !== steps.length - 1) return;
    setBusy(true); setError("");
    const ok = await persist(tour.index, true);
    if (ok) {
      const next = { ...tour, active: false, mandatory: false, completed: true };
      storeSession(childId, next); setTour(next);
      await onComplete?.();
      router.push(tour.returnHash);
    }
    setBusy(false);
  }
  function replay() { const next = { active: true, mandatory: false, index: 0, returnHash: currentHash(), completed: true }; storeSession(childId, next); setTour(next); setError(""); }
  function close() { if (tour.mandatory || busy) return; const next = { ...tour, active: false }; storeSession(childId, next); setTour(next); router.push(tour.returnHash); }

  return <>
    <button type="button" className="pb-kid-help" onClick={replay} aria-label="Zo werkt mijn boek"><HelpCircle size={18}/><span>Zo werkt mijn boek</span></button>
    <Primitive.Root open={tour.active} onOpenChange={open => { if (!open) close(); }}><Primitive.Portal><Primitive.Overlay className="pb-kid-guide-overlay"/><Primitive.Content className="pb-kid-guide-dialog" onEscapeKeyDown={event => { if (tour.mandatory || busy) event.preventDefault(); }} onPointerDownOutside={event => event.preventDefault()} onOpenAutoFocus={event => { event.preventDefault(); title.current?.focus(); }}>
      <div className="pb-kid-guide-top"><span><Sparkles size={16}/>Even samen kijken</span>{!tour.mandatory && <button type="button" aria-label="Uitleg sluiten" onClick={close} disabled={busy}><X size={20}/></button>}</div>
      <div className="pb-kid-guide-progress" role="progressbar" aria-label="Voortgang uitleg" aria-valuemin={1} aria-valuemax={steps.length} aria-valuenow={tour.index + 1}><span style={{ width: `${(tour.index + 1) / steps.length * 100}%` }}/></div>
      <div className="pb-kid-guide-stage"><img src="/images/poortenboek-v3/guide-spirit.webp" alt="Een vriendelijk lichtgeestje helpt je op weg" onError={event => { event.currentTarget.onerror = null; event.currentTarget.src = "/images/poortenboek-v2/avatars/ghost-scout.webp"; }}/><div><p className="pb-kid-guide-counter">{tour.index + 1} van {steps.length} <span>{step.label}</span></p><Primitive.Title ref={title} tabIndex={-1} className="pb-kid-guide-title">{tour.index === 0 ? `Hoi ${snapshot.firstName}, dit is jouw boek!` : step.title}</Primitive.Title></div></div>
      <Primitive.Description className="pb-kid-guide-copy">{step.copy}</Primitive.Description>
      <div className="pb-kid-guide-tip"><BookOpen size={20}/><p>{step.tip}</p></div>
      <p className="pb-kid-guide-screen">{targetVisible ? "Het bijbehorende scherm staat achter deze uitleg." : "Dit onderdeel verschijnt wanneer jullie avontuur eraan toe is."}</p>
      {error && <p className="pb-kid-guide-error" role="alert">{error}</p>}
      <div className="pb-kid-guide-actions"><button className="pb-kid-guide-back" type="button" disabled={busy || tour.index === 0} onClick={() => void move(tour.index - 1)}><ArrowLeft size={17}/>Terug</button>{tour.index < steps.length - 1 ? <button className="pb-kid-guide-next" type="button" disabled={busy} onClick={() => void move(tour.index + 1)}>{busy ? "Even wachten…" : "Verder"}<ArrowRight size={18}/></button> : <button className="pb-kid-guide-next" type="button" disabled={busy} onClick={() => void finish()}><Check size={18}/>{busy ? "Even bewaren…" : "Ik ben klaar voor mijn avontuur!"}</button>}</div>
      {tour.mandatory && <p className="pb-kid-guide-required">We kijken alles één keer samen na. Bij opnieuw openen gaan we verder waar je was.</p>}
    </Primitive.Content></Primitive.Portal></Primitive.Root>
  </>;
}
