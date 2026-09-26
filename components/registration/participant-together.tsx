"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Request = {
  id: string; version: number; status: "pending" | "accepted" | "rejected" | "withdrawn";
  requestedCode: string; direction: "incoming" | "outgoing"; canWithdraw: boolean;
};
type Snapshot = {
  togetherCode: string; clusterReference: string | null; memberCount: number; confirmed: boolean;
  canRequest: boolean; locked: boolean; realtimeTopic: string; requests: Request[];
};
const statusLabels: Record<Request["status"], string> = {
  pending: "Aangevraagd · wacht op beoordeling", accepted: "Goedgekeurd", rejected: "Geweigerd", withdrawn: "Geannuleerd",
};
function errorLabel(message: string) {
  if (message.includes("INVALID_TOGETHER_CODE")) return "Deze samenloopcode is niet beschikbaar. Controleer de vier tekens; gebruik een code van een andere inschrijving.";
  if (message.includes("OPEN_TOGETHER_REQUEST")) return "Er staat al een verzoek open. Wacht op het besluit of trek jullie eigen verzoek eerst in.";
  if (message.includes("STALE_VERSION")) return "Het verzoek is inmiddels gewijzigd of beoordeeld. De actuele status is opgehaald.";
  if (message.includes("TOGETHER_LOCKED") || message.includes("TOGETHER_REQUEST_BLOCKED")) return "Dit verzoek kan niet direct worden ingediend vanwege de groepsindeling of groepsgrootte. Neem contact op met de organisatie.";
  return "De actie is niet bevestigd. Probeer het opnieuw.";
}

export function ParticipantTogether({ registrationId }: { registrationId: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [code, setCode] = useState(""); const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false); const pending = useRef(false);
  const [cancel, setCancel] = useState<Request | null>(null);
  const attempt = useRef({ code: "", key: "" });
  const requestSequence = useRef(0);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const sequence = ++requestSequence.current;
    const { data, error } = await client.schema("api").rpc("registration_together_snapshot", { _registration_id: registrationId });
    if (sequence !== requestSequence.current) return;
    if (!error) setSnapshot(data as Snapshot);
    else setNotice("Samenloopgegevens konden niet worden opgehaald. Probeer het opnieuw.");
  }, [registrationId]);
  useEffect(() => {
    const first = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 20_000);
    const refresh = () => { if (document.visibilityState === "visible") void load(); };
    window.addEventListener("focus", refresh);
    return () => { window.clearTimeout(first); window.clearInterval(poll); window.removeEventListener("focus", refresh); };
  }, [load]);
  useEffect(() => {
    const client = createClient(); if (!client || !snapshot?.realtimeTopic) return;
    const channel = client.channel(snapshot.realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load()).subscribe();
    return () => { void client.removeChannel(channel); };
  }, [load, snapshot?.realtimeTopic]);
  async function submit() {
    if (pending.current || !snapshot?.canRequest || !/^[A-HJ-NP-Z2-9]{4}$/.test(code)) return;
    const client = createClient(); if (!client) return;
    if (attempt.current.code !== code || !attempt.current.key) attempt.current = { code, key: crypto.randomUUID() };
    pending.current = true; setBusy(true);
    try {
      const { error } = await client.schema("api").rpc("registration_together_request", {
        _registration_id: registrationId, _together_code: code, _idempotency_key: attempt.current.key,
      });
      setNotice(error ? errorLabel(error.message) : "Jullie samenloopverzoek is ingediend. De organisatie beoordeelt het voordat jullie worden gekoppeld.");
      if (!error) { setCode(""); attempt.current = { code: "", key: "" }; }
      await load();
    } finally { pending.current = false; setBusy(false); }
  }
  async function withdraw() {
    if (!cancel || pending.current) return;
    const client = createClient(); if (!client) return;
    pending.current = true; setBusy(true);
    try {
      const { error } = await client.schema("api").rpc("together_join_request_withdraw", {
        _request_id: cancel.id, _expected_version: cancel.version, _reason: "Deelnemer trekt het samenloopverzoek in via de eigen omgeving",
      });
      setNotice(error ? errorLabel(error.message) : "Het samenloopverzoek is geannuleerd. Jullie inschrijving blijft geldig.");
      setCancel(null); attempt.current = { code: "", key: "" }; await load();
    } finally { pending.current = false; setBusy(false); }
  }
  return <section className="panel participant-card together-code-card participant-together" aria-label="Jullie samenloop">
    <p className="kicker">Samen lopen</p><h2>Jullie samenloop</h2>
    {notice && <p className="form-notice" role="status">{notice}</p>}
    {!snapshot ? <p>Samenloopgegevens ophalen…</p> : <>
      <p>Jullie samenloopcode: <strong className="registration-code together-share-code" aria-label={`Samenloopcode ${snapshot.togetherCode}`}>{snapshot.togetherCode}</strong></p>
      <p>Deel deze viertekencode met bekenden. Zij kunnen hem tijdens of na hun inschrijving indienen. De organisatie beoordeelt elk verzoek.</p>
      {snapshot.confirmed && <div className="form-notice"><strong>Samenloop bevestigd</strong>{snapshot.clusterReference && <p>Samenloopnummer: <strong>{snapshot.clusterReference}</strong></p>}<p>{snapshot.memberCount} inschrijvingen lopen na goedkeuring samen.</p></div>}
      {snapshot.requests.map((request) => <article className="participant-together-request" key={request.id} data-request-id={request.id}>
        <strong>{statusLabels[request.status]}</strong>
        <p>{request.direction === "outgoing" ? `Jullie verzoek om samen te lopen met code ${request.requestedCode}.` : "Een andere inschrijving heeft gevraagd om bij jullie aan te sluiten."}</p>
        {request.status === "pending" && <p>Tot goedkeuring blijven de inschrijvingen apart.</p>}
        {request.status === "rejected" && <p>Jullie eigen inschrijving blijft geldig. Jullie kunnen een andere code indienen.</p>}
        {request.status === "withdrawn" && <p>Dit verzoek is ingetrokken. Jullie inschrijving is niet geannuleerd.</p>}
        {request.canWithdraw && <button className="btn outline" type="button" disabled={busy} onClick={() => setCancel(request)}>Verzoek annuleren</button>}
      </article>)}
      {cancel && <div className="participant-together-request" role="group" aria-label="Annuleren bevestigen"><p>Willen jullie het open verzoek bij code {cancel.requestedCode} intrekken? Jullie inschrijving blijft geldig.</p><div className="actions"><button className="btn outline" type="button" disabled={busy} onClick={() => setCancel(null)}>Verzoek behouden</button><button className="btn" type="button" disabled={busy} onClick={() => void withdraw()}>Ja, verzoek intrekken</button></div></div>}
      {snapshot.canRequest && <form onSubmit={(event) => { event.preventDefault(); void submit(); }}><label className="field"><span>Samenloopcode van een andere inschrijving</span><input value={code} required pattern="[A-HJ-NP-Z2-9]{4}" maxLength={4} autoCapitalize="characters" autoCorrect="off" spellCheck={false} placeholder="Bijvoorbeeld X7K9" disabled={busy} onChange={(event) => setCode(event.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ""))} /></label><p>De organisatie controleert de groepsgrootte en indeling. Een code indienen koppelt jullie nog niet.</p><button type="submit" className="btn" disabled={busy || !/^[A-HJ-NP-Z2-9]{4}$/.test(code)}>Samenloop aanvragen</button></form>}
      {snapshot.locked && <p>De groepsindeling staat vast of is vergrendeld. Neem contact op met de organisatie als jullie iets willen wijzigen.</p>}
    </>}
  </section>;
}
