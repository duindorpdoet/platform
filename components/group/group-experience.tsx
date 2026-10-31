"use client";

import { useSnapshotRefresh } from "@/lib/realtime/use-snapshot-refresh";
import { useSnapshotLoader } from "@/lib/realtime/use-snapshot-loader";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { useRouter } from "next/navigation";
import { groupAccessDenied } from "@/lib/domain/group-access";
import { useCallback, useEffect, useRef, useState } from "react";
import "./group-experience.css";
import "../../modern/route.css";
import { AlertTriangle, ArrowRight, Camera, Check, CheckCircle2, Clock3, CloudOff, Footprints, LockKeyhole, MapPin, QrCode, RefreshCw, SkipForward, Users } from "lucide-react";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots, readPrivateSnapshot, storePrivateSnapshot } from "@/lib/pwa/private-snapshot";
import { GroupJourneyPreference } from "@/components/group/group-journey-preference";
import { ReleasedDestination } from "@/components/group/released-destination";
import { attendanceSummary, reconcileAttendance, type AttendanceDecision } from "@/lib/domain/attendance-check";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { parseGateCredential } from "@/lib/redesign/gate-credentials";
import { configureArrivalSync, clearArrivalMemory, hasWaitingArrival, isArrivalConnected, submitArrival } from "@/lib/redesign/arrival-sync";
import { ArrivalSyncNotice, useArrivalSync } from "@/components/redesign/arrival-sync-ui";
import { EarlyDeparture } from "@/components/redesign/early-departure";
import { QrScanner } from "@/components/redesign/qr-scanner";
import {DuinpadExperience} from "@/components/duinpad/experience";
import { FamilyPortalThanks } from "@/components/redesign/portal-thanks";

type Arrival = { credential: string; portalId?: string; stopId: string; runId: string; runVersion: number; method: string; portalName: string; finale: boolean; choices: Record<string, "visited" | "skipped">; participants: Participant[] };

type RosterItem = { registrationChildId: string; firstName: string; householdLabel: string };
type Participant = { id: string; childId: string; firstName: string; attendance: string; rosterVersion: number; isOwnChild: boolean; status: "pending" | "visited" | "skipped" | null; statusVersion: number | null; required: boolean | null };
type Snapshot = {
  duinpadFinale?: {eveningEnded:boolean;eligible?:boolean;recorded?:boolean};
  eventId: string;
  group: {
    id: string;
    code: string;
    status: string;
    version: number;
    routeMode: "legacy" | "dynamic";
    effectiveOrdinaryStopAt: string | null;
    expectedFinaleArrivalAt: string | null;
    start?: { name: string; locationName: string; address: string; startsAt: string; coordinate?: [number, number] | null; locationSource?: string; arrivalInstructions?: string | null; safeApproach?: string | null; queueNumber?: number | null; addressReleased?:boolean; addressReleaseAt?:string; canStart?:boolean };
  };
  access: { leader: boolean; support: boolean };
  run: null | {
    id: string;
    status: string;
    version: number;
    lastServerConfirmation: string;
    emergencyInstruction: string | null;
    elapsedSeconds: number;
    remainingStopCount: number | null;
    waitingInstruction: boolean;
    currentStop: null | { id: string; sequence: number; version: number; kind: "ordinary" | "finale"; openedAt: string; reservedArrivalAt: string | null; scanAccepted: boolean; portal: { id: string; systemCode?: string; name: string; description: string; intensity: number; operationStatus: string; world: string; address: string; postalCode: string; city?: string; publicEntranceInstructions?: string | null; locationSource?: string; coordinate: [number, number] | null } };
    participants: Participant[];
    ownEveningFinished?: boolean;
    duinpadEveningEnded?: boolean;
    endedEarly?: boolean;
    farewells?: Record<string, {endedAt: string; reason: string}>;
    history: Array<{ sequence: number; kind?: "ordinary" | "finale"; outcome: string; completedAt: string; portalName: string; world: string; arrivalConfirmed?: boolean }>;
  };
};

function scrollToRouteStep(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth", block: "start" });
}

