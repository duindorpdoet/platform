"use client";
/* eslint-disable @next/next/no-location-assign-relative-destination -- Role/child changes intentionally discard all prior private router state. */
import Link from "next/link";
import { useState } from "react";
import { ArrowRight, BookOpen, CheckCircle2, DoorOpen, Eye, ShieldCheck, Sparkles, Users } from "lucide-react";
import type { AccountSnapshot, AccountTarget } from "@/lib/account/model";
import { SignOutButton } from "@/components/auth/account-actions";
import { EntryHeader } from "@/components/auth/account-login";

const icons = { parent: Users, house: DoorOpen, viewer: Eye, admin: ShieldCheck };
export function EnvironmentChooser({ initial }: { initial: AccountSnapshot }) {
  const [childId, setChildId] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const resumedChild = initial.resume?.kind === "child" ? initial.children.find(child => child.id === initial.resume?.id) : undefined;
  const resumedEnvironment = initial.resume?.kind === "adult" ? initial.environments.find(environment => environment.id === initial.resume?.id) : undefined;
  async function open(target: AccountTarget) {
    if (busy) return;
    setBusy(true); setNotice("");
    try {
      const result = await fetch("/api/account", { method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store", body: JSON.stringify({ action: "remember", target }) });
      const body = await result.json();
      if (!result.ok) throw new Error(body.error?.message ?? "Deze toegang is niet meer beschikbaar. Vernieuw je omgevingen.");
      if (target.kind === "child") {
        const selected = initial.children.find(child => child.id === target.id);
        setNotice(`Je opent het boek van ${selected?.firstName ?? "je kind"}…`);
        const child = await fetch("/api/poortenboek/parent", { method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store", body: JSON.stringify({ action: "open", childId: target.id }) });
        if (!child.ok) throw new Error("Het kinderboek kon niet veilig worden geopend. Vernieuw de kinderlijst en probeer opnieuw.");
        window.location.assign("/poortenboek");
      } else window.location.assign(body.data.path);
    } catch (error) { setNotice(error instanceof Error ? error.message : "Maak verbinding en probeer opnieuw."); setBusy(false); }
  }
  return <div className="entry-page entry-choice-page"><EntryHeader /><main className="entry-choice-wrap">
    <div className="entry-choice-heading"><p className="entry-kicker"><span />Jouw persoonlijke toegang</p><h1>Welkom terug.<br /><em>Jouw avontuur wacht.</em></h1><p>Waar begint jouw avontuur vandaag?</p><div className="entry-account-tag"><span>{initial.email}</span><SignOutButton label="Wissel account" destination="/inloggen" /></div></div>
    {notice && <p className="entry-error" role="status">{notice}</p>}
    {(resumedChild || resumedEnvironment) && <button type="button" disabled={busy} className="entry-resume-card" onClick={() => void open(initial.resume!)}><CheckCircle2 /><span><strong>Ga verder waar je was</strong><small>{resumedChild ? `Het Poortenboek van ${resumedChild.firstName}` : resumedEnvironment?.label}</small></span><ArrowRight /></button>}
    <section className="entry-environments" aria-label="Kies jouw omgeving">{initial.environments.map(environment => {
      const Icon = icons[environment.kind];
      return <button type="button" disabled={busy} className={`entry-environment-card is-${environment.kind}`} key={environment.id} onClick={() => void open({ kind: "adult", id: environment.id })}><span className="entry-environment-top"><span className="entry-environment-icon"><Icon size={25} /></span><ArrowRight size={21} /></span><h2>{environment.label}</h2><p>{environment.description}</p><span className="entry-environment-open">Open mijn omgeving <ArrowRight size={15} /></span></button>;
    })}</section>
    {initial.children.length > 0 && <section className="entry-children" aria-label="Poortenboeken van jouw kinderen"><span className="entry-children-symbol"><BookOpen size={30} /><Sparkles size={17} /></span><div><p className="entry-kicker">Een eigen avontuur voor ieder kind</p><h2>Het Poortenboek</h2><p>Ieder kind heeft een eigen boek, naam en voortgang. Jij opent het veilig vanuit je account.</p><div className="entry-child-choice"><label className="entry-child-select"><span className="sr-only">Kies een kinderomgeving</span><select disabled={busy} value={childId} onChange={event => setChildId(event.target.value)}><option value="">Kies een kinderomgeving</option>{initial.children.map(child => <option key={child.id} value={child.id}>{child.firstName}</option>)}</select></label><button className="entry-button entry-button-gold" type="button" disabled={busy || !childId} onClick={() => void open({ kind: "child", id: childId })}><BookOpen size={17} />Open Poortenboek</button></div></div></section>}
    {initial.environments.length === 0 && initial.children.length === 0 && <section className="entry-empty"><Users size={30} /><h2>Welkom bij De Poorten.</h2><p>Aan dit account is nog geen deelname gekoppeld. Meld je aan om mee te lopen of om een poort te openen. Een bestaande uitnodiging kun je openen vanuit het bericht van de organisatie.</p><div className="actions"><Link className="entry-button entry-button-gold" href="/meelopen">Meelopen</Link><Link className="entry-button entry-button-outline" href="/huis-aanmelden">Een poort aanmelden</Link></div></section>}
    <footer className="entry-choice-footer"><span><ShieldCheck size={15} />Alleen jouw gekoppelde omgevingen zijn zichtbaar.</span><Link className="device-text-button" href="/app/meldingen">App & meldingen</Link></footer>
  </main></div>;
}
