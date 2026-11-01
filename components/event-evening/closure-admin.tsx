"use client";

import { useRef, useState } from "react";
import { CheckCircle2, Mail, MoonStar, RefreshCw } from "lucide-react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { EVENING_CLOSURE_BODY, EVENING_CLOSURE_BODY_LIMIT, EVENING_CLOSURE_SUBJECT, EVENING_CLOSURE_SUBJECT_LIMIT } from "@/lib/event-evening/defaults";
import { eveningClosureResponse, isEveningClosureSnapshot, type EveningClosureMail } from "@/lib/event-evening/types";
import { useClosureSnapshot } from "./use-closure-snapshot";
import "../../modern/event-evening.css";

export function closureDate(value: string) {
  return new Date(value).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Amsterdam" });
}

function ClosureMailProgress({ mail }: { mail: EveningClosureMail }) {
  return <div className="evening-mail-progress" aria-label="Verzendstatus bedankbericht">
    {[["In wachtrij", mail.queued], ["Verwerkt", mail.processed], ["Provider geaccepteerd", mail.providerAccepted], ["Bezorging bevestigd", mail.delivered], ["Mislukt", mail.failed], ["Uitkomst onbekend", mail.unknown], ["Verzending geblokkeerd", mail.suppressed]].map(([label, count]) => <div key={label}><strong>{count}</strong><span>{label}</span></div>)}
  </div>;
}

