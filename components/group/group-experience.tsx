"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { AlertTriangle, Camera, Check, CloudOff, LockKeyhole, MapPin, QrCode, RefreshCw, SkipForward } from "lucide-react";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots, readPrivateSnapshot, storePrivateSnapshot } from "@/lib/pwa/private-snapshot";

type RosterItem = { registrationChildId: string; firstName: string; householdLabel: string };
type Participant = { id: string; firstName: string; attendance: string; rosterVersion: number; isOwnChild: boolean; status: "pending" | "visited" | "skipped" | null; statusVersion: number | null; required: boolean | null };
type Snapshot = {
  group: { id: string; code: string; status: string; version: number; start?: { name: string; locationName: string; startsAt: string } };
  access: { leader: boolean; support: boolean };
  run: null | { id: string; status: string; version: number; lastServerConfirmation: string; remainingStopCount: number; currentStop: null | { id: string; sequence: number; version: number; openedAt: string; scanAccepted: boolean; portal: { name: string; description: string; intensity: number; operationStatus: string; world: string; address: string; postalCode: string; coordinate: [number, number] | null } }; participants: Participant[]; history: Array<{ sequence: number; outcome: string; completedAt: string; portalName: string; world: string }> };
};

function explain(error: { message?: string } | null) {
  const value = error?.message ?? "";
  if (value.includes("STALE_VERSION")) return "Deze stap is intussen veranderd. Kijk het scherm nog even na en probeer opnieuw.";
  if (value.includes("SCAN_REQUIRED")) return "Scan eerst de QR-code van deze poort.";
  if (value.includes("PENDING_PARTICIPANTS")) return "Geef voor ieder aanwezig kind aan: bezocht of overgeslagen.";
  if (value.includes("WRONG_PORTAL")) return "Deze code hoort niet bij de huidige poort of is verlopen.";
  if (value.includes("PORTAL_UNAVAILABLE")) return "Deze poort is gepauzeerd of gesloten; een nieuw bezoek kan niet worden vastgelegd.";
  if (value.includes("VISIT_ALREADY_RECORDED")) return "Er is al een bezoek vastgelegd; de poort kan niet meer als systeemskip worden overschreven.";
  return "Dat lukte nog niet. Controleer de poort en probeer opnieuw.";
}