function explain(error: { message?: string } | null) {
  const value = error?.message ?? "";
  if (value.includes("STALE_VERSION")) return "Deze stap is intussen veranderd. Kijk het scherm nog even na en probeer opnieuw.";
  if (value.includes("SCAN_REQUIRED")) return "Scan eerst de QR-code van deze poort.";
  if (value.includes("PENDING_PARTICIPANTS")) return "Geef voor ieder aanwezig kind aan: bezocht of overgeslagen.";
  if (value.includes("WRONG_PORTAL")) return "Deze code hoort niet bij de huidige poort of is verlopen.";
  if (value.includes("PORTAL_UNAVAILABLE")) return "Deze poort is gepauzeerd of gesloten; een nieuw bezoek kan niet worden vastgelegd.";
  if (value.includes("START_TIME_NOT_REACHED")) return "Jullie toegewezen starttijd is nog niet bereikt.";
  if (value.includes("FINAL_PORTAL_REQUIRED")) return "Bevestig de aankomst bij de laatste poort of vraag de organisatie om hulp. Meedoen aan de beleving hoeft niet.";
  if (value.includes("FINALE_CAPACITY_UNAVAILABLE")) return "We zoeken een nieuw aankomstmoment bij de laatste poort. Blijf bij elkaar en wacht op het volgende bericht.";
  if (value.includes("VISIT_ALREADY_RECORDED")) return "Er is al een bezoek vastgelegd; de poort kan niet meer als systeemskip worden overschreven.";
  return "Dat lukte nog niet. Controleer de poort en probeer opnieuw.";
}

