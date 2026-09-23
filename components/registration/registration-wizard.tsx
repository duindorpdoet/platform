"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

type ChildDraft = { name: string; age: string; accessibilityNote: string };
type Draft = { adult: { name: string; phone: string }; children: ChildDraft[]; togetherPreference: string; marketingConsent: boolean };
type Snapshot = { draft?: { payload: Draft; version: number } | null; registration?: { id: string; reference: string; status: string; priceCents: number; version: number; payment?: { status: string; amountCents: number; externalUrl?: string; version: number } | null } | null };

const emptyDraft: Draft = { adult: { name: "", phone: "" }, children: [{ name: "", age: "", accessibilityNote: "" }], togetherPreference: "", marketingConsent: false };

async function digest(value: unknown) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((item) => item.toString(16).padStart(2, "0")).join("");
}

export function RegistrationWizard({ eventSlug, canSubmit }: { eventSlug: string; canSubmit: boolean }) {
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [version, setVersion] = useState<number | null>(null);
  const [registration, setRegistration] = useState<Snapshot["registration"]>(null);
  const [step, setStep] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [noticeIsError, setNoticeIsError] = useState(false);
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
  const total = useMemo(() => draft.children.length * 200, [draft.children.length]);

  useEffect(() => {
    const client = createClient();
    if (!client) return;
    void client.schema("api").rpc("registration_snapshot", { _event_slug: eventSlug }).then(({ data }: { data: unknown }) => {
      const snapshot = data as Snapshot | null;
      if (snapshot?.draft?.payload) { setDraft({ ...emptyDraft, ...snapshot.draft.payload, adult: { ...emptyDraft.adult, ...snapshot.draft.payload.adult }, togetherPreference: snapshot.draft.payload.togetherPreference ?? "" }); setVersion(snapshot.draft.version); }
      if (snapshot?.registration) setRegistration(snapshot.registration);
    });
  }, [eventSlug]);

  async function save(nextStep?: number) {
    const client = createClient();
    if (!client) return reportError("We kunnen je inschrijving nu niet openen. Probeer het zo nog eens.");
    if (!draft.adult.name.trim()) return reportError("Vul eerst de naam van de verantwoordelijke volwassene in.");
    if (nextStep === 2 && draft.children.some((child) => !child.name.trim() || !/^\d{1,2}$/.test(child.age) || Number(child.age) > 20)) return reportError("Vul voor ieder kind een naam en leeftijd in.");
    setBusy(true); setNotice(""); setNoticeIsError(false);
    const { data, error } = await client.schema("api").rpc("registration_save_draft", { _event_slug: eventSlug, _payload: draft, _expected_version: version });
    setBusy(false);
    if (error) return reportError(error.message.includes("STALE_VERSION") ? "Deze inschrijving is intussen veranderd. Vernieuw de pagina en kijk het nog even na." : "Opslaan is niet gelukt. Controleer de ingevulde gegevens.");
    setVersion((data as { version: number }).version);
    setNotice("Jullie gegevens zijn bewaard. Je kunt later verdergaan.");
    if (nextStep !== undefined) setStep(nextStep);
    return true;
  }

  async function submit() {
    if (!canSubmit) return reportError("De inschrijving opent zodra de avond en groepen definitief zijn.");
    if (draft.children.some((child) => !child.name.trim() || !/^\d{1,2}$/.test(child.age) || Number(child.age) > 20)) return reportError("Vul voor ieder kind een naam en geldige leeftijd in.");
    if (!await save()) return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    const key = crypto.randomUUID();
    const request = { eventSlug, terms: "2026-1", privacy: "2026-1", draft };
    const { data, error } = await client.schema("api").rpc("registration_submit", { _event_slug: eventSlug, _terms_version: "2026-1", _privacy_version: "2026-1", _idempotency_key: key, _request_hash: await digest(request) });
    setBusy(false);
    if (error) return reportError(error.message.includes("REGISTRATION_CLOSED") ? "De inschrijving is gesloten." : "Definitief inschrijven is niet gelukt. Probeer het nog eens.");
    setRegistration(data as Snapshot["registration"]);
    setStep(3);
  }

  if (registration) return <div className="panel success-panel" role="status"><p className="kicker">Jullie avontuur begint</p><h2 ref={heading} tabIndex={-1}>Welkom bij de poorten!</h2><p>De inschrijving van jullie gezin is ontvangen. Bewaar deze code voor vragen aan de organisatie:</p><div className="registration-code">{registration.reference}</div><p>Deelname: € {(registration.priceCents / 100).toFixed(2).replace(".", ",")} per kind. We laten weten wat de volgende stap is.</p><div className="actions"><Link className="btn" href="/mijn-inschrijving">Bekijk jullie inschrijving</Link></div></div>;

  return <div className="wizard panel">
    <div className="stepper" aria-label={`Stap ${step + 1} van 3`}><div className={step === 0 ? "active" : ""}><span>1</span><small>Volwassene</small></div><div className={step === 1 ? "active" : ""}><span>2</span><small>Kinderen</small></div><div className={step === 2 ? "active" : ""}><span>3</span><small>Controleren</small></div></div>
    {step === 0 && <section><h2 ref={heading} tabIndex={-1}>Wie loopt er mee?</h2><label className="field"><span>Naam verantwoordelijke volwassene</span><input value={draft.adult.name} onChange={(event) => setDraft({ ...draft, adult: { ...draft.adult, name: event.target.value } })} autoComplete="name" /></label><label className="field"><span>Telefoonnummer voor de avond</span><input value={draft.adult.phone} onChange={(event) => setDraft({ ...draft, adult: { ...draft.adult, phone: event.target.value } })} inputMode="tel" autoComplete="tel" /></label></section>}
    {step === 1 && <section><h2 ref={heading} tabIndex={-1}>Deelnemende kinderen</h2>{draft.children.map((child, index) => <div className="child-form" key={index}><div className="two-fields"><label className="field"><span>Voornaam kind {index + 1}</span><input value={child.name} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, name: event.target.value } : item) })} /></label><label className="field"><span>Leeftijd op 31 oktober</span><input type="number" min={0} max={20} value={child.age} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, age: event.target.value } : item) })} /></label></div><label className="field"><span>Praktische toegankelijkheidswens (optioneel)</span><input value={child.accessibilityNote} maxLength={500} onChange={(event) => setDraft({ ...draft, children: draft.children.map((item, childIndex) => childIndex === index ? { ...item, accessibilityNote: event.target.value } : item) })} /></label>{draft.children.length > 1 && <button className="text-link" type="button" onClick={() => setDraft({ ...draft, children: draft.children.filter((_, childIndex) => childIndex !== index) })}>Verwijder kind</button>}</div>)}<button className="btn outline" type="button" onClick={() => setDraft({ ...draft, children: [...draft.children, { name: "", age: "", accessibilityNote: "" }] })}>Nog een kind</button><label className="field"><span>Met wie zouden jullie graag samenlopen? (optioneel)</span><input value={draft.togetherPreference} maxLength={160} onChange={(event) => setDraft({ ...draft, togetherPreference: event.target.value })} /><small>Vul bijvoorbeeld de naam van een volwassene of een ontvangen samenloopcode in. Een wens is geen garantie; capaciteit en veiligheid blijven leidend.</small></label></section>}
    {step === 2 && <section><h2 ref={heading} tabIndex={-1}>Controleren</h2><div className="summary-row"><span>Volwassene</span><strong>{draft.adult.name}</strong></div><div className="summary-row"><span>Kinderen</span><strong>{draft.children.length}</strong></div><div className="summary-row"><span>Prijs</span><strong>€ {(total / 100).toFixed(2).replace(".", ",")}</strong></div><label className="checkfield"><input type="checkbox" checked={termsAccepted} onChange={(event) => setTermsAccepted(event.target.checked)} />Ik ga akkoord met de <Link href="/voorwaarden" target="_blank">voorwaarden</Link> en heb de <Link href="/privacy" target="_blank">privacy-informatie</Link> gelezen.</label><label className="checkfield"><input type="checkbox" checked={draft.marketingConsent} onChange={(event) => setDraft({ ...draft, marketingConsent: event.target.checked })} />Ik ontvang graag niet-operationele updates (optioneel).</label>{!canSubmit && <p className="form-warning">Inschrijving staat bewust gesloten totdat de organisatie de tijden en capaciteit publiceert. Je concept blijft bewaard.</p>}</section>}
    {notice && <p ref={noticeElement} tabIndex={-1} className="form-notice" role={noticeIsError ? "alert" : "status"}>{notice}</p>}
    <div className="wizard-nav">{step > 0 && <button className="btn ghost" type="button" onClick={() => setStep(step - 1)}>Vorige</button>}{step < 2 ? <button className="btn" disabled={busy} type="button" onClick={() => void save(step + 1)}>{busy ? "Opslaan…" : "Opslaan en verder"}</button> : <button className="btn" disabled={busy || !canSubmit || !termsAccepted} type="button" onClick={() => void submit()}>{busy ? "Verwerken…" : "Definitief inschrijven"}</button>}</div>
  </div>;
}
