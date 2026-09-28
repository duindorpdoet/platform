"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Plus, RefreshCw, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { AdminDialog } from "@/components/admin/admin-dialog";
import {
  groupLabel, matchingMembers, partyIdentity, partyPreference, togetherError, togetherProblemLabels,
  type TogetherParty, type TogetherPreview, type TogetherRequest, type TogetherSnapshot,
} from "@/lib/domain/together-management";

export function TogetherManagement({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<TogetherSnapshot | null>(null);
  const [tab, setTab] = useState<"confirmed" | "requests" | "problems">("confirmed");
  const [query, setQuery] = useState("");
  const [offset, setOffset] = useState(0);
  const [notice, setNotice] = useState("");
  const [linkOpen, setLinkOpen] = useState(false);
  const [decision, setDecision] = useState<{ request: TogetherRequest; value: "accept" | "reject" } | null>(null);
  const sequence = useRef(0);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const current = ++sequence.current;
    const { data, error } = await client.schema("api").rpc("admin_together_management_snapshot", {
      _event_slug: eventSlug, _query: query, _limit: 50, _offset: offset,
    });
    if (current !== sequence.current) return;
    if (error) setNotice(togetherError(error.message));
    else setSnapshot(data as TogetherSnapshot);
  }, [eventSlug, offset, query]);
  const invalidate = useCallback(() => { sequence.current++; }, []);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 200);
    const poll = window.setInterval(() => void load(), 30_000);
    return () => { window.clearTimeout(timer); window.clearInterval(poll); invalidate(); };
  }, [invalidate, load]);
  useEffect(() => {
    const client = createClient();
    if (!client || !snapshot?.realtimeTopic) return;
    const channel = client.channel(snapshot.realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load()).subscribe();
    return () => { void client.removeChannel(channel); };
  }, [load, snapshot?.realtimeTopic]);
  const complete = (message: string) => {
    setLinkOpen(false); setDecision(null); setNotice(message); void load();
  };
  return <section className="panel together-management" aria-label="Samenloopbeheer"><header className="workspace-heading"><div><p className="kicker">Samen op pad</p><h2>Samenloop</h2><p>Houd vrienden bij elkaar en beoordeel nieuwe verzoeken.</p></div></header>
    <div className="row-between together-toolbar">
      <label className="field"><span>Zoeken</span><input type="search" maxLength={200} value={query} onChange={(event) => { setQuery(event.target.value); setOffset(0); }} placeholder="Zoek op samenloopnummer, inschrijfnummer, samenloopcode, ouder, e-mail of kind…" /></label>
      <div className="actions"><button type="button" className="btn outline" aria-label="Samenlopen vernieuwen" onClick={() => void load()}><RefreshCw /></button><button type="button" className="btn" onClick={() => setLinkOpen(true)}><Plus />Samenloop koppelen</button></div>
    </div>
    {notice && <p role="status" className="form-notice">{notice}</p>}
    <div className="actions together-tabs" aria-label="Samenloopweergave">
      {([["confirmed", "Bevestigde samenlopen"], ["requests", "Open verzoeken"], ["problems", "Problemen"]] as const).map(([key, label]) => <button type="button" key={key} className={`btn ${tab === key ? "" : "outline"}`} aria-pressed={tab === key} onClick={() => { setTab(key); setOffset(0); }}>{label}{snapshot ? ` (${snapshot.totals[key]})` : ""}</button>)}
    </div>
    {!snapshot ? <p role="status">Samenlopen ophalen…</p> : <>
      {tab === "problems" && <p>Bekijk deze samenlopen nog even. Open de details om te zien wat aandacht nodig heeft.</p>}
      {snapshot[tab].length === 0 && <p>Geen {tab === "confirmed" ? "bevestigde samenlopen" : tab === "requests" ? "open verzoeken" : "problemen"} gevonden.</p>}
      {tab !== "requests" ? snapshot[tab].map((party) => <PartyCard key={party.partyId} party={party} query={query} showProblems={tab === "problems"} />) : snapshot.requests.map((request) => <article className="together-card" key={request.id}>
        <strong>{request.registrationReference} wil aansluiten bij samenloopcode {request.requestedCode}</strong>
        <div className="together-preview-columns"><div><h3>Bron</h3>{request.source ? <PartySummary party={request.source} /> : <p>Bron is niet meer actief.</p>}</div><div><h3>Doel</h3>{request.target ? <PartySummary party={request.target} /> : <p>Doel is niet meer actief.</p>}</div></div>
        <p>Na acceptatie: {request.projectedChildren} kinderen · limiet {snapshot.maxGroupSize}</p>
        <div className="actions"><button type="button" className="btn" disabled={request.projectedChildren > 20 || !request.source || !request.target || request.source.locked || request.target.locked} onClick={() => setDecision({ request, value: "accept" })}>{request.projectedChildren > snapshot.maxGroupSize ? "Accepteren met uitzondering" : "Accepteren"}</button><button type="button" className="btn outline" onClick={() => setDecision({ request, value: "reject" })}>Afwijzen</button></div>
      </article>)}
      {snapshot.totals[tab] > 50 && <div className="actions"><button type="button" className="btn outline" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - 50))}>Vorige</button><span>{offset + 1}–{Math.min(offset + 50, snapshot.totals[tab])} van {snapshot.totals[tab]}</span><button type="button" className="btn outline" disabled={offset + 50 >= snapshot.totals[tab]} onClick={() => setOffset(offset + 50)}>Volgende</button></div>}
    </>}
    {linkOpen && <LinkDialog eventSlug={eventSlug} close={() => setLinkOpen(false)} complete={complete} />}
    {decision && snapshot && <DecisionDialog decision={decision} maxGroupSize={snapshot.maxGroupSize} close={() => setDecision(null)} complete={complete} />}
  </section>;
}

