"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Snapshot = { registration?: { id: string; reference: string; status: string; priceCents: number; version: number; payment?: { status: string; amountCents: number; externalUrl?: string; version: number } | null } | null };
type PartySnapshot = { registrationId: string; party: null | { id: string; label: string; memberCount: number; locked: boolean } };

export function RegistrationDashboard({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [party, setParty] = useState<PartySnapshot | null>(null);
  const [label, setLabel] = useState("");
  const [code, setCode] = useState("");
  const [createdCode, setCreatedCode] = useState("");
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const [registrationResult, partyResult] = await Promise.all([
      client.schema("api").rpc("registration_snapshot", { _event_slug: eventSlug }),
      client.schema("api").rpc("together_snapshot", { _event_slug: eventSlug }),
    ]);
    if (!registrationResult.error) setSnapshot(registrationResult.data as Snapshot);
    if (!partyResult.error) setParty(partyResult.data as PartySnapshot | null);
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  const registration = snapshot?.registration;
  if (!snapshot) return <div className="panel">Inschrijving veilig ophalen…</div>;
  if (!registration) return <div className="panel empty-state"><h2>Geen definitieve inschrijving</h2><p>Je kunt een concept starten via ‘Meelopen’.</p></div>;
  async function reportPayment() {
    const current = snapshot?.registration;
    const client = createClient(); if (!client || !current?.payment) return;
    const { error } = await client.schema("api").rpc("registration_report_payment", { _registration_id: current.id, _expected_version: current.payment.version });
    setNotice(error ? "De betaalmelding kon niet worden verwerkt." : "Je melding is opgeslagen. De organisatie controleert de betaling handmatig.");
    await load();
  }
  async function createParty() {
    const client = createClient(); if (!client || !party?.registrationId) return;
    const { data, error } = await client.schema("api").rpc("together_create", { _registration_id: party.registrationId, _label: label });
    if (error) return setNotice("Samenloopgroep maken is niet gelukt.");
    setCreatedCode((data as { inviteCode: string }).inviteCode); setNotice("De samenloopwens is opgeslagen. Deel de code veilig met het andere huishouden."); await load();
  }
  async function joinParty() {
    const client = createClient(); if (!client || !party?.registrationId) return;
    const { error } = await client.schema("api").rpc("together_join", { _registration_id: party.registrationId, _invite_code: code });
    setNotice(error ? "De code is ongeldig, verlopen of al gebruikt voor jouw inschrijving." : "Je samenloopwens is gekoppeld."); await load();
  }
  return <div className="dashboard-stack"><section className="panel"><p className="kicker">Referentie</p><h1>{registration.reference}</h1><div className="summary-row"><span>Inschrijving</span><strong>{registration.status}</strong></div><div className="summary-row"><span>Totaal</span><strong>€ {(registration.priceCents / 100).toFixed(2).replace(".", ",")}</strong></div><div className="summary-row"><span>Betaling</span><strong>{registration.payment?.status ?? "wordt voorbereid"}</strong></div>{registration.payment?.externalUrl && <a className="btn" href={registration.payment.externalUrl} rel="noreferrer">Open de Tikkie-link</a>}{registration.payment && ["awaiting_link", "awaiting_payment"].includes(registration.payment.status) && <button className="btn outline" onClick={() => void reportPayment()}>Ik heb betaald</button>}<p className="note">Alleen een bevoegde organisator kan een betaling bevestigen. Een melding van jou is nog geen bevestiging.</p></section><section className="panel"><p className="kicker">Samen lopen</p><h2>Samenloopwens</h2>{party?.party ? <><p>Je bent gekoppeld aan <strong>{party.party.label}</strong> met {party.party.memberCount} inschrijving(en).</p>{createdCode && <div className="registration-code">{createdCode}</div>}<p className="note">De routeplanner houdt de wens bij elkaar zolang capaciteit en veiligheid dat toelaten.</p></> : <><label className="field"><span>Nieuwe samenloopgroep</span><input value={label} onChange={(event) => setLabel(event.target.value)} placeholder="Bijvoorbeeld: Familie aan zee" /></label><button className="btn outline" disabled={!label.trim()} onClick={() => void createParty()}>Maak uitnodigingscode</button><div className="separator" /><label className="field"><span>Ontvangen code</span><input value={code} onChange={(event) => setCode(event.target.value.toUpperCase())} /></label><button className="btn outline" disabled={!code.trim()} onClick={() => void joinParty()}>Koppel samenloopwens</button></>}{notice && <p className="form-notice" role="status">{notice}</p>}</section></div>;
}
