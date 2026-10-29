"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { trackShareCampaignCompletion } from "@/lib/social-share/client-analytics";

type ChildDraft = { name: string; age: string; accessibilityNote: string; stepFreeRequired: boolean | null };
type Draft = { adult: { name: string; phone: string }; children: ChildDraft[]; togetherCode: string; startPreference: "early" | "indifferent" | "later"; ordinaryStopAt: string; preferredStartAt: string; desiredEndAt: string; marketingConsent: boolean };
type Snapshot = { draft?: { payload: Draft; version: number } | null; registration?: { id: string; reference: string; status: string; priceCents: number; togetherCode: string; version: number; payment?: { status: string; amountCents: number; externalUrl?: string; version: number } | null } | null };

const emptyDraft: Draft = { adult: { name: "", phone: "" }, children: [{ name: "", age: "", accessibilityNote: "", stepFreeRequired: null }], togetherCode: "", startPreference: "indifferent", ordinaryStopAt: "", preferredStartAt: "", desiredEndAt: "", marketingConsent: false };

function normalizeTogetherCode(value: string) {
  return value.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g, "").slice(0, 4);
}

async function digest(value: unknown) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((item) => item.toString(16).padStart(2, "0")).join("");
}

export function RegistrationWizard({ eventSlug, canSubmit }: { eventSlug: string; canSubmit: boolean }) {
  const [accountEmail, setAccountEmail] = useState("");
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [version, setVersion] = useState<number | null>(null);
  const [registration, setRegistration] = useState<Snapshot["registration"]>(null);
  const [step, setStep] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [noticeIsError, setNoticeIsError] = useState(false);
  const [startOptions, setStartOptions] = useState<string[]>([]);
  const [endOptions, setEndOptions] = useState<string[]>([]);
  const heading = useRef<HTMLHeadingElement>(null);
  const noticeElement = useRef<HTMLParagraphElement>(null);
  const previousStep = useRef(step);
  useEffect(() => {
    if (previousStep.current !== step) heading.current?.focus();
    previousStep.current = step;
  }, [step]);
  useEffect(() => {
    if (noticeIsError) noticeElement.current?.focus();
  }, [notice, noticeIsError]);
  function reportError(message: string) {
    setNoticeIsError(true);
    setNotice(message);
    noticeElement.current?.focus();
    return false;
  }
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [maximum,setMaximum]=useState<number|null>(null);
  const [savedChildCount,setSavedChildCount]=useState(0);
  const [priceCents, setPriceCents] = useState<number | null>(null);
  const total = useMemo(() => priceCents === null ? null : draft.children.length * priceCents, [draft.children.length, priceCents]);

  useEffect(() => {
    const client = createClient();
    if (!client) return;
    void Promise.all([
      client.schema("api").rpc("registration_snapshot", { _event_slug: eventSlug }),
      client.schema("api").rpc("registration_preferences_snapshot", { _event_slug: eventSlug }),
      client.auth.getUser(),
    ]).then(([registrationResult, preferenceResult, accountResult]) => {
      setAccountEmail(accountResult.data.user?.email ?? "");
      const snapshot = registrationResult.data as Snapshot | null;
      if (snapshot?.draft?.payload) { setSavedChildCount(snapshot.draft.payload.children?.length??0); setDraft({ ...emptyDraft, ...snapshot.draft.payload, children: snapshot.draft.payload.children.map((child) => ({ ...child, stepFreeRequired: typeof child.stepFreeRequired === "boolean" ? child.stepFreeRequired : null })), adult: { ...emptyDraft.adult, ...snapshot.draft.payload.adult }, togetherCode: normalizeTogetherCode(snapshot.draft.payload.togetherCode ?? "") }); setVersion(snapshot.draft.version); }
      if (snapshot?.registration) setRegistration(snapshot.registration);
      const preference = preferenceResult.data as { event?: { allowedStartTimes?: string[]; allowedEndTimes?: string[]; priceCents?: number; maxGroupSize?: number } } | null;
      setPriceCents(preference?.event?.priceCents ?? null);
      const limit=preference?.event?.maxGroupSize;
      setMaximum(typeof limit==="number"&&Number.isSafeInteger(limit)&&limit>=1?limit:null);
      setStartOptions(preference?.event?.allowedStartTimes ?? []);
      setEndOptions(preference?.event?.allowedEndTimes ?? []);
    });
  }, [eventSlug]);

  async function save(nextStep?: number) {
    const client = createClient();
    if (!client) return reportError("We kunnen je inschrijving nu niet openen. Probeer het zo nog eens.");
    const policy=await client.schema("api").rpc("registration_preferences_snapshot",{_event_slug:eventSlug});
    const currentLimit=(policy.data as {event?:{maxGroupSize?:number}}|null)?.event?.maxGroupSize;
    if(policy.error||typeof currentLimit!=="number"||!Number.isSafeInteger(currentLimit)||currentLimit<1)return reportError("De actuele groepslimiet kon niet worden opgehaald. Je invoer blijft staan; probeer opnieuw.");
    setMaximum(currentLimit);
    if(draft.children.length>currentLimit&&draft.children.length>savedChildCount)return reportError(`De groepslimiet is nu ${currentLimit} kinderen, inclusief aangesloten gezinnen. Je invoer blijft staan. Controleer de samenloop of neem contact op met de organisatie.`);
    if (!draft.adult.name.trim()) return reportError("Vul eerst de naam van de verantwoordelijke volwassene in.");
    if (nextStep === 1 && !draft.desiredEndAt) return reportError("Kies een gewenste eindtijd voor de hele avond, inclusief de laatste poort.");
    if (nextStep === 2 && draft.children.some((child) => !child.name.trim() || !/^\d{1,2}$/.test(child.age) || Number(child.age) > 20)) return reportError("Vul voor ieder kind een naam en leeftijd in.");
    if (nextStep === 2 && draft.togetherCode.length > 0 && draft.togetherCode.length !== 4) return reportError("Een samenloopcode bestaat uit precies vier tekens.");
    setBusy(true); setNotice(""); setNoticeIsError(false);
    const { data, error } = await client.schema("api").rpc("registration_save_draft", { _event_slug: eventSlug, _payload: draft, _expected_version: version });
    setBusy(false);
    if (error) return reportError(error.message.includes("STALE_VERSION") ? "Deze inschrijving is intussen veranderd. Vernieuw de pagina en kijk het nog even na." : "Opslaan is niet gelukt. Controleer de ingevulde gegevens.");
    setVersion((data as { version: number }).version);
    setSavedChildCount(draft.children.length);
    setNotice("Jullie gegevens zijn bewaard. Je kunt later verdergaan.");
    if (nextStep !== undefined) setStep(nextStep);
    return true;
  }

  async function submit() {
    if (!canSubmit) return reportError("De inschrijvingen zijn gesloten.");
    if (draft.children.some((child) => !child.name.trim() || !/^\d{1,2}$/.test(child.age) || Number(child.age) > 20)) return reportError("Vul voor ieder kind een naam en geldige leeftijd in.");
    if (!draft.desiredEndAt) return reportError("Kies een gewenste eindtijd voor de hele avond, inclusief de laatste poort.");
    if (!await save()) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const key = crypto.randomUUID();
    const request = { eventSlug, terms: "2026-1", privacy: "2026-1", draft };
    const { data, error } = await client.schema("api").rpc("registration_submit", { _event_slug: eventSlug, _terms_version: "2026-1", _privacy_version: "2026-1", _idempotency_key: key, _request_hash: await digest(request) });
    setBusy(false);
    if (error) return reportError(error.message.includes("REGISTRATION_CLOSED") ? "De inschrijving is gesloten." : error.message.includes("GROUP_SIZE_LIMIT_EXCEEDED") ? `De organisatie heeft de groepslimiet gewijzigd. Jullie concept is behouden; controleer de actuele limiet of neem contact op met de organisatie.` : error.message.includes("INVALID_TOGETHER_CODE") ? "Deze samenloopcode is niet geldig. Controleer de vier tekens of laat het veld leeg." : "Definitief inschrijven is niet gelukt. Probeer het nog eens.");
    setRegistration(data as Snapshot["registration"]);
    trackShareCampaignCompletion("participant_registration");
    setStep(3);
  }

  if (registration) return <div className="panel success-panel" role="status"><p className="kicker">Jullie avontuur begint</p><h2 ref={heading} tabIndex={-1}>Welkom bij de poorten!</h2><p>De inschrijving is ontvangen. Willen bekenden zich bij jullie aansluiten? Deel dan jullie samenloopcode:</p><div className="registration-code together-share-code" aria-label={`Samenloopcode ${registration.togetherCode}`}>{registration.togetherCode}</div><p>Referentie voor vragen: <strong>{registration.reference}</strong>. Totale bijdrage: € {(registration.priceCents / 100).toFixed(2).replace(".", ",")}.</p><div className="actions"><Link className="btn" href="/mijn-inschrijving">Bekijk jullie inschrijving</Link></div></div>;

  return <div className="wizard panel">
    <div className="stepper" aria-label={`Stap ${step + 1} van 3`}><div className={step === 0 ? "active" : ""}><span>1</span><small>Volwassene</small></div><div className={step === 1 ? "active" : ""}><span>2</span><small>Kinderen</small></div><div className={step === 2 ? "active" : ""}><span>3</span><small>Controleren</small></div></div>
    {step === 0 && <section><h2 ref={heading} tabIndex={-1}>Wie loopt er mee?</h2><label className="field"><span>Naam verantwoordelijke volwassene</span><input value={draft.adult.name} onChange={(event) => setDraft({ ...draft, adult: { ...draft.adult, name: event.target.value } })} autoComplete="name" /></label><label className="field"><span>E-mailadres van je account</span><input type="email" value={accountEmail} readOnly autoComplete="email" placeholder="Accountgegevens worden opgehaald…" aria-describedby="registration-email-help" /><small id="registration-email-help">Hier ontvang je de bevestiging, betaallink en berichten over je inschrijving. Dit adres hoort bij het account waarmee je bent ingelogd.</small></label><label className="field"><span>Telefoonnummer voor de avond</span><input value={draft.adult.phone} onChange={(event) => setDraft({ ...draft, adult: { ...draft.adult, phone: event.target.value } })} inputMode="tel" autoComplete="tel" /></label><label className="field"><span>Gewenste starttijd</span><select value={draft.preferredStartAt} onChange={(event) => setDraft({ ...draft, preferredStartAt: event.target.value, startPreference: "indifferent" })}><option value="">Maakt niet uit</option>{startOptions.map((value) => <option key={value} value={value}>{new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</option>)}</select><small>Dit is een voorkeur. De organisatie bevestigt later één exact startpunt en tijdstip.</small></label><label className="field"><span>Wanneer willen jullie klaar zijn, inclusief de laatste poort?</span><select required value={draft.desiredEndAt} onChange={(event) => setDraft({ ...draft, desiredEndAt: event.target.value, ordinaryStopAt: "" })}><option value="">Kies een tijd</option>{endOptions.map((value) => <option key={value} value={value}>{new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</option>)}</select><small>Dit is de gewenste afronding van de hele avond, inclusief het bezoek aan de laatste poort. De organisatie gebruikt de gezamenlijke groepsvoorkeur als streeftijd.</small></label></section>}
    {step === 1 && <section><h2 ref={heading} tabIndex={-1}>Deelnemende kinderen</h2>{draft.children.map((child, index) => <div className="child-form" key={index}><div className="two-fields"><label className="field"><span>Voornaam kind {index + 1}</span><input value={child.name} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, name: event.target.value } : item) })} /></label><label className="field"><span>Leeftijd op 31 oktober</span><input type="number" min={0} max={20} value={child.age} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, age: event.target.value } : item) })} /></label></div><label className="field"><span>Drempelvrije route nodig?</span><select value={child.stepFreeRequired === null ? "review" : child.stepFreeRequired ? "yes" : "no"} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, stepFreeRequired: event.target.value === "review" ? null : event.target.value === "yes" } : item) })}><option value="review">Nog niet aangegeven</option><option value="no">Nee</option><option value="yes">Ja, zonder trappen of drempels</option></select><small>Geef dit apart aan; een andere bijzonderheid betekent niet automatisch dat een drempelvrije route nodig is.</small></label><label className="field"><span>Praktische toegankelijkheidswens (optioneel)</span><input value={child.accessibilityNote} maxLength={500} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, accessibilityNote: event.target.value } : item) })} /></label>{draft.children.length > 1 && <button className="text-link" type="button" onClick={() => setDraft({ ...draft, children: draft.children.filter((_, childIndex) => childIndex !== index) })}>Verwijder kind</button>}</div>)}<button className="btn outline" type="button" disabled={maximum===null||draft.children.length>=maximum} onClick={() => setDraft({ ...draft, children: [...draft.children, { name: "", age: "", accessibilityNote: "", stepFreeRequired: null }] })}>Nog een kind</button><label className="field together-code-field"><span>Samenloopcode (optioneel)</span><input className="together-code-input" value={draft.togetherCode} maxLength={4} inputMode="text" autoCapitalize="characters" autoCorrect="off" spellCheck={false} placeholder="Bijvoorbeeld K7MX" onChange={(event) => setDraft({ ...draft, togetherCode: normalizeTogetherCode(event.target.value) })} /><small>Heb je van een andere inschrijving een code van vier tekens gekregen? Vul die hier in. Laat het veld leeg als jullie zelfstandig inschrijven; daarna ontvangen jullie een eigen code om te delen.</small></label></section>}
    {step === 2 && <section><h2 ref={heading} tabIndex={-1}>Controleren</h2><div className="summary-row"><span>Volwassene</span><strong>{draft.adult.name}</strong></div><div className="summary-row"><span>E-mailadres</span><strong>{accountEmail || "Accountgegevens worden opgehaald…"}</strong></div><div className="summary-row"><span>Kinderen</span><strong>{draft.children.length}</strong></div><div className="summary-row"><span>Gewenste starttijd</span><strong>{draft.preferredStartAt ? new Date(draft.preferredStartAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "Maakt niet uit"}</strong></div><div className="summary-row"><span>Gewenst klaar, inclusief laatste poort</span><strong>{draft.desiredEndAt ? new Date(draft.desiredEndAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "Nog niet gekozen"}</strong></div>{draft.togetherCode && <div className="summary-row"><span>Samenloopcode</span><strong>{draft.togetherCode}</strong></div>}<div className="summary-row"><span>Totale bijdrage</span><strong>{total === null ? "Bedrag wordt opgehaald…" : `€ ${(total / 100).toFixed(2).replace(".", ",")}`}</strong></div><p>De bijdrage is bedoeld om waar nodig snoep te verdelen onder deelnemende huizen. Een groep bestaat uit maximaal {maximum??"het door de organisatie ingestelde aantal"} kinderen, inclusief aangesloten gezinnen.</p><label className="checkfield"><input type="checkbox" checked={termsAccepted} onChange={(event) => setTermsAccepted(event.target.checked)} /><span>Ik ga akkoord met de <Link href="/voorwaarden" target="_blank">voorwaarden</Link> en heb de <Link href="/privacy" target="_blank">privacy-informatie</Link> gelezen.</span></label><label className="checkfield"><input type="checkbox" checked={draft.marketingConsent} onChange={(event) => setDraft({ ...draft, marketingConsent: event.target.checked })} /><span>Ik ontvang graag niet-operationele updates (optioneel).</span></label>{!canSubmit && <p className="form-warning">De inschrijvingen zijn gesloten. Je concept blijft bewaard.</p>}</section>}
    {notice && <p ref={noticeElement} tabIndex={-1} className="form-notice" role={noticeIsError ? "alert" : "status"}>{notice}</p>}
    <div className="wizard-nav">{step > 0 && <button className="btn ghost" type="button" onClick={() => setStep(step - 1)}>Vorige</button>}{step < 2 ? <button className="btn" disabled={busy} type="button" onClick={() => void save(step + 1)}>{busy ? "Opslaan…" : "Opslaan en verder"}</button> : <button className="btn" disabled={busy || !canSubmit || !termsAccepted || priceCents === null} type="button" onClick={() => void submit()}>{busy ? "Verwerken…" : "Definitief inschrijven"}</button>}</div>
  </div>;
}