export function EventEveningClosureAdmin({ eventSlug, eventId, eventTitle, authorized }: {
  eventSlug: string; eventId: string; eventTitle: string; authorized: boolean;
}) {
  const { snapshot, error, loading, load, replace } = useClosureSnapshot({ eventSlug, eventId, scope: "admin", enabled: authorized, poll: authorized });
  const [open, setOpen] = useState(false);
  const [subject, setSubject] = useState(EVENING_CLOSURE_SUBJECT);
  const [body, setBody] = useState(EVENING_CLOSURE_BODY);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const command = useRef<{ id: string; subject: string; body: string } | null>(null);
  const [notice, setNotice] = useState("");
  const [uncertain, setUncertain] = useState(false);
  if (!authorized) return null;

  async function send(action: "confirm" | "retry_failed") {
    if (busyRef.current || !snapshot || snapshot.event.id !== eventId || (action === "confirm" && (snapshot.closed || uncertain))) return;
    busyRef.current = true; setBusy(true); setNotice("");
    if (action === "confirm") command.current ??= { id: crypto.randomUUID(), subject, body };
    try {
      const response = await fetch("/api/event-evening/closure", {
        method: "POST", cache: "no-store", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ eventSlug, action, ...(action === "confirm" ? { subject: command.current!.subject, body: command.current!.body, commandId: command.current!.id } : {}) }),
      });
      const result = eveningClosureResponse(await response.json());
      if (!response.ok || !isEveningClosureSnapshot(result, eventSlug, eventId)) throw new Error();
      replace(result); setUncertain(false);
      if (result.closed) {
        setOpen(false);
        setNotice(action === "confirm" ? "De avond is afgesloten. De bedankberichten worden verstuurd." : result.requeued === 0 ? "Geen verzendjobs opnieuw klaargezet; controleer de bestaande mailregistratie." : typeof result.requeued === "number" ? `${result.requeued} mislukte of aantoonbaar niet uitgevoerde verzendjob(s) opnieuw klaargezet.` : "Het herstelverzoek is verwerkt. Controleer de actuele verzendstatus.");
      }
    } catch {
      setUncertain(true);
      setNotice("De uitkomst is nog niet bevestigd. Controleer eerst de actuele status; het verzoek wordt niet automatisch herhaald.");
    } finally { busyRef.current = false; setBusy(false); }
  }

  async function checkOutcome() {
    const current = await load();
    if (current) {
      setUncertain(false);
      if (current.closed) { setOpen(false); setNotice("De avond is afgesloten. De bedankberichten worden verstuurd."); }
    }
    // A status read never confirms or resends a mutation. A new deliberate click
    // retains the original command and text when the first result is unknown.
  }
  const counts = snapshot?.counts;
  const fixed = snapshot?.closure;
  const valid = subject.trim().length > 0 && subject.length <= EVENING_CLOSURE_SUBJECT_LIMIT && body.trim().length > 0 && body.length <= EVENING_CLOSURE_BODY_LIMIT;
  return <section className="panel evening-closure-admin" aria-labelledby="evening-closure-heading">
    <p className="kicker">Evenement afsluiten</p><div className="row-between"><div><h2 id="evening-closure-heading">Een warme afsluiting voor iedereen.</h2><p>{eventTitle} · {eventSlug}</p></div><MoonStar aria-hidden="true"/></div>
    {fixed ? <><p className="evening-closed-status"><CheckCircle2 size={19}/>De avond is afgesloten op {closureDate(fixed.closedAt)}.</p><p>De bedankberichten worden verstuurd. Dit vaste organisatiebericht kan niet opnieuw worden verzonden door de avond nogmaals af te sluiten.</p><details className="evening-confirmed-message"><summary>Bekijk het vastgelegde organisatiebericht</summary><h3>{fixed.subject}</h3><p className="evening-message-text">{fixed.body}</p></details>{snapshot.mail && <ClosureMailProgress mail={snapshot.mail}/>}<p className="evening-contact-note">Deze verzendstanden horen bij het organisatiebericht aan deelnemers.</p>{Boolean(snapshot.mail?.houseFailed) && <p className="evening-contact-note">Mislukte bewonersberichten: <strong>{snapshot.mail!.houseFailed}</strong></p>}<div className="actions"><button type="button" className="btn outline" disabled={busy || loading} onClick={() => void load()}><RefreshCw size={16}/>Verzendstatus vernieuwen</button>{Boolean(snapshot.mail?.failed || snapshot.mail?.houseFailed) && <button type="button" className="btn outline" disabled={busy || uncertain} onClick={() => void send("retry_failed")}>Alleen mislukte verzendjobs herstellen</button>}</div>{Boolean(snapshot.mail?.unknown) && <p className="evening-contact-note">Bij een onbekende provideruitkomst wordt niet blind opnieuw verstuurd. Controleer eerst de bestaande mailregistratie.</p>}</> : <><p>Sluit de avond bewust voor alle deelnemers af, geef alle deelnemende poorten en zegels vrij en stuur één bewerkbaar organisatiebericht.</p><button type="button" className="btn" disabled={!snapshot || loading || busy} onClick={() => { setOpen(true); setNotice(""); }}><MoonStar size={17}/>Avond afsluiten…</button></>}
    {(error || notice) && <p className="form-notice" role="status">{error || notice}</p>}
    {(!snapshot || uncertain) && <button className="text-link" type="button" disabled={busy || loading} onClick={() => void checkOutcome()}>Actuele afsluitstatus controleren</button>}
    <Dialog open={open && !fixed} onOpenChange={next => { if (!busyRef.current) setOpen(next); }}><DialogContent className="evening-closure-dialog" showCloseButton={!busy} onEscapeKeyDown={event => { if (busy) event.preventDefault(); }} onPointerDownOutside={event => { if (busy) event.preventDefault(); }}>
      <DialogTitle>Avond afsluiten en iedereen bedanken</DialogTitle>
      <DialogDescription>De avond is voor iedereen klaar, ook zonder afgeronde route of finalescan. Alle deelnemende poorten staan op bezocht en alle zegels zijn vrij. Alle deelnemers krijgen dit bericht in de app en per e-mail waar mogelijk; gezinnen kunnen daarna alle huizen bedanken.</DialogDescription>
      <div className="evening-closure-event"><strong>{snapshot?.event.title ?? eventTitle}</strong><span>{eventSlug}</span></div>
      {counts && <dl className="evening-closure-counts"><div><dt>Deelnemersaccounts</dt><dd>{counts.participantAccounts}</dd></div><div><dt>Kinderen</dt><dd>{counts.children}</dd></div><div><dt>Deelnemende huizen</dt><dd>{counts.participatingHouses}</dd></div><div><dt>Unieke e-mailontvangers</dt><dd>{counts.uniqueEmailRecipients}</dd></div></dl>}
      {counts && <p className="evening-contact-note" role="status">{counts.missingContactAccounts} deelnemersaccount(s) zonder beschikbaar contactadres. De terugblik blijft voor hen in de app beschikbaar; dit houdt het afsluiten niet tegen. Bestaande verzendblokkades blijven gelden.{Boolean(counts.pendingActivations) && ` ${counts.pendingActivations} bestaande inschrijving(en) wachten nog op accountactivatie; zij krijgen dezelfde terugblik zodra hun toegang is geactiveerd.`}</p>}
      <fieldset disabled={busy || uncertain} className="evening-message-fields"><legend className="sr-only">Organisatiebedankbericht aanpassen</legend><label>Onderwerp<input value={subject} maxLength={EVENING_CLOSURE_SUBJECT_LIMIT} onChange={event => { command.current = null; setSubject(event.target.value); }}/></label><label>Bericht<textarea aria-label="Bericht" value={body} rows={15} maxLength={EVENING_CLOSURE_BODY_LIMIT} onChange={event => { command.current = null; setBody(event.target.value); }}/></label></fieldset>
      <section className="evening-message-preview" aria-label="Voorvertoning in app en e-mail"><p className="kicker"><Mail size={14}/>Voorvertoning · app en e-mail</p><h3>{subject}</h3><p className="evening-message-text">{body}</p></section>
      <p className="evening-contact-note">Na bevestigen liggen deze tekst en de sluiting vast. De server controleert opnieuw je bevoegdheid en de actuele evenementstatus.</p>
      {notice && <p className="form-notice" role="status">{notice}</p>}{uncertain && <button type="button" className="text-link" disabled={loading || busy} onClick={() => void checkOutcome()}>Actuele afsluitstatus controleren</button>}
      <div className="evening-closure-actions"><button className="btn outline" type="button" disabled={busy} onClick={() => setOpen(false)}>Annuleren</button><button className="btn" type="button" disabled={busy || uncertain || !valid || !counts || snapshot?.closed} onClick={() => void send("confirm")}>{busy ? "Afsluiting bevestigen…" : "Avond afsluiten en bedankbericht versturen"}</button></div>
    </DialogContent></Dialog>
  </section>;
}