export function GroupExperience({ groupId, userId }: { groupId: string; userId: string }) {
  const router = useRouter();
  const sync = useArrivalSync();
  const waitingForArrival = hasWaitingArrival();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [roster, setRoster] = useState<RosterItem[]>([]);
  const [attendance, setAttendance] = useState<Record<string, AttendanceDecision>>({});
  const [offline, setOffline] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [manualCode, setManualCode] = useState("");
  const [scannerOpen, setScannerOpen] = useState(false);
  const [arrival, setArrival] = useState<Arrival | null>(null);
  const [arrivalError, setArrivalError] = useState("");
  const consumedLink = useRef("");
  const portalHeading = useRef<HTMLHeadingElement>(null);
  const previousStopId = useRef<string | null>(null);
  const sourceGeneration = useRef(0);
  const invalidateSource = useCallback(() => { sourceGeneration.current++; }, []);

  const { load, invalidate } = useSnapshotLoader(useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const generation = sourceGeneration.current;
    const { data, error } = await client.schema("api").rpc("group_snapshot", { _group_id: groupId }).abortSignal(AbortSignal.timeout(8_000));
    if (generation !== sourceGeneration.current) return;
    if (error) {
      if (groupAccessDenied(error)) {
        clearPrivateSnapshots(); clearArrivalMemory();
        setSnapshot(null); setRoster([]); setArrival(null); setOffline(false);
        setNotice("Jullie groepsindeling of toegang is gewijzigd. De actuele omgeving wordt opgehaald.");
        router.refresh();
        return;
      }
      const cached = readPrivateSnapshot<Snapshot>(userId, groupId);
      if (cached) { setSnapshot(cached); setOffline(true); }
      return;
    }
    const next = data as Snapshot;
    setSnapshot(next); setOffline(!isArrivalConnected()); try { storePrivateSnapshot(userId, groupId, next); } catch { /* Route remains available; an arrival is only called saved after its own durable write. */ }
    try { await configureArrivalSync({accountId:userId,eventId:next.eventId,groupId}); } catch { setNotice("Een bewaarde aankomst vraagt herstelcontrole. Houd deze telefoon bij je en neem contact op met de organisatie."); }
    if (!next.run && next.access.leader) {
      const rosterResult = await client.schema("api").rpc("group_roster", { _group_id: groupId }).abortSignal(AbortSignal.timeout(8_000));
      if (generation !== sourceGeneration.current) return;
      if (!rosterResult.error) {
        const items = rosterResult.data as RosterItem[];
        setRoster(items);
        setAttendance((current) => reconcileAttendance(items.map((item) => item.registrationChildId), current));
      }
    }
  }, [groupId, userId, router]));
  useSnapshotRefresh(load);
  usePrivateBroadcast(`group:${groupId}`, invalidate);

  useEffect(() => {
    const client = createClient(); if (!client) return;
    const timer = window.setTimeout(() => void load(), 0);
    const auth = client.auth.onAuthStateChange((_event: AuthChangeEvent, session: Session | null) => { if (!session || session.user.id !== userId) { invalidateSource(); clearPrivateSnapshots(); clearArrivalMemory(); } });
    return () => { invalidateSource(); window.clearTimeout(timer); auth.data.subscription.unsubscribe(); };
  }, [groupId, userId, load, invalidateSource]);

  useEffect(() => {
    const stopId = snapshot?.run?.currentStop?.id ?? null;
    if (stopId && previousStopId.current && previousStopId.current !== stopId) {
      portalHeading.current?.focus();
      setManualCode("");
      setArrival(null);
    }
    previousStopId.current = stopId;
  }, [snapshot?.run?.currentStop?.id]);

  async function command(name: string, args: Record<string, unknown>) {
    const client = createClient(); if (!client || offline || waitingForArrival) return;
    setBusy(true); setNotice("");
    const { error } = await client.schema("api").rpc(name, args);
    setBusy(false);
    if (error) setNotice(explain(error));
    await load();
  }

  const prepareArrival = useCallback(async (value: string, inputMethod: string) => {
    const method = inputMethod === "short_code" ? "short_code" : "qr";
    const activeRun = snapshot?.run, activeStop = activeRun?.currentStop;
    if (!activeRun || !activeStop || !snapshot?.access.leader || offline || busy || waitingForArrival || activeRun.status !== "live" || activeStop.kind === "finale") return;
    const client = createClient(); if (!client) return;
    setBusy(true); setNotice(""); setArrivalError("");
    try {
      const parsed = parseGateCredential(value);
      const { error } = await client.schema("api").rpc("run_scan_validate", { _run_id: activeRun.id, _expected_stop_id: activeStop.id, _expected_run_version: activeRun.version, _credential: parsed.credential, _portal_id: parsed.portalId ?? null, _method: method });
      if (error) { setNotice(explain(error)); await load(); return; }
      const participants = activeRun.participants.filter(p => p.attendance === "present");
      setArrival({ ...parsed, stopId: activeStop.id, runId: activeRun.id, runVersion: activeRun.version, method, portalName: activeStop.portal.name, finale: false, participants, choices: Object.fromEntries(participants.map(p => [p.id, p.status === "skipped" || p.attendance !== "present" ? "skipped" : "visited"])) });
      return true;
    } catch (error) { setNotice(explain({message:error instanceof Error ? error.message : "WRONG_PORTAL"})); }
    finally { setBusy(false); }
  }, [snapshot, offline, busy, waitingForArrival, load]);

  async function confirmArrival(advance: boolean) {
    if (!arrival || busy) return;
    setBusy(true); setArrivalError("");
    try {
      const receipt = await submitArrival(advance ? "run_arrive_and_advance" : "run_scan", {
        _run_id: arrival.runId, _expected_stop_id: arrival.stopId, _expected_run_version: arrival.runVersion,
        _credential: arrival.credential, _portal_id: arrival.portalId, _method: arrival.method,
        _participant_choices: arrival.choices, _idempotency_key: crypto.randomUUID(),
      }, {portalName:arrival.portalName, childIds:arrival.participants.map(p=>p.childId), finale:arrival.finale});
      if(receipt.status === "attention") { setArrivalError(explain({message:receipt.error??""})); await load(); return; }
      setArrival(null); setManualCode("");
      setNotice(""); await load();
    } catch {setArrivalError("De aankomst kon niet worden bewaard. Houd dit scherm open en probeer opnieuw.");}
    finally {setBusy(false);}
  }
  useEffect(() => { const timer=setTimeout(()=>void load(),0);return()=>clearTimeout(timer); }, [sync.connected, sync.receipt?.status, load]);

  useEffect(() => {
    function readArrivalLink() {
      // Mandatory daily information and the first tour get the modal first.
      // Keep the QR query until guidance closes, then validate it once.
      if (document.documentElement.dataset.participantGuidanceActive === "true") return;
      const query = window.location.search.slice(1);
      if (!query || !snapshot?.run?.currentStop || !snapshot.access.leader || snapshot.run.currentStop.kind === "finale" || busy || offline) return;
      const code = new URLSearchParams(query).get("code");
      if (!code || consumedLink.current === query) return;
      consumedLink.current = query;
      // Reading a camera link never records arrival. The parent must confirm it.
      void prepareArrival(window.location.href, "qr").then(ready=>{if(ready){const clean=new URL(window.location.href);clean.searchParams.delete("code");clean.searchParams.delete("poort");window.history.replaceState(null,"",clean.pathname+clean.search);}});
    }
    let timer: number | undefined;
    function scheduleArrivalLink() {
      if (timer !== undefined) window.clearTimeout(timer);
      // Read the current DOM flag after all sibling initial effects have run.
      timer = window.setTimeout(readArrivalLink, 0);
    }
    scheduleArrivalLink();
    window.addEventListener("popstate", scheduleArrivalLink);
    window.addEventListener("poorten-guidance-status", scheduleArrivalLink);
    return () => {
      if (timer !== undefined) window.clearTimeout(timer);
      window.removeEventListener("popstate", scheduleArrivalLink);
      window.removeEventListener("poorten-guidance-status", scheduleArrivalLink);
    };
  }, [snapshot?.run?.currentStop, snapshot?.run?.version, snapshot?.access.leader, busy, offline, prepareArrival]);

  if (!snapshot) return <div className="panel loading-state" role="status"><RefreshCw className="spin" /><p>{notice || "Jullie groepsinformatie ophalen…"}</p></div>;
  if(snapshot.duinpadFinale?.eveningEnded)return <div className="group-app group-premium route-workspace"><DuinpadExperience key={userId} onSaved={load}/></div>;
  const run = snapshot.run;
  const stop = run?.currentStop;
  const isFinale = stop?.kind === "finale";
  const elapsedMinutes = run ? Math.floor(run.elapsedSeconds / 60) : 0;
  const attendanceState = attendanceSummary(roster.map((item) => item.registrationChildId), attendance);
  const checkedParticipants = run?.participants.filter((item) => item.status === "visited" || item.status === "skipped").length ?? 0;
  const participantTotal = run?.participants.length ?? 0;
  const canAct = !offline && !busy && !waitingForArrival && !run?.ownEveningFinished && run?.status === "live";

  return <div className="group-app group-premium route-workspace">
    <header className="route-workspace-heading"><div><p className="kicker">Samen door Duindorp</p><h2>{!run ? "Bijna tijd voor jullie avontuur" : (run.status === "completed" || run.endedEarly || run.ownEveningFinished) ? "Een nacht om te bewaren" : "Eén poort tegelijk. Samen op pad."}</h2></div><span className="route-group-badge"><Users size={16}/>{snapshot.group.code}</span></header>
    <div className="group-route-context"><span className="group-route-code"><Footprints aria-hidden="true" />{snapshot.group.code}</span><span className={`group-route-phase ${run?.status === "live" && !offline ? "is-active" : ""}`}>{offline ? "Laatste opgeslagen opdracht" : !run ? "Voor de tocht" : run.status === "completed" ? "Tocht afgerond" : run.status === "stopped" ? run.endedEarly ? "Avond afgerond" : "Tocht beëindigd" : run.status === "paused" ? "Route gepauzeerd" : "De tocht is begonnen"}</span><button type="button" className="group-route-refresh" onClick={() => void load()} aria-label="Groepsinformatie vernieuwen"><RefreshCw aria-hidden="true" /><span>Vernieuwen</span></button></div>
    {run && stop && !isFinale && !["completed", "stopped"].includes(run.status) && <nav className="route-steps" aria-label="Stappen van dit poortbezoek"><button type="button" onClick={() => scrollToRouteStep("route-destination")} className="is-done"><span><MapPin size={15}/></span><div><small>01 · Bestemming</small><strong>Loop naar de poort</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-scan")} className={stop.scanAccepted ? "is-done" : "is-current"}><span>{stop.scanAccepted ? <Check size={16}/> : <QrCode size={16}/>}</span><div><small>02 · Bevestigen</small><strong>{stop.scanAccepted ? "Poort gescand" : "Scan bij aankomst"}</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-children")} className={checkedParticipants === participantTotal ? "is-done" : stop.scanAccepted ? "is-current" : ""}><span><Users size={16}/></span><div><small>03 · Kinderen</small><strong>{checkedParticipants} van {participantTotal} verwerkt</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-next")} className={checkedParticipants === participantTotal ? "is-current" : ""}><span><ArrowRight size={16}/></span><div><small>04 · Verder</small><strong>{isFinale ? "Rond de avond af" : "Open de volgende poort"}</strong></div></button></nav>}
    {offline && <div className="offline-banner" role="alert"><CloudOff size={18} />Geen verbinding. Je ziet de laatste route-informatie, bijgewerkt om {run ? new Date(run.lastServerConfirmation).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "een eerder moment"}. Wacht op verbinding voordat jullie verdergaan.</div>}
    <ArrivalSyncNotice/>

    <DuinpadExperience key={userId} onSaved={load}/>
    {notice && <div className="form-warning" role="status">{notice}</div>}
    {!run && <GroupJourneyPreference groupId={groupId} onSaved={load} />}
    {!run && snapshot.group.start && snapshot.group.start.addressReleased !== false && snapshot.group.start.address && <section className="panel route-map-card group-start-destination"><div className="route-map-heading"><MapPin size={17}/><div><p className="kicker">Jullie vrijgegeven startpunt</p><h3>{snapshot.group.start.locationName}</h3></div></div><ReleasedDestination id={`start-${groupId}`} name={snapshot.group.start.locationName} address={snapshot.group.start.address} coordinate={snapshot.group.start.coordinate} instruction={[snapshot.group.start.arrivalInstructions, snapshot.group.start.safeApproach].filter(Boolean).join(" ")} locationSource={snapshot.group.start.locationSource} start/></section>}
    {!run && <div className="pre-event group-pre-event"><div className="pre-art"><img src="/images/avondloop-hero.webp" alt="Verlichte Duindorpse straat in de avond" /><div><p className="kicker">Route nog vergrendeld</p><h2>{snapshot.group.start ? new Date(snapshot.group.start.startsAt).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Amsterdam" }) : "Starttijd volgt"}</h2><p>{snapshot.group.start?.addressReleased===false ? `Jullie eerste adres verschijnt ${snapshot.group.start.addressReleaseAt ? new Date(snapshot.group.start.addressReleaseAt).toLocaleString("nl-NL",{day:"numeric",month:"long",hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"}):"één uur vooraf"}. Dat is één uur voor jullie start.` : snapshot.group.start ? `${snapshot.group.start.locationName}${snapshot.group.start.address?` · ${snapshot.group.start.address}`:""}` : "De organisatie publiceert de startlocatie later."}</p></div></div><div className="panel group-check-in"><p className="kicker">Samen vertrekken</p><h2>Controleer aanwezigheid</h2>{snapshot.access.leader ? <>{roster.length === 0 ? <p>De actuele groepslijst wordt opgehaald.</p> : <><div className="attendance-progress" aria-live="polite"><strong>{attendanceState.checked} van {attendanceState.total} gecontroleerd</strong><span>{attendanceState.presentIds.length} aanwezig · {attendanceState.absent} afwezig</span></div>{roster.map((item) => <fieldset className="attendance-row" key={item.registrationChildId}><legend><strong>{item.firstName}</strong><small>{item.householdLabel}</small></legend><div><label className={attendance[item.registrationChildId] === "present" ? "selected present" : "present"}><input type="radio" name={`attendance-${item.registrationChildId}`} checked={attendance[item.registrationChildId] === "present"} onChange={() => setAttendance((current) => ({ ...current, [item.registrationChildId]: "present" }))} />Aanwezig</label><label className={attendance[item.registrationChildId] === "absent" ? "selected absent" : "absent"}><input type="radio" name={`attendance-${item.registrationChildId}`} checked={attendance[item.registrationChildId] === "absent"} onChange={() => setAttendance((current) => ({ ...current, [item.registrationChildId]: "absent" }))} />Afwezig</label></div></fieldset>)}</>}<button className="btn full" disabled={busy || offline || !attendanceState.canStart || snapshot.group.start?.canStart!==true} onClick={() => { if (!attendanceState.canStart || snapshot.group.start?.canStart!==true) return; const message = `Je start met ${attendanceState.presentIds.length} aanwezige ${attendanceState.presentIds.length === 1 ? "kind" : "kinderen"}. ${attendanceState.absent} ${attendanceState.absent === 1 ? "kind is" : "kinderen zijn"} afwezig. Klopt dit?`; if (window.confirm(message)) void command("run_start", { _group_id: groupId, _present_registration_child_ids: attendanceState.presentIds, _expected_group_version: snapshot.group.version, _idempotency_key: crypto.randomUUID(), _request_hash: attendanceState.presentIds.slice().sort().join(":") }); }}>Start groep met {attendanceState.presentIds.length} aanwezig</button>{attendanceState.complete && attendanceState.presentIds.length === 0 && <p className="form-warning" role="alert">Een groep kan niet starten zonder aanwezig kind.</p>}</> : <p>Jullie groepsleider start de tocht. Daarna verschijnt de eerste bestemming.</p>}</div></div>}
    {run?.status === "completed" && !run.duinpadEveningEnded && !snapshot.duinpadFinale?.eligible && !snapshot.duinpadFinale?.recorded && <div className="finish-screen"><Check size={54} /><p className="kicker">De cirkel is rond</p><h2>Jullie zijn gefinisht.</h2><p>De bereikte poorten staan in jullie logboek. Ieder kind dat met de groep bij de poort aankwam, krijgt een zegel, ook als het de beleving oversloeg.</p></div>}
    {run?.status === "stopped" && !run.endedEarly && <div className="finish-screen"><LockKeyhole size={54} /><p className="kicker">Route beëindigd</p><h2>Volg de organisatie-instructie.</h2><p>{run.emergencyInstruction ?? "Er worden geen nieuwe poorten vrijgegeven. Blijf bij de verantwoordelijke volwassene en neem bij direct gevaar contact op met de hulpdiensten."}</p></div>}
    {run && !run.duinpadEveningEnded && <EarlyDeparture run={run} disabled={offline || busy || waitingForArrival} onSaved={load}/>}
    {!run?.duinpadEveningEnded&&<FamilyPortalThanks key={run?.version??0}/>}
    {run && !["completed", "stopped"].includes(run.status) && !run.ownEveningFinished && !stop && <div className="panel loading-state" aria-live="polite"><RefreshCw className="spin" /><div><h2>Wacht veilig bij de laatst bevestigde plek</h2><p>We zoeken de volgende poort waar jullie terechtkunnen. Blijf samen op een veilige plek tot de nieuwe aanwijzing verschijnt.</p></div></div>}
    {run && !["completed", "stopped"].includes(run.status) && stop && stop.kind !== "finale" && <>
      <div className="live-topbar group-route-metrics"><span><Footprints size={15}/><strong>{isFinale ? "Laatste poort" : `Poort ${stop.sequence}`}</strong></span><span><Clock3 size={15}/>{elapsedMinutes} min onderweg</span><span className="route-stop-time">Gewone poorten tot {snapshot.group.effectiveOrdinaryStopAt ? new Date(snapshot.group.effectiveOrdinaryStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "de afgesproken grens"}</span><span className="route-finale-time">Finale rond {snapshot.group.expectedFinaleArrivalAt ? new Date(snapshot.group.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "wordt berekend"}</span><span className="route-update-time">Bijgewerkt {new Date(run.lastServerConfirmation).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</span>{snapshot.access.leader && <button className="text-link" disabled={offline || busy} onClick={() => void command("run_set_state", { _run_id: run.id, _state: run.status === "paused" ? "live" : "paused", _expected_version: run.version, _reason: run.status === "paused" ? "Groepsleider hervat de route" : "Groepsleider pauzeert de route" })}>{run.status === "paused" ? "Route hervatten" : "Route pauzeren"}</button>}</div>
      {run.status === "paused" && <div className="offline-banner"><CloudOff size={18} />Jullie tocht staat even op pauze. De groepsleider kan hem hervatten zodra jullie klaarstaan.</div>}
      <div className="live-grid"><section id="route-destination" className="active-portal group-destination" aria-live="polite"><img src="/images/pluvierstraat.webp" alt="Sfeervol verlichte poort" /><div className="active-portal-copy"><p className="kicker">{isFinale ? "Laatste poort" : `Huidige poort · ${stop.portal.world}`}</p><h2 ref={portalHeading} tabIndex={-1}>{stop.portal.name}</h2><p>{stop.portal.description}</p><div className="portal-meta group-destination-details"><span><MapPin size={16} />{stop.portal.address}, {stop.portal.postalCode}</span><span>{stop.reservedArrivalAt ? `Aankomstvenster ${new Date(stop.reservedArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}` : `Spanning ${stop.portal.intensity}/4`}</span></div>{stop.portal.operationStatus !== "open" && <div className="form-warning">Deze poort is tijdelijk {stop.portal.operationStatus === "paused" ? "gepauzeerd" : "gesloten"}. Volg de instructie van de groepsleiding.</div>}</div></section><aside className="panel live-map-column participant-route-map route-map-card"><div className="route-map-heading"><MapPin size={17}/><div><p className="kicker">Jullie bestemming</p><h3>{isFinale ? "Naar de finale" : "De poort op de kaart"}</h3></div></div><ReleasedDestination id={stop.portal.id} name={stop.portal.name} address={[stop.portal.address, [stop.portal.postalCode, stop.portal.city].filter(Boolean).join(" ")].filter(Boolean).join(", ")} coordinate={stop.portal.coordinate} instruction={stop.portal.publicEntranceInstructions} locationSource={stop.portal.locationSource}/><div className="route-instruction"><MapPin /><span><strong>Loop samen naar de vrijgegeven poort.</strong>Scan bij aankomst de QR-code of vul de korte code van de poort in.</span></div>{!isFinale && <div className="next-hidden"><LockKeyhole /><span><strong>De volgende stop blijft nog een verrassing.</strong>Rond dit bezoek samen af. Daarna ontdek je de volgende bestemming.</span></div>}</aside></div>
      {snapshot.access.leader && !isFinale && stop.portal.operationStatus === "closed" && <div className="panel emergency"><AlertTriangle /><h3>Deze poort is gesloten</h3><p>Overleg eerst met de bewoner of organisatie. Bevestig daarna dat de groep deze gesloten poort overslaat.</p><button className="btn outline" disabled={offline || busy} onClick={() => { if (window.confirm("Gesloten poort overslaan en precies de volgende bestemming vrijgeven?")) { const key = crypto.randomUUID(); const reason = "Gesloten poort overgeslagen door groepsleider"; void command("run_system_skip", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Gesloten poort overslaan</button></div>}
      {snapshot.access.leader && <section id="route-scan" className={`panel scan-panel route-scan-card ${stop.scanAccepted ? "is-confirmed" : ""}`}><div className="route-section-title"><span className="route-step-number">02</span><div><p className="kicker">Bij de deur</p><h2>{stop.scanAccepted ? "Poort bevestigd" : "Bevestig jullie aankomst"}</h2></div>{stop.scanAccepted && <CheckCircle2 className="route-confirmed-icon"/>}</div><p>{stop.scanAccepted ? "De bezoekcode klopt. Geef nu per kind aan wie deze poort heeft bezocht." : "Scan de QR-poster of vul de korte code in. Bevestig wie erbij is en open direct jullie volgende poort."}</p><div className="actions"><button className="btn" disabled={!canAct} onClick={() => setScannerOpen(true)}><Camera size={18} />QR scannen</button><input aria-label="Korte poortcode" autoCapitalize="characters" autoComplete="off" value={manualCode} onChange={(event) => setManualCode(event.target.value)} placeholder="Korte bezoekcode" /><button className="btn outline" disabled={!canAct || !manualCode} onClick={() => void prepareArrival(manualCode, "short_code")}>Code controleren</button></div>{stop.scanAccepted && <p className="success-line"><Check size={16} />Bezoekcode gecontroleerd</p>}</section>}
      <section id="route-children" className="panel participant-panel route-children-card"><div className="row-between"><div className="route-section-title"><span className="route-step-number">03</span><div><p className="kicker">Samen controleren</p><h2>{isFinale ? "Wie doet mee aan de finale?" : "Wie doet mee aan de beleving?"}</h2></div></div><span className="status route-checked-count">{checkedParticipants}/{participantTotal} klaar</span></div><div className="route-visit-progress" role="progressbar" aria-label="Kinderen verwerkt" aria-valuemin={0} aria-valuemax={participantTotal} aria-valuenow={checkedParticipants}><span style={{width:`${participantTotal ? checkedParticipants/participantTotal*100 : 0}%`}}/></div>{!stop.scanAccepted && <p className="route-inline-guide"><LockKeyhole size={15}/>Bevestig jullie aankomst bij de poort. Een beleving overslaan mag altijd.</p>}{run.participants.map((participant) => <div className="participant-row" key={participant.id}><div className="avatar">{participant.firstName.slice(0, 1)}</div><div><strong>{participant.firstName}</strong><small>{participant.attendance === "present" ? "Aanwezig" : participant.attendance === "absent" ? "Afwezig" : participant.attendance === "departed" ? "Avond afgerond" : "Aangemeld"}</small></div><span className={`status ${participant.status ?? "pending"}`}>{participant.status === "visited" ? "Meegedaan" : participant.status === "skipped" ? "Beleving overgeslagen" : "Wacht"}</span><div className="participant-actions">{participant.attendance === "present" && participant.status === "pending" && snapshot.access.leader && <button disabled={!canAct || !stop.scanAccepted} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "visited", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}><Check size={14} />Doet mee</button>}{(!isFinale || stop.scanAccepted) && participant.status === "pending" && (snapshot.access.leader || participant.isOwnChild) && <button disabled={!canAct} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "skipped", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: snapshot.access.leader ? "Bevestigd met ouder bij de poort" : null })}><SkipForward size={14} />Overslaan</button>}{(!isFinale || stop.scanAccepted) && participant.status === "skipped" && participant.isOwnChild && !snapshot.access.leader && <button disabled={!canAct} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "pending", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}>Herstellen</button>}</div></div>)}{(!isFinale || stop.scanAccepted) && snapshot.access.leader && run.participants.some((item) => item.required && item.status === "pending") && <button className="btn outline full" disabled={!canAct} onClick={() => { if (window.confirm("De nog wachtende kinderen slaan de beleving over. Na bevestigde aankomst krijgen zij gewoon hun zegel. Klopt dat?")) { const key = crypto.randomUUID(); const reason = "Resterende kinderen overgeslagen door groepsleider"; void command("run_bulk_skip_pending", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Resterende kinderen overslaan</button>}{snapshot.access.leader && <div id="route-next" className="route-next-block"><div><span className="route-step-number">04</span><div><strong>{isFinale ? "De laatste stap van jullie avond" : "Klaar voor de volgende poort?"}</strong><p>{!stop.scanAccepted ? "Bevestig eerst jullie aankomst met de poortcode. Zo krijgt ieder aanwezig kind zijn zegel." : checkedParticipants === participantTotal ? "Iedereen is verwerkt. Je kunt dit bezoek afronden." : "Leg eerst voor ieder aanwezig kind een keuze vast."}</p></div></div><button className="btn full route-finish-button" disabled={!canAct || !stop.scanAccepted || run.participants.some((item) => item.required && item.status === "pending")} onClick={() => { const allSkipped = run.participants.every((item) => !item.required || item.status === "skipped"); if (!allSkipped || window.confirm("Iedereen slaat de beleving over. Bij bevestigde aankomst krijgt ieder aanwezig kind gewoon een zegel. Bezoek afronden?")) void command("run_complete_stop", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _all_skip_confirmed: allSkipped, _idempotency_key: crypto.randomUUID(), _request_hash: `${run.id}:${stop.id}:${run.version}:${allSkipped}` }); }}>{isFinale ? "Laatste poort afronden" : "Poort afronden"}<ArrowRight size={18}/></button></div>}</section>
      {scannerOpen && <QrScanner onCancel={() => setScannerOpen(false)} onResult={(value) => { setScannerOpen(false); void prepareArrival(value, "qr"); }} />}
    </>}
    <Dialog open={!!arrival} onOpenChange={open => { if (!open && !busy) setArrival(null); }}><DialogContent className="gate-arrival-dialog" showCloseButton={!busy} onEscapeKeyDown={e => { if (busy) e.preventDefault(); }} onInteractOutside={e => e.preventDefault()}><span className="gate-arrival-icon"><QrCode size={27}/></span><p className="kicker">Jullie zijn bij de juiste poort</p><DialogTitle>Aangekomen bij {arrival?.portalName}</DialogTitle><DialogDescription>Iedereen is bij de poort en krijgt een zegel. Geef alleen aan wie aan de beleving meedoet. Daarna verschijnt {arrival?.finale ? "de afronding van jullie avond" : "alleen de volgende bestemming"}. Blijf samen en neem de tijd bij de poort.</DialogDescription><div className="gate-arrival-children">{arrival?.participants.map(p => <label key={p.id}><span><strong>{p.firstName}</strong><small>{p.status === "skipped" ? "Beleving eerder overgeslagen · wel een zegel" : p.status === "visited" ? "Bezoek al vastgelegd" : "Bij jullie groep"}</small></span><span><input type="checkbox" checked={arrival.choices[p.id] === "visited"} disabled={busy || p.status === "skipped" || p.status === "visited"} onChange={e => setArrival(current => current ? {...current, choices:{...current.choices,[p.id]:e.target.checked ? "visited" : "skipped"}} : null)}/>{arrival.choices[p.id] === "visited" ? "Doet mee" : "Kijkt rustig mee"}</span></label>)}</div><p className="gate-arrival-note">Ieder aanwezig kind krijgt bij deze aankomst een zegel. Buiten blijven of de beleving overslaan is helemaal goed.</p>{arrivalError && <p className="form-warning" role="alert">{arrivalError}</p>}<button type="button" className="btn gate-arrival-confirm" disabled={busy} onClick={() => void confirmArrival(true)}>{busy ? "Aankomst vastleggen…" : arrival?.finale ? "Aankomst bevestigen & avond afronden" : "Aankomst bevestigen & volgende poort"}<ArrowRight size={17}/></button><button type="button" className="gate-arrival-separate" disabled={busy} onClick={() => void confirmArrival(false)}>Alleen code bevestigen, kinderen apart verwerken</button></DialogContent></Dialog>
    {run && run.history.length > 0 && <div className="panel timeline group-route-history"><p className="kicker">Logboek</p><h2>Afgeronde poorten</h2>{run.history.map((item) => <div className="summary-row" key={item.sequence}><span>{item.sequence}. {item.portalName} · {item.world}</span><strong>{item.outcome === "system_skipped" ? "Poort gesloten" : item.arrivalConfirmed || item.outcome === "visited" || item.outcome === "mixed" ? "Aangekomen" : "Poort overgeslagen"}</strong></div>)}</div>}
  </div>;
}
