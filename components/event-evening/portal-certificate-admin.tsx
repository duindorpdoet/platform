"use client";

import { useEffect, useRef, useState } from "react";
import { CheckCircle2, FileHeart, Mail, RefreshCw } from "lucide-react";
import Link from "next/link";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { PORTAL_CERTIFICATE_BODY, PORTAL_CERTIFICATE_SUBJECT } from "@/lib/event-evening/portal-certificate-defaults";
import { EVENING_CLOSURE_BODY_LIMIT, EVENING_CLOSURE_SUBJECT_LIMIT } from "@/lib/event-evening/defaults";
import { eveningClosureResponse } from "@/lib/event-evening/types";
import { validatePortalCertificateSnapshot, type PortalCertificateMail } from "@/lib/event-evening/portal-certificates";
import { usePortalCertificateStatus } from "./use-portal-certificate-status";
import "../../modern/event-evening.css";

type Props = { eventSlug: string; eventId: string; eventTitle: string; authorized: boolean };
export function PortalCertificateMailAdmin(props: Props) {
  return props.authorized ? <CertificateCampaign key={`${props.eventId}:${props.eventSlug}`} {...props}/> : null;
}
function MailProgress({ mail }: { mail: PortalCertificateMail }) {
  return <div className="evening-mail-progress" aria-label="Verzendstatus certificaatmail">{[["Nog klaar te zetten", mail.pending], ["In wachtrij", mail.queued], ["Verwerkt", mail.processed], ["Provider geaccepteerd", mail.providerAccepted], ["Bezorging bevestigd", mail.delivered], ["Mislukt", mail.failed], ["Uitkomst onbekend", mail.unknown], ["Geblokkeerd", mail.suppressed]].map(([label, count]) => <div key={label}><strong>{count}</strong><span>{label}</span></div>)}</div>;
}
function CertificateCampaign({ eventSlug, eventId, eventTitle }: Props) {
  const { snapshot, error, loading, load, replace, deny } = usePortalCertificateStatus(eventSlug, eventId);
  const [open, setOpen] = useState(false), [subject, setSubject] = useState(PORTAL_CERTIFICATE_SUBJECT), [body, setBody] = useState(PORTAL_CERTIFICATE_BODY);
  const [acknowledged, setAcknowledged] = useState(false), [busy, setBusy] = useState(false), [uncertain, setUncertain] = useState(false), [draftFrozen, setDraftFrozen] = useState(false), [notice, setNotice] = useState("");
  const busyRef = useRef(false), mounted = useRef(false);
  const command = useRef<{ commandId: string; subject: string; body: string } | null>(null);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const valid = Boolean(subject.trim() && body.trim() && subject.length <= EVENING_CLOSURE_SUBJECT_LIMIT && body.length <= EVENING_CLOSURE_BODY_LIMIT && !/[\r\n\u0000]/.test(subject) && !body.includes("\u0000"));
  const fixed = snapshot?.campaign;
  async function send(action: "confirm" | "retry_failed") {
    if (busyRef.current || !snapshot || uncertain || (action === "confirm" && (!snapshot.ready || snapshot.confirmed || !valid || !acknowledged)) || (action === "retry_failed" && !snapshot.mail.retryableFailed)) return;
    busyRef.current = true; setBusy(true); setNotice("");
    if (action === "confirm") { command.current ??= { commandId: crypto.randomUUID(), subject, body }; setDraftFrozen(true); }
    try {
      const response = await fetch("/api/event-evening/portal-certificates", { method: "POST", cache: "no-store", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ eventSlug, action, ...(action === "confirm" ? command.current : {}) }) });
      if (!mounted.current) return;
      if (response.status === 401 || response.status === 403) { deny(); setOpen(false); return; }
      const value = validatePortalCertificateSnapshot(eveningClosureResponse(await response.json()), eventSlug, eventId);
      if (!mounted.current) return;
      if (!response.ok || !value?.confirmed || !value.campaign || (action === "retry_failed" && typeof value.requeued !== "number")) throw new Error();
      if (!replace(value)) { setOpen(false); return; }
      setOpen(false); setUncertain(false);
      setNotice(action === "confirm" ? "De certificaatcampagne is vastgelegd. De berichten worden apart verwerkt." : value.requeued === 0 ? "Geen verzendjobs opnieuw klaargezet; controleer de bestaande mailregistratie." : `${value.requeued} aantoonbaar mislukte verzendjob(s) opnieuw klaargezet.`);
    } catch {
      if (mounted.current) { setUncertain(true); setNotice("De uitkomst is nog niet bevestigd. Controleer eerst de actuele status. Dit verzoek wordt niet automatisch herhaald."); }
    } finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  }
  async function checkStatus() {
    const value = await load();
    if (!mounted.current || !value) return;
    setUncertain(false);
    if (value.confirmed) { setOpen(false); setNotice("De certificaatcampagne is vastgelegd. Controleer hieronder de actuele verzendstatus."); }
    else if (command.current) setNotice("Er is nog geen bevestigde campagne zichtbaar. Een nieuwe bewuste bevestiging gebruikt dezelfde aanvraag en tekst.");
  }
  return <section className="panel evening-closure-admin" aria-labelledby="portal-certificate-heading">
    <p className="kicker">Poortwachters en crew bedanken</p><div className="row-between"><div><h2 id="portal-certificate-heading">Jullie certificaat verdient een bericht.</h2><p>{eventTitle} · {eventSlug}</p></div><FileHeart aria-hidden="true"/></div>
    <p>Stuur het actieve poortteam een organisatiedank, de link naar hun certificaat en een uitnodiging om volgend jaar mee te denken over Duindorp FrightNight.</p>
    {fixed ? <><p className="evening-closed-status"><CheckCircle2 size={19}/>Vastgelegd op {new Date(fixed.createdAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam", dateStyle: "long", timeStyle: "short" })}.</p><details className="evening-confirmed-message"><summary>Bekijk het vastgelegde certificaatbericht</summary><h3>{fixed.subject}</h3><p className="evening-message-text">{fixed.body}</p><Link href="/mijn-huis">Open jullie Poortkamer</Link></details><p className="evening-contact-note">Deze afzonderlijke campagne is één keer bevestigd. Nogmaals openen verstuurt niets opnieuw.</p><MailProgress mail={snapshot!.mail}/><div className="actions"><button type="button" className="btn outline" disabled={busy || loading} onClick={() => void checkStatus()}><RefreshCw size={16}/>Certificaatmailstatus vernieuwen</button>{snapshot!.mail.retryableFailed > 0 && <button type="button" className="btn outline" disabled={busy || uncertain} onClick={() => void send("retry_failed")}>Alleen mislukte certificaatmails herstellen</button>}</div>{snapshot!.mail.unknown > 0 && <p className="evening-contact-note">Bij een onbekende provideruitkomst wordt niet blind opnieuw verstuurd. Controleer de bestaande mailregistratie.</p>}</> : <><button type="button" className="btn" disabled={!snapshot?.ready || busy || loading} onClick={() => { setOpen(true); setAcknowledged(false); setNotice(""); }}><Mail size={17}/>Certificaatbericht aan poortteams…</button><button type="button" className="btn outline" disabled={busy || loading} onClick={() => void checkStatus()}><RefreshCw size={16}/>Certificaatmailstatus vernieuwen</button>{snapshot && !snapshot.ready && <p className="evening-contact-note">Sluit de avond eerst bewust af. Daarna kun je deze afzonderlijke mailactie bevestigen.</p>}</>}
    {(error || notice) && <p className="form-notice" role="status">{error || notice}</p>}
    {(!snapshot || uncertain) && <button type="button" className="text-link" disabled={busy || loading} onClick={() => void checkStatus()}>Actuele certificaatmailstatus controleren</button>}
    <Dialog open={open && !fixed && Boolean(snapshot)} onOpenChange={next => { if (!busyRef.current) setOpen(next); }}><DialogContent className="evening-closure-dialog" showCloseButton={!busy} onEscapeKeyDown={event => { if (busy) event.preventDefault(); }} onPointerDownOutside={event => { if (busy) event.preventDefault(); }}>
      <DialogTitle>Certificaten aankondigen en het poortteam bedanken</DialogTitle>
      <DialogDescription>Dit is een aparte, eenmalige e-mail aan actieve poortwachters en crew. Het certificaat staat in hun eigen Poortkamer en kan daar worden gedeeld of gedownload.</DialogDescription>
      <div className="evening-closure-event"><strong>{snapshot?.event.title ?? eventTitle}</strong><span>{eventSlug}</span></div>
      {snapshot && <><dl className="evening-closure-counts"><div><dt>Deelnemende huizen</dt><dd>{snapshot.counts.participatingHouses}</dd></div><div><dt>Actieve teamaccounts</dt><dd>{snapshot.counts.teamAccounts}</dd></div><div><dt>Unieke e-mailontvangers</dt><dd>{snapshot.counts.uniqueEmailRecipients}</dd></div></dl><p className="evening-contact-note">{snapshot.counts.missingContactAccounts} teamaccount(s) zonder beschikbaar bevestigd contactadres. Bestaande verzendblokkades blijven gelden. De server controleert de actuele teamtoegang opnieuw.</p></>}
      <fieldset disabled={busy || uncertain || draftFrozen} className="evening-message-fields"><legend className="sr-only">Organisatiebericht voor poortteams aanpassen</legend><label>Onderwerp<input value={subject} maxLength={EVENING_CLOSURE_SUBJECT_LIMIT} onChange={event => setSubject(event.target.value)}/></label><label>Bericht<textarea aria-label="Bericht" value={body} rows={15} maxLength={EVENING_CLOSURE_BODY_LIMIT} onChange={event => setBody(event.target.value)}/></label></fieldset>
      <section className="evening-message-preview" aria-label="Voorvertoning certificaatmail"><p className="kicker"><Mail size={14}/>Voorvertoning · e-mail</p><h3>{subject}</h3><p className="evening-message-text">{body}</p><Link href="/mijn-huis" target="_blank" rel="noopener noreferrer">Open jullie Poortkamer</Link><p className="evening-contact-note">De ontvanger opent na inloggen het certificaat met de vooraf geregistreerde groepen en kids voor de eigen poort. Er wordt geen afbeelding met privégegevens meegestuurd.</p></section>
      <label className="evening-certificate-confirm"><input type="checkbox" checked={acknowledged} disabled={busy || uncertain} onChange={event => setAcknowledged(event.target.checked)}/><span>Ik heb de tekst en ontvangersaantallen gecontroleerd en wil dit certificaatbericht één keer aan de actieve poortwachters en crew versturen.</span></label>
      <p className="evening-contact-note">Na bevestigen ligt de tekst vast. Bij gelijktijdige bevestiging door een andere organisator blijft de al vastgelegde campagne leidend.</p>
      {notice && <p className="form-notice" role="status">{notice}</p>}{uncertain && <button type="button" className="text-link" disabled={busy || loading} onClick={() => void checkStatus()}>Actuele certificaatmailstatus controleren</button>}
      <div className="evening-closure-actions"><button type="button" className="btn outline" disabled={busy} onClick={() => setOpen(false)}>Annuleren</button><button type="button" className="btn" disabled={busy || uncertain || !acknowledged || !valid || !snapshot?.ready} onClick={() => void send("confirm")}>{busy ? "Campagne bevestigen…" : "Certificaatbericht definitief versturen"}</button></div>
    </DialogContent></Dialog>
  </section>;
}