export function GroupExperience({ groupId, userId }: { groupId: string; userId: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [roster, setRoster] = useState<RosterItem[]>([]);
  const [present, setPresent] = useState<Set<string>>(new Set());
  const [offline, setOffline] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [manualCode, setManualCode] = useState("");
  const [scannerOpen, setScannerOpen] = useState(false);
  const portalHeading = useRef<HTMLHeadingElement>(null);
  const previousStopId = useRef<string | null>(null);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("group_snapshot", { _group_id: groupId });
    if (error) {
      const cached = readPrivateSnapshot<Snapshot>(userId, groupId);
      if (cached) { setSnapshot(cached); setOffline(true); }
      return;
    }
    const next = data as Snapshot;
    setSnapshot(next); setOffline(false); storePrivateSnapshot(userId, groupId, next);
    if (!next.run && next.access.leader) {
      const rosterResult = await client.schema("api").rpc("group_roster", { _group_id: groupId });
      if (!rosterResult.error) {
        const items = rosterResult.data as RosterItem[];
        setRoster(items); setPresent(new Set(items.map((item) => item.registrationChildId)));
      }
    }
  }, [groupId, userId]);

  useEffect(() => {
    const client = createClient(); if (!client) return;
    const timer = window.setTimeout(() => void load(), 0);
    const channel = client.channel(`group:${groupId}`, { config: { private: true } }).on("broadcast", { event: "snapshot_changed" }, () => void load()).subscribe();
    const auth = client.auth.onAuthStateChange((_event: AuthChangeEvent, session: Session | null) => { if (!session || session.user.id !== userId) clearPrivateSnapshots(); });
    const reconnect = () => void load();
    window.addEventListener("online", reconnect);
    return () => { window.clearTimeout(timer); void client.removeChannel(channel); auth.data.subscription.unsubscribe(); window.removeEventListener("online", reconnect); };
  }, [groupId, userId, load]);

  useEffect(() => {
    const stopId = snapshot?.run?.currentStop?.id ?? null;
    if (stopId && previousStopId.current && previousStopId.current !== stopId) {
      portalHeading.current?.focus();
    }
    previousStopId.current = stopId;
  }, [snapshot?.run?.currentStop?.id]);

  async function command(name: string, args: Record<string, unknown>) {
    const client = createClient(); if (!client || offline) return;
    setBusy(true); setNotice("");
    const { error } = await client.schema("api").rpc(name, args);
    setBusy(false);
    if (error) setNotice(explain(error));
    await load();
  }

  if (!snapshot) return <div className="panel loading-state"><RefreshCw className="spin" /><p>Jullie groepsinformatie ophalen…</p></div>;
  const run = snapshot.run;
  const stop = run?.currentStop;

  return <div className="group-app">
    <div className="app-heading row-between"><div><p className="kicker">Groep {snapshot.group.code}</p><h1>Mijn groep</h1></div><button className="btn outline" onClick={() => void load()}><RefreshCw size={16} />Vernieuwen</button></div>
    {offline && <div className="offline-banner" role="alert"><CloudOff size={18} />Jullie zijn even offline. We bewaren jullie voortgang en gaan verder zodra de verbinding terug is.</div>}
    {notice && <div className="form-warning" role="status">{notice}</div>}
    {!run && <div className="pre-event"><div className="pre-art"><img src="/images/avondloop-hero.webp" alt="Verlichte Duindorpse straat in de avond" /><div><p className="kicker">Route nog vergrendeld</p><h2>{snapshot.group.start ? new Date(snapshot.group.start.startsAt).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short" }) : "Starttijd volgt"}</h2><p>{snapshot.group.start?.locationName ?? "De organisatie publiceert de startlocatie later."}</p></div></div><div className="panel"><h2>Controleer aanwezigheid</h2>{snapshot.access.leader ? <>{roster.map((item) => <label className="checkfield" key={item.registrationChildId}><input type="checkbox" checked={present.has(item.registrationChildId)} onChange={(event) => setPresent((current) => { const next = new Set(current); if (event.target.checked) next.add(item.registrationChildId); else next.delete(item.registrationChildId); return next; })} />{item.firstName} <small>· {item.householdLabel}</small></label>)}<button className="btn full" disabled={busy || offline || present.size === 0} onClick={() => void command("run_start", { _group_id: groupId, _present_registration_child_ids: [...present], _expected_group_version: snapshot.group.version, _idempotency_key: crypto.randomUUID(), _request_hash: [...present].sort().join(":") })}>Start groep met {present.size} aanwezig</button></> : <p>Alleen de aangewezen groepsleider kan de route starten. Tot die tijd blijven adressen verborgen.</p>}</div></div>}
    {run?.status === "completed" && <div className="finish-screen"><Check size={54} /><p className="kicker">De cirkel is rond</p><h2>Jullie zijn gefinisht.</h2><p>Alle bezochte en overgeslagen poorten staan in het logboek. Een overslag levert geen bezochte zegel op.</p></div>}
    {run?.status === "stopped" && <div className="finish-screen"><LockKeyhole size={54} /><p className="kicker">Route beëindigd</p><h2>Volg de organisatie-instructie.</h2><p>Er worden geen nieuwe poorten vrijgegeven. Neem bij direct gevaar contact op met de hulpdiensten.</p></div>}
    {run && !["completed", "stopped"].includes(run.status) && stop && <>
      <div className="live-topbar"><span>Stop {stop.sequence}</span><span>Nog {run.remainingStopCount} te gaan</span><span>Bijgewerkt om {new Date(run.lastServerConfirmation).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</span>{snapshot.access.leader && <button className="text-link" disabled={offline || busy} onClick={() => { const reason = run.status === "paused" ? "Groepsleider hervat de route" : window.prompt("Waarom pauzeer je de groep?")?.trim(); if (reason) void command("run_set_state", { _run_id: run.id, _state: run.status === "paused" ? "live" : "paused", _expected_version: run.version, _reason: reason }); }}>{run.status === "paused" ? "Route hervatten" : "Route pauzeren"}</button>}</div>
      {run.status === "paused" && <div className="offline-banner"><CloudOff size={18} />De groep is gepauzeerd. Scans en voortgang blijven geblokkeerd tot hervatten is bevestigd.</div>}
      <div className="live-grid"><section className="active-portal" aria-live="polite"><img src="/images/pluvierstraat.webp" alt="Sfeervol verlichte poort" /><div className="active-portal-copy"><p className="kicker">Huidige poort · {stop.portal.world}</p><h2 ref={portalHeading} tabIndex={-1}>{stop.portal.name}</h2><p>{stop.portal.description}</p><div className="portal-meta"><span><MapPin size={16} />{stop.portal.address}, {stop.portal.postalCode}</span><span>Spanning {stop.portal.intensity}/4</span></div>{stop.portal.operationStatus !== "open" && <div className="form-warning">Deze poort is tijdelijk {stop.portal.operationStatus}. Volg de instructie van de groepsleiding.</div>}</div></section><aside className="panel live-map-column"><LockKeyhole /><h3>De volgende stop blijft nog een verrassing</h3><p>Rond deze poort samen af. Daarna verschijnt vanzelf jullie volgende bestemming.</p></aside></div>
      {snapshot.access.leader && stop.portal.operationStatus === "closed" && <div className="panel emergency"><AlertTriangle /><h3>Poort door systeem overslaan</h3><p>Gebruik dit alleen nadat de sluiting met de bewoner of organisatie is afgestemd. Dit wordt apart gelogd en telt niet als vrijwillige kind-skip.</p><button className="btn outline" disabled={offline || busy} onClick={() => { const reason = window.prompt("Leg vast waarom deze gesloten poort systeemmatig wordt overgeslagen:")?.trim(); if (reason && reason.length >= 10 && window.confirm("Gesloten poort overslaan en precies de volgende bestemming vrijgeven?")) { const key = crypto.randomUUID(); void command("run_system_skip", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Gesloten poort overslaan</button></div>}
      {snapshot.access.leader && <div className="panel scan-panel"><h2>Bevestig de poort</h2><p>Scan de QR-code bij het huis. Werkt de camera niet, gebruik dan de korte code.</p><div className="actions"><button className="btn" disabled={offline || busy} onClick={() => setScannerOpen(true)}><Camera size={18} />QR scannen</button><input aria-label="Korte poortcode" value={manualCode} onChange={(event) => setManualCode(event.target.value.toUpperCase())} placeholder="Korte code" /><button className="btn outline" disabled={offline || busy || !manualCode} onClick={() => void command("run_scan", { _run_id: run.id, _expected_stop_id: stop.id, _expected_run_version: run.version, _credential: manualCode, _method: "short_code" })}>Code controleren</button></div>{stop.scanAccepted && <p className="success-line"><Check size={16} />Poort bevestigd. Jullie kunnen verder.</p>}</div>}
      <div className="panel participant-panel"><div className="row-between"><div><p className="kicker">Aanwezige kinderen</p><h2>Wie bezocht de poort?</h2></div><span className="status">{run.participants.filter((item) => item.status === "pending").length} open</span></div>{run.participants.map((participant) => <div className="participant-row" key={participant.id}><div className="avatar">{participant.firstName.slice(0, 1)}</div><div><strong>{participant.firstName}</strong><small>{participant.attendance}</small></div><span className={`status ${participant.status ?? "pending"}`}>{participant.status ?? "wachten"}</span><div className="participant-actions">{participant.status === "pending" && snapshot.access.leader && <button disabled={busy || offline || !stop.scanAccepted} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "visited", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}><Check size={14} />Bezocht</button>}{participant.status === "pending" && (snapshot.access.leader || participant.isOwnChild) && <button disabled={busy || offline} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "skipped", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: snapshot.access.leader ? "Bevestigd met ouder bij de poort" : null })}><SkipForward size={14} />Overslaan</button>}{participant.status === "skipped" && participant.isOwnChild && !snapshot.access.leader && <button disabled={busy || offline} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "pending", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}>Herstellen</button>}</div></div>)}{snapshot.access.leader && run.participants.some((item) => item.required && item.status === "pending") && <button className="btn outline full" disabled={busy || offline} onClick={() => { const reason = window.prompt("Bevestig waarom alle resterende kinderen deze poort overslaan:")?.trim(); if (reason && reason.length >= 10 && window.confirm("Alleen de nog wachtende kinderen op overgeslagen zetten? Bestaande bezoeken blijven staan.")) { const key = crypto.randomUUID(); void command("run_bulk_skip_pending", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Resterende kinderen overslaan</button>}{snapshot.access.leader && <button className="btn full" disabled={busy || offline || run.participants.some((item) => item.required && item.status === "pending")} onClick={() => { const allSkipped = run.participants.every((item) => !item.required || item.status === "skipped"); if (!allSkipped || window.confirm("Iedereen slaat deze poort over. Bevestig afronden zonder bezochte zegel.")) void command("run_complete_stop", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _all_skip_confirmed: allSkipped, _idempotency_key: crypto.randomUUID(), _request_hash: `${run.id}:${stop.id}:${run.version}:${allSkipped}` }); }}>Poort afronden</button>}</div>
      {scannerOpen && <QrScanner onCancel={() => setScannerOpen(false)} onResult={(value) => { setScannerOpen(false); void command("run_scan", { _run_id: run.id, _expected_stop_id: stop.id, _expected_run_version: run.version, _credential: value, _method: "qr" }); }} />}
    </>}
    {run && run.history.length > 0 && <div className="panel timeline"><p className="kicker">Logboek</p><h2>Afgeronde poorten</h2>{run.history.map((item) => <div className="summary-row" key={item.sequence}><span>{item.sequence}. {item.portalName} · {item.world}</span><strong>{item.outcome === "system_skipped" ? "Poort gesloten" : item.outcome === "all_skipped" ? "Overgeslagen" : item.outcome === "mixed" ? "Deels bezocht" : "Bezocht"}</strong></div>)}</div>}
  </div>;
}

function QrScanner({ onResult, onCancel }: { onResult: (value: string) => void; onCancel: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const resultHandler = useRef(onResult);
  const [error, setError] = useState("");
  useEffect(() => { resultHandler.current = onResult; }, [onResult]);
  useEffect(() => {
    let stopped = false;
    let stream: MediaStream | undefined;
    let controls: { stop: () => void } | undefined;
    const preview = video.current;
    function release() {
      controls?.stop();
      stream?.getTracks().forEach((track) => track.stop());
      if (preview) preview.srcObject = null;
    }
    void (async () => {
      try {
        const { BrowserQRCodeReader } = await import("@zxing/browser");
        if (stopped || !preview) return;
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" } } });
        if (stopped) { release(); return; }
        controls = await new BrowserQRCodeReader().decodeFromStream(stream, preview, (result) => {
          if (result && !stopped) resultHandler.current(result.getText());
        });
        if (stopped) release();
      } catch {
        release();
        if (!stopped) setError("Camera niet beschikbaar. Gebruik de korte code.");
      }
    })();
    return () => { stopped = true; release(); };
  }, []);
  return <div className="scanner-overlay" role="dialog" aria-modal="true" aria-label="QR-scanner"><div className="panel scanner-dialog"><QrCode size={28} /><h2>Scan de huidige poort</h2><video ref={video} className="scanner-video" muted playsInline />{error && <p className="form-warning">{error}</p>}<button className="btn outline" onClick={onCancel}>Sluiten</button></div></div>;
}
