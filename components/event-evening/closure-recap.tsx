"use client";

import Link from "next/link";
import { useRef, useState } from "react";
import { CheckCircle2, Heart, MailOpen, MoonStar, TicketCheck } from "lucide-react";
import { FamilyPortalThanks } from "@/components/redesign/portal-thanks";
import type { EveningClosure } from "@/lib/event-evening/types";
import { eveningClosureResponse, isEveningClosureSnapshot } from "@/lib/event-evening/types";
import { useClosureSnapshot } from "./use-closure-snapshot";
import "../../modern/event-evening.css";

export function EventEveningRecap({ closure, eventSlug, withThanks = true }: {
  closure: EveningClosure; eventSlug: string; withThanks?: boolean;
}) {
  const [acknowledged, setAcknowledged] = useState(closure.readAt ?? null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const saving = useRef(false);
  const target = withThanks ? "" : "/omgeving/meeloper/nu";
  async function acknowledge() {
    if (saving.current || acknowledged) return;
    saving.current = true; setBusy(true); setNotice("");
    try {
      const response = await fetch("/api/event-evening/closure", { method: "POST", cache: "no-store", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ eventSlug, action: "acknowledge", closureId: closure.id }) });
      const result = eveningClosureResponse(await response.json());
      if (!response.ok || !isEveningClosureSnapshot(result, eventSlug) || result.closure?.id !== closure.id || !result.closure.readAt) throw new Error();
      setAcknowledged(result.closure.readAt);
    } catch { setNotice("Gelezen-status bewaren lukt nu niet. Je kunt gewoon verder navigeren en de terugblik later openen."); }
    finally { saving.current = false; setBusy(false); }
  }
  return <div className="evening-recap" aria-labelledby="evening-recap-title">
    <section className="participant-card evening-recap-message">
      <span className="evening-recap-symbol" aria-hidden="true"><MoonStar size={31}/></span>
      <p className="participant-eyebrow">Een nacht om te bewaren</p>
      <h1 id="evening-recap-title">Bedankt, dappere Duindorpers!</h1>
      <h2>{closure.subject}</h2>
      <p className="evening-message-text">{closure.body}</p>
      <p className="evening-stamps-complete"><CheckCircle2 size={20}/>Jullie Nachtpas is compleet: alle zegels zijn vrijgegeven.</p>
      <div className="participant-actions evening-recap-actions"><a className="btn" href={`${target}#thanks-all-houses`}><Heart size={17}/>Bedank alle huizen</a><a className="btn outline" href={`${target}#thanks-personal-house`}>Geef een huis een extra bedankje</a><Link className="btn outline" href="/omgeving/meeloper/nachtpas"><TicketCheck size={17}/>Bekijk de complete Nachtpas</Link><a className="text-link" href={`${target}#thanks-sent-history`}>Eigen verstuurde bedankjes</a></div>
      <div className="evening-read-status">{acknowledged ? <span><MailOpen size={16}/>Bericht gelezen. Deze terugblik blijft bereikbaar via Overzicht en Route.</span> : <button type="button" className="text-link" disabled={busy} onClick={() => void acknowledge()}>{busy ? "Gelezen-status bewaren…" : "Markeer dit bericht als gelezen"}</button>}</div>
      {notice && <p className="form-notice" role="status">{notice}</p>}
      <p className="evening-voluntary-note">Bedanken is vrijwillig. Jullie kunnen vrij verder navigeren in de app.</p>
    </section>
    {withThanks && <FamilyPortalThanks/>}
  </div>;
}

export function CompleteEveningNightPass({ closure, eventSlug, childProfiles }: {
  closure: EveningClosure; eventSlug: string; childProfiles: Array<{ id: string; firstName: string }>;
}) {
  const { snapshot, error, loading, load } = useClosureSnapshot({ eventSlug, scope: "participant" });
  const portals = snapshot?.closure?.id === closure.id ? snapshot.portals : undefined;
  return <section className="participant-card evening-complete-pass" aria-labelledby="evening-complete-pass-title">
    <div className="section-title"><div><p className="participant-eyebrow">Cadeau van de organisatie</p><h2 id="evening-complete-pass-title">Jullie Nachtpas is compleet</h2></div><TicketCheck aria-hidden="true"/></div>
    <p>Alle deelnemende poorten staan op bezocht en alle bijbehorende zegels zijn vrijgegeven, inclusief de finalepoort. Dit geldt ook zonder routestart of finalescan.</p>
    {childProfiles.length > 0 && <ul className="evening-child-stamps" aria-label="Zegels per kind">{childProfiles.map(child => <li key={child.id}><CheckCircle2 size={17}/><strong>{child.firstName}</strong><span>Alle zegels vrijgegeven</span></li>)}</ul>}
    {portals ? <ul className="evening-gift-stamps" aria-label="Alle vrijgegeven poortzegels">{portals.map(portal => <li key={portal.id}><CheckCircle2 aria-hidden="true"/><div><strong>{portal.name}</strong><span>{portal.worldName}{portal.finale ? `${portal.worldName ? " · " : ""}Finalepoort` : ""}</span><small>Bezocht · cadeauzegel van de organisatie</small></div></li>)}</ul> : <p role="status">{loading ? "De vrijgegeven poortzegels worden opgehaald…" : "De lijst met vrijgegeven zegels is nog niet beschikbaar."}</p>}
    {error && <p className="form-notice" role="status">{error}<button className="text-link" type="button" disabled={loading} onClick={() => void load()}>Zegels opnieuw ophalen</button></p>}
    <Link href="/omgeving/meeloper/nu" className="btn outline">Naar de terugblik en bedankjes</Link>
  </section>;
}