function PartySummary({ party }: { party: TogetherParty }) {
  return <div className="together-summary"><strong>{partyIdentity(party)}</strong><span>{party.memberCount} inschrijvingen · {party.childCount} kinderen</span><span>{groupLabel(party)}</span><small>{partyPreference(party)}</small>{party.locked && <small>Vergrendeld</small>}{party.published && <small>Gepubliceerd</small>}</div>;
}
function PartyCard({ party, query, showProblems }: { party: TogetherParty; query: string; showProblems: boolean }) {
  const matches = matchingMembers(party, query);
  return <details className="together-card" data-party-id={party.partyId}><summary><PartySummary party={party} />{party.memberCount > 1 && <small>Samenloop bevestigd</small>}{matches.length > 0 && <small>Gevonden via: {matches.join(", ")}</small>}<span className="text-link">Leden en details</span></summary>
    {showProblems && <ul className="form-warning">{party.problems.map((problem) => <li key={problem}>{togetherProblemLabels[problem] ?? problem}</li>)}</ul>}
    <div className="together-members">{party.members.map((member) => <article key={member.id}><strong>{member.reference}</strong><span>{member.parentName || member.householdLabel}</span><span>{member.childCount} kinderen · Samenloopcode: <b>{member.togetherCode}</b></span>{member.parentEmail && <span>{member.parentEmail}</span>}<ul>{member.children.map((child, index) => <li key={`${child.name}-${index}`}>{child.name}{child.age !== null ? ` · ${child.age} jaar` : ""}</li>)}</ul></article>)}</div>
  </details>;
}

