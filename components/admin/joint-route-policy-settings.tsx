"use client";

import { useRef, useState } from "react";
import type { JointRoutePolicySettings } from "@/lib/domain/joint-route-policy";
import { AdminDialog } from "./admin-dialog";

export function JointRoutePolicySettingsForm({ eventSlug, disabled, onSaved }: { eventSlug: string; disabled: boolean; onSaved: () => Promise<void> }) {
  const [open, setOpen] = useState(false), [busy, setBusy] = useState(false);
  const [policy, setPolicy] = useState<JointRoutePolicySettings | null>(null);
  const [walking, setWalking] = useState("65"), [early, setEarly] = useState("30"), [targets, setTargets] = useState<string[]>([]);
  const [reason, setReason] = useState(""), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const pending = useRef(false), command = useRef<{ signature: string; key: string } | null>(null);
  async function load(preserve = false) {
    if (pending.current || disabled) return;
    pending.current = true; setBusy(true); setError(""); setOpen(true);
    try {
      const response = await fetch("/api/admin/routes/policy", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "get", eventSlug }), signal: AbortSignal.timeout(30_000) });
      const body = await response.json() as { data?: JointRoutePolicySettings; error?: { message?: string } };
      if (!response.ok || !body.data) { setError(body.error?.message ?? "Het actuele routebeleid kon niet worden geladen."); return; }
      setPolicy(body.data);
      if (!preserve) { setWalking(String(body.data.maxTotalWalkingSeconds / 60)); setEarly(String(body.data.maxEarlyFinishSeconds / 60)); setTargets(body.data.organizerCoveragePortalIds); setReason(""); }
      command.current = null;
    } catch { setError("Het ophalen is onderbroken. Je invoer blijft behouden."); }
    finally { pending.current = false; setBusy(false); }
  }
  const valid = Number.isInteger(Number(walking)) && Number(walking) >= 1 && Number(walking) <= 1440
    && Number.isInteger(Number(early)) && early.trim() !== "" && Number(early) >= 0 && Number(early) <= 1440;
  async function save() {
    if (!policy || !valid || reason.trim().length < 10 || pending.current || disabled) return;
    const body = { action: "save", eventSlug, expectedVersion: policy.version, maxTotalWalkingSeconds: Number(walking) * 60,
      maxEarlyFinishSeconds: Number(early) * 60, organizerCoveragePortalIds: targets, reason: reason.trim() };
    const signature = JSON.stringify(body);
    if (command.current?.signature !== signature) command.current = { signature, key: crypto.randomUUID() };
    pending.current = true; setBusy(true); setError("");
    try {
      const response = await fetch("/api/admin/routes/policy", { method: "POST", headers: { "Content-Type": "application/json", "idempotency-key": command.current.key }, body: signature, signal: AbortSignal.timeout(30_000) });
      const result = await response.json() as { data?: { version: number }; error?: { message?: string } };
      if (!response.ok || !result.data?.version) { setError(result.error?.message ?? "Het routebeleid is niet bevestigd. Je invoer blijft behouden."); return; }
      await onSaved(); setOpen(false); setNotice("Routebeleid opgeslagen. Bereken een nieuw gezamenlijk voorstel om routes en tijdsafspraken te beoordelen.");
    } catch { setError("Opslag is niet bevestigd. Herhaal dezelfde opdracht; je invoer blijft behouden."); }
    finally { pending.current = false; setBusy(false); }
  }
  return <>
    <button className="btn outline" type="button" disabled={disabled || busy} onClick={() => void load()}>Routebeleid instellen</button>
    {notice && <p role="status" className="form-notice">{notice}</p>}
    {open && <AdminDialog labelledBy="joint-route-policy-title" close={() => { if (!busy) setOpen(false); }}><section>
      <h2 id="joint-route-policy-title">Routebeleid instellen</h2>
      <p>Het totale loopbudget omvat de hele werkelijke route, inclusief de wandeling naar P-38. De vroegtegrens wordt getoetst op het einde van de finaleshow. Bij een ontbrekende gewenste eindtijd geldt geen ondergrens.</p>
      <p>Voor dit nieuwe beleid is maximaal 30 minuten eerder afronden als standaard voorgesteld. De ingestelde grens wordt hard gecontroleerd. De bestaande uitlooptolerantie blijft apart gelden.</p>
      {policy && <>
        <div className="settings-grid"><label className="field"><span>Totaal loopbudget per groep (minuten)</span><input type="number" min={1} max={1440} step={1} value={walking} disabled={busy} onChange={event => setWalking(event.target.value)}/></label>
          <label className="field"><span>Maximaal eerder klaar (minuten)</span><input type="number" min={0} max={1440} step={1} value={early} disabled={busy} onChange={event => setEarly(event.target.value)}/></label></div>
        <fieldset disabled={busy}><legend>Fysieke poorten als organisatiedoel</legend><p>De doelvariant probeert deze poorten bij zoveel mogelijk groepen in te plannen, in de hieronder getoonde volgorde. De vergelijking toont de afweging met andere bezoeken, lopen en wachten.</p>
          <p>Doelvolgorde: {targets.map(id => policy.portals.find(portal => portal.id === id)?.code ?? "onbekende poort").join(" → ") || "geen doelen"}</p>
          {policy.portals.filter(portal => portal.active && !portal.finale || targets.includes(portal.id)).map(portal => <label className="check-row" key={portal.id}><input type="checkbox" checked={targets.includes(portal.id)} onChange={event => setTargets(current => event.target.checked ? [...current, portal.id] : current.filter(id => id !== portal.id))}/><span>{portal.code} · {portal.name}{!portal.active || portal.finale ? " · momenteel niet beschikbaar; verwijder dit doel" : ""}</span></label>)}
        </fieldset>
        <label className="field"><span>Reden voor deze beleidswijziging</span><textarea value={reason} minLength={10} maxLength={500} disabled={busy} onChange={event => setReason(event.target.value)}/></label>
      </>}
      {error && <p className="form-warning" role="alert">{error}</p>}
      <div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={() => setOpen(false)}>Sluiten</button><button type="button" className="btn outline" disabled={busy || disabled} onClick={() => void load(true)}>Actuele versie ophalen; mijn invoer behouden</button><button type="button" className="btn" disabled={busy || disabled || !policy || !valid || reason.trim().length < 10} onClick={() => void save()}>{busy ? "Bezig…" : "Routebeleid opslaan"}</button></div>
    </section></AdminDialog>}
  </>;
}