function LinkDialog({ eventSlug, close, complete }: { eventSlug: string; close: () => void; complete: (message: string) => void }) {
  const [source, setSource] = useState(""); const [target, setTarget] = useState("");
  const [preview, setPreview] = useState<TogetherPreview | null>(null);
  const [reason, setReason] = useState(""); const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false); const pending = useRef(false);
  const key = useRef("");
  const previewHeading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { if (preview) previewHeading.current?.focus(); }, [preview]);
  async function check() {
    if (pending.current) return;
    const client = createClient(); if (!client) return;
    pending.current = true; setBusy(true); setNotice("");
    try {
      const [s, t] = await Promise.all([source, target].map((_identifier) => client.schema("api").rpc("admin_together_resolve_identifier", { _event_slug: eventSlug, _identifier })));
      if (s.error || t.error) { setNotice(togetherError((s.error ?? t.error)!.message)); return; }
      const result = await client.schema("api").rpc("admin_together_merge_preview", { _event_slug: eventSlug, _source_party_id: s.data.partyId, _target_party_id: t.data.partyId });
      if (result.error) setNotice(togetherError(result.error.message));
      else { setPreview(result.data as TogetherPreview); key.current = crypto.randomUUID(); }
    } finally { pending.current = false; setBusy(false); }
  }
  async function confirm() {
    if (!preview?.canMerge || pending.current || reason.trim().length < 10) return;
    const client = createClient(); if (!client) return;
    pending.current = true; setBusy(true); setNotice("");
    try {
      const { data, error } = await client.schema("api").rpc("admin_merge_together_parties", {
        _event_slug: eventSlug, _source_party_id: preview.source.partyId, _target_party_id: preview.target.partyId,
        _expected_source_state: preview.source.stateToken, _expected_target_state: preview.target.stateToken,
        _reason: reason.trim(), _idempotency_key: key.current,
      });
      if (error) { setNotice(togetherError(error.message)); if (/STALE_VERSION|MERGE_BLOCKED/.test(error.message)) setPreview(null); }
      else complete(`Samenloop gekoppeld: ${data.clusterReference}`);
    } finally { pending.current = false; setBusy(false); }
  }
  return <AdminDialog labelledBy="together-link-title" close={() => { if (!pending.current) close(); }}><button className="group-dialog-close" type="button" aria-label="Sluiten" disabled={busy} onClick={close}><X /></button><h2 ref={previewHeading} tabIndex={-1} id="together-link-title">{preview ? "Samenloop controleren" : "Samenloop koppelen"}</h2>
    {notice && <p role="alert" className="form-warning">{notice}</p>}
    {!preview ? <form onSubmit={(event) => { event.preventDefault(); void check(); }}><p>Gebruik een inschrijfnummer, viertekencode of samenloopnummer.</p><label>Bron<input data-initial-focus required disabled={busy} maxLength={80} value={source} onChange={(event) => setSource(event.target.value)} placeholder="DPH-2026-… / X7K9 / SL-2026-…" /></label><label>Doel<input required disabled={busy} maxLength={80} value={target} onChange={(event) => setTarget(event.target.value)} /></label><div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={close}>Annuleren</button><button type="submit" className="btn" disabled={busy}>Controleren</button></div></form> : <form onSubmit={(event) => { event.preventDefault(); void confirm(); }}>
      <div className="together-preview-columns"><div><h3>Bron</h3><PartySummary party={preview.source} /></div><div><h3>Doel</h3><PartySummary party={preview.target} /></div></div>
      <div><h3>Resultaat</h3><p>{preview.projectedRegistrations} inschrijvingen · {preview.projectedChildren} kinderen · limiet {preview.maxGroupSize}</p></div>
      {preview.canMerge ? <ul><li>Zelfde evenement</li><li>Binnen groepslimiet</li><li>Geen gepubliceerde of vergrendelde indeling</li><li>De groepsindeling hoeft niet te veranderen</li></ul> : <div role="alert"><strong>Niet mogelijk</strong><ul>{preview.blockers.map((blocker) => <li key={blocker}>{togetherProblemLabels[blocker] ?? blocker}</li>)}</ul></div>}
      {preview.canMerge && <label>Reden<textarea required minLength={10} maxLength={500} disabled={busy} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Bijvoorbeeld: gekoppeld na verzoek per e-mail" /></label>}
      <div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={close}>Annuleren</button><button type="button" className="btn outline" disabled={busy} onClick={() => setPreview(null)}>Wijzigen</button>{preview.canMerge && <button type="submit" className="btn" disabled={busy || reason.trim().length < 10}>Bevestigen en koppelen</button>}</div>
    </form>}
  </AdminDialog>;
}

function DecisionDialog({ decision, maxGroupSize, close, complete }: { decision: { request: TogetherRequest; value: "accept" | "reject" }; maxGroupSize: number; close: () => void; complete: (message: string) => void }) {
  const [reason, setReason] = useState(""); const [override, setOverride] = useState(false); const [busy, setBusy] = useState(false); const [notice, setNotice] = useState(""); const pending = useRef(false);
  const needsOverride = decision.value === "accept" && decision.request.projectedChildren > maxGroupSize;
  async function submit() {
    if (pending.current || (needsOverride && !override)) return;
    const client = createClient(); if (!client) return;
    pending.current = true; setBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_decide_together_request", { _request_id: decision.request.id, _expected_version: decision.request.version, _decision: decision.value, _override_limit: needsOverride && override, _reason: reason });
      if (error) setNotice(togetherError(error.message)); else complete(decision.value === "accept" ? "Samenloopverzoek geaccepteerd." : "Samenloopverzoek afgewezen.");
    } finally { pending.current = false; setBusy(false); }
  }
  return <AdminDialog labelledBy="together-decision-title" close={() => { if (!pending.current) close(); }}><h2 id="together-decision-title">Samenloopverzoek {decision.value === "accept" ? "accepteren" : "afwijzen"}</h2><form onSubmit={(event) => { event.preventDefault(); void submit(); }}><p>{decision.request.registrationReference} · {decision.request.projectedChildren} kinderen</p>{notice && <p role="alert">{notice}</p>}{needsOverride && <label><input type="checkbox" checked={override} onChange={(event) => setOverride(event.target.checked)} />Ik bevestig een uitzondering op de limiet van {maxGroupSize} kinderen en leg de veiligheidsafweging vast.</label>}<label>Reden<textarea data-initial-focus required minLength={10} maxLength={500} value={reason} disabled={busy} onChange={(event) => setReason(event.target.value)} /></label><div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={close}>Annuleren</button><button type="submit" className="btn" disabled={busy || reason.trim().length < 10 || (needsOverride && !override)}>Besluit bevestigen</button></div></form></AdminDialog>;
}
