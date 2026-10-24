"use client";

import { useSnapshotRefresh } from "@/lib/realtime/use-snapshot-refresh";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import "./group-experience.css";
import "../../modern/route.css";
import "../../modern/outdoor.css";
import {DestinationWarnings, OutdoorButton, RouteHelp, useOutdoorMode, type PortalVisitInformation, type RouteContact} from "./route-utilities";
import { AlertTriangle, ArrowRight, Camera, Check, CheckCircle2, Clock3, CloudOff, Footprints, LockKeyhole, MapPin, QrCode, RefreshCw, SkipForward, Users } from "lucide-react";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import { clearPrivateSnapshots, readPrivateSnapshotEntry, storePrivateSnapshot } from "@/lib/pwa/private-snapshot";
import {useAccountObservation,useStartAppointmentObservation} from "./start-appointment-observation";
import { GroupJourneyPreference } from "@/components/group/group-journey-preference";
import { NightMap } from "@/components/maps/night-map";
import { attendanceSummary, reconcileAttendance, type AttendanceDecision } from "@/lib/domain/attendance-check";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import {withRequestDeadline} from "@/lib/redesign/request-deadline";
import { parseGateCredential } from "@/lib/redesign/gate-credentials";
import { configureArrivalSync, clearArrivalMemory, hasWaitingArrival, isArrivalConnected, submitArrival } from "@/lib/redesign/arrival-sync";
import { ArrivalSyncNotice, useArrivalSync } from "@/components/redesign/arrival-sync-ui";
import { EarlyDeparture } from "@/components/redesign/early-departure";
import { FamilyPortalThanks } from "@/components/redesign/portal-thanks";

type Arrival = { credentialVerified:boolean; credential: string; portalId?: string; stopId: string; runId: string; runVersion: number; method: string; portalName: string; finale: boolean; choices: Record<string, "visited" | "skipped">; participants: Participant[] };

type RosterItem = { registrationChildId: string; firstName: string; householdLabel: string };
type Participant = { id: string; childId: string; firstName: string; attendance: string; rosterVersion: number; isOwnChild: boolean; status: "pending" | "visited" | "skipped" | null; statusVersion: number | null; required: boolean | null };
type Snapshot = {
  eventId: string; readinessRevision?:string|null;
  group: {
    id: string;
    code: string;
    status: string;
    version: number;
    routeMode: "legacy" | "dynamic";
    effectiveOrdinaryStopAt: string | null;
    expectedFinaleArrivalAt: string | null;
    start?: { name: string; locationName: string; address: string; startsAt: string; revision?:number; timePublished?:string; queueNumber?: number | null; addressReleased?:boolean; addressReleaseAt?:string; canStart?:boolean };
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
    waitingInstruction: boolean; currentDestinationNeedsReview?:boolean;planningConflict?:string; waitingReason?:string; waitingUntil?:string; safeWaitingInstruction?:string; reservedArrivalAt?:string;
    currentStop: null | { id: string; sequence: number; version: number; kind: "ordinary" | "finale"; openedAt: string; reservedArrivalAt: string | null; arrivalWindow?:{from:string;until:string}|null; scanAccepted: boolean; portal: PortalVisitInformation & { id: string; systemCode?: string; name: string; description: string; intensity: number; operationStatus: string; world: string; address: string; postalCode: string; coordinate: [number, number] | null } };
    participants: Participant[];
    ownEveningFinished?: boolean;
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
  if(value.includes("FINAL_ARRIVAL_TOO_EARLY"))return "Het gereserveerde finalemoment is nog niet bereikt. Wacht samen tot jullie afspraak.";
  if(value.includes("FINAL_RESERVATION_MISSED"))return "Jullie finalemoment is verstreken. Vraag de organisatie om een nieuwe afspraak.";
  if (value.includes("STALE_VERSION")) return "Deze stap is intussen veranderd. Kijk het scherm nog even na en probeer opnieuw.";
  if (value.includes("SCAN_REQUIRED")) return "Scan eerst de QR-code van deze poort.";
  if (value.includes("PENDING_PARTICIPANTS")) return "Geef voor ieder aanwezig kind aan: bezocht of overgeslagen.";
  if (value.includes("WRONG_PORTAL")) return "Deze code hoort niet bij de huidige poort of is verlopen.";
  if (/PORTAL_(?:CHILD_|TOTAL_)?CAPACITY_/.test(value)) return "Deze poort heeft nu onvoldoende bevestigde ontvangstruimte. Blijf bij jullie groep en vraag de organisatie om hulp.";
  if (value.includes("PORTAL_UNAVAILABLE")) return "Deze poort is gepauzeerd of gesloten; een nieuw bezoek kan niet worden vastgelegd.";
  if (value.includes("START_TIME_NOT_REACHED")) return "Jullie toegewezen starttijd is nog niet bereikt.";
  if (value.includes("PAYMENT_NOT_CONFIRMED")) return "De betaling moet door de organisatie zijn bevestigd voordat de groep kan starten.";
  if (value.includes("FINAL_PORTAL_REQUIRED")) return "Bevestig de aankomst bij de laatste poort of vraag de organisatie om hulp. Meedoen aan de beleving hoeft niet.";
  if (/FINAL_RESERVATION_REQUIRED|FINAL_RESERVATION_CONFLICT|FINALE_CAPACITY_|FINALE_UNAVAILABLE/.test(value)) return "De organisatie moet jullie vaste finale-afspraak controleren. Blijf bij elkaar en vraag om hulp.";
  if (value.includes("VISIT_ALREADY_RECORDED")) return "Er is al een bezoek vastgelegd; de poort kan niet meer als systeemskip worden overschreven.";
  return "Dat lukte nog niet. Controleer de poort en probeer opnieuw.";
}

type GroupExperienceProps={groupId:string;userId:string;contact?:RouteContact};
export function GroupExperience(props:GroupExperienceProps){return <GroupExperienceForAccount key={`${props.userId}:${props.groupId}`} {...props}/>;}
function GroupExperienceForAccount({groupId,userId,contact}:GroupExperienceProps) {
  const outdoor=useOutdoorMode(userId);
  const requestSequence=useRef(0);
  const [loadError,setLoadError]=useState(false);
  const sync = useArrivalSync();
  const waitingForArrival = hasWaitingArrival();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [roster, setRoster] = useState<RosterItem[]>([]);
  const [attendance, setAttendance] = useState<Record<string, AttendanceDecision>>({});
  const [offline, setOffline] = useState(false);
  const [cacheExpiresAt,setCacheExpiresAt]=useState<number|null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [manualCode, setManualCode] = useState("");
  const [scannerOpen, setScannerOpen] = useState(false);
  const [arrival, setArrival] = useState<Arrival | null>(null);
  const [arrivalError, setArrivalError] = useState("");
  const consumedLink = useRef("");
  const portalHeading = useRef<HTMLHeadingElement>(null);
  const appointment=useRef<HTMLHeadingElement>(null);
  useAccountObservation("group",groupId);
  useStartAppointmentObservation(appointment,groupId,snapshot?.readinessRevision);
  const previousStopId = useRef<string | null>(null);

  const restoreCached=useCallback(async()=>{
    const entry=readPrivateSnapshotEntry<Snapshot>(userId,groupId);
    const cached=entry?.snapshot?.group?.id===groupId&&typeof entry.snapshot.eventId==='string'?entry:null;
    setOffline(true);setLoadError(true);setSnapshot(cached?.snapshot??null);setCacheExpiresAt(cached?.expiresAt??null);if(!cached){setArrival(null);setManualCode("");setScannerOpen(false);}
    if(cached)await configureArrivalSync({accountId:userId,eventId:cached.snapshot.eventId,groupId,runId:cached.snapshot.run?.id??null}).catch(()=>{});
  },[userId,groupId]);
  const load = useCallback(async () => {
    const sequence=++requestSequence.current;
    if(!isArrivalConnected()){await restoreCached();return;}
    const client=createClient();
    if(!client){setLoadError(true);return;}
    try {
      const {data,error}=await withRequestDeadline(client.schema("api").rpc("group_snapshot",{_group_id:groupId}));
      if(sequence!==requestSequence.current)return;
      if(error||!data){
        if(error&&/NOT_AUTHORIZED|AUTHENTICATION_REQUIRED|JWT expired/.test(error.message)){setSnapshot(null);setCacheExpiresAt(null);setLoadError(true);clearPrivateSnapshots();clearArrivalMemory();return;}
        await restoreCached();return;
      }
      const next=data as Snapshot;
      setSnapshot(next);setCacheExpiresAt(null);setOffline(false);setLoadError(false);
      try{storePrivateSnapshot(userId,groupId,next);}catch{}
      try{await configureArrivalSync({accountId:userId,eventId:next.eventId,groupId,runId:next.run?.id??null});}catch{setNotice("Een bewaarde aankomst vraagt herstelcontrole. Houd deze telefoon bij je en neem contact op met de organisatie.");}
      if(sequence!==requestSequence.current)return;
      if(!next.run&&next.access.leader){
        try{const result=await withRequestDeadline(client.schema("api").rpc("group_roster",{_group_id:groupId}));
          if(!result.error&&sequence===requestSequence.current){const items=result.data as RosterItem[];setRoster(items);setAttendance(current=>reconcileAttendance(items.map(item=>item.registrationChildId),current));}
          else if(sequence===requestSequence.current)setNotice("De groepslijst kon niet worden opgehaald. Vernieuw voordat je de groep start.");
        }catch{if(sequence===requestSequence.current)setNotice("De groepslijst kon niet worden opgehaald. Vernieuw voordat je de groep start.");}
      }
    } catch {if(sequence===requestSequence.current)await restoreCached();}
  },[groupId,userId,restoreCached]);
  useEffect(()=>{if(!offline||cacheExpiresAt===null)return;const timer=setTimeout(()=>{requestSequence.current++;setSnapshot(null);setCacheExpiresAt(null);setArrival(null);setManualCode("");setScannerOpen(false);setLoadError(true);if(isArrivalConnected())void load();},Math.max(0,cacheExpiresAt-Date.now()));return()=>clearTimeout(timer);},[offline,cacheExpiresAt,load]);
  useSnapshotRefresh(load);

  useEffect(() => {
    const client = createClient(); if (!client) return;
    const timer = window.setTimeout(() => void load(), 0);
    const channel = client.channel(`group:${groupId}`, { config: { private: true } }).on("broadcast", { event: "snapshot_changed" }, () => void load()).subscribe();
    const auth = client.auth.onAuthStateChange((_event: AuthChangeEvent, session: Session | null) => { if (!session || session.user.id !== userId) { requestSequence.current++;setSnapshot(null);setCacheExpiresAt(null);setRoster([]);setArrival(null);setLoadError(true);clearPrivateSnapshots();clearArrivalMemory(); } });
    const reconnect = () => void load();
    window.addEventListener("online", reconnect);
    return () => { window.clearTimeout(timer); void client.removeChannel(channel); auth.data.subscription.unsubscribe(); window.removeEventListener("online", reconnect); };
  }, [groupId, userId, load]);

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
    try {
      const { error } = await withRequestDeadline(client.schema("api").rpc(name, args));
      if (error) setNotice(explain(error));
      await load();
    } catch {setNotice("Er kwam geen bevestiging terug. Vernieuw de actuele groep voordat jullie verdergaan.");}
    finally {setBusy(false);}
  }

  const prepareArrival = useCallback(async (value: string, inputMethod: string) => {
    const method = inputMethod === "short_code" ? "short_code" : "qr";
    const activeRun = snapshot?.run, activeStop = activeRun?.currentStop;
    if (!activeRun || !activeStop || !snapshot?.access.leader || busy || waitingForArrival || activeRun.status !== "live") return;
    const client = createClient(); if (!client) return;
    setBusy(true); setNotice(""); setArrivalError("");
    try {
      const parsed = parseGateCredential(value);
      let credentialVerified=false;
      if(!offline){try{const result=await withRequestDeadline(client.schema("api").rpc("run_scan_validate",{_run_id:activeRun.id,_expected_stop_id:activeStop.id,_expected_run_version:activeRun.version,_credential:parsed.credential,_portal_id:parsed.portalId??null,_method:method}));
        if(result.error){if([408,425,429].includes(result.status)||result.status>=500||/fetch|network|timeout/i.test(result.error.message))throw new Error('RESPONSE_UNCERTAIN');setNotice(explain(result.error));await load();return;}credentialVerified=true;
      }catch{setNotice("De code kon nog niet bij de server worden gecontroleerd. Je kunt de aankomst op deze telefoon bewaren voor bevestiging.");}}

      const participants = activeRun.participants.filter(p => p.attendance === "present");
      setArrival({ ...parsed, credentialVerified, stopId: activeStop.id, runId: activeRun.id, runVersion: activeRun.version, method, portalName: activeStop.portal.name, finale: activeStop.kind === "finale", participants, choices: Object.fromEntries(participants.map(p => [p.id, p.status === "skipped" || p.attendance !== "present" ? "skipped" : "visited"])) });
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
      if (!query || !snapshot?.run?.currentStop || !snapshot.access.leader || busy) return;
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

  const releasedStop = snapshot?.run?.currentStop;
  const mapPortals = useMemo(() => releasedStop ? [{
    id: releasedStop.id,
    name: releasedStop.portal.name,
    world: releasedStop.portal.world,
    coordinate: releasedStop.portal.coordinate,
    address: `${releasedStop.portal.address}, ${releasedStop.portal.postalCode} Den Haag`,
  }] : [], [releasedStop]);

  if(!snapshot)return <div className={`group-app route-workspace ${outdoor.enabled?'is-outdoor':''}`}><div className="route-utility-bar"><OutdoorButton enabled={outdoor.enabled} onClick={outdoor.toggle}/><RouteHelp contact={contact}/></div>{loadError?<section className="panel route-snapshot-error" role="alert"><AlertTriangle size={32}/><h2>Jullie route kon niet worden opgehaald</h2><p>Er is geen geldige opgeslagen bestemming op deze telefoon. Blijf samen en neem contact op met de organisatie. Geef jullie groepscode door als je die bij je hebt.</p><div className="actions"><button className="btn" onClick={()=>void load()}><RefreshCw/>Opnieuw proberen</button><RouteHelp contact={contact}/></div></section>:<div className="panel loading-state"><RefreshCw className="spin"/><p>Jullie groepsinformatie ophalen…</p></div>}<ArrivalSyncNotice/></div>;
  const run = snapshot.run;
  const stop = run?.currentStop;
  const isFinale = stop?.kind === "finale";
  const elapsedMinutes = run ? Math.floor(run.elapsedSeconds / 60) : 0;
  const attendanceState = attendanceSummary(roster.map((item) => item.registrationChildId), attendance);
  const checkedParticipants = run?.participants.filter((item) => item.status === "visited" || item.status === "skipped").length ?? 0;
  const participantTotal = run?.participants.length ?? 0;
  const canAct = !offline && !busy && !waitingForArrival && run?.status === "live";

  return <div className={`group-app group-premium route-workspace ${outdoor.enabled?"is-outdoor":""} ${stop?"has-active-stop":""}`}>
    <header className="route-workspace-heading"><div><p className="kicker">Samen door Duindorp</p><h2>{!run ? "Bijna tijd voor jullie avontuur" : (run.status === "completed" || run.endedEarly || run.ownEveningFinished) ? "Een nacht om te bewaren" : "Eén poort tegelijk. Samen op pad."}</h2></div><span className="route-group-badge"><Users size={16}/>{snapshot.group.code}</span></header>
    <div className="route-utility-bar"><OutdoorButton enabled={outdoor.enabled} onClick={outdoor.toggle}/><RouteHelp contact={contact}/></div>
    <div className="group-route-context"><span className="group-route-code"><Footprints aria-hidden="true" />{snapshot.group.code}</span><span className={`group-route-phase ${run?.status === "live" && !offline ? "is-active" : ""}`}>{offline ? "Laatste opgeslagen opdracht" : !run ? "Voor de tocht" : run.status === "completed" ? "Tocht afgerond" : run.status === "stopped" ? run.endedEarly ? "Avond afgerond" : "Tocht beëindigd" : run.status === "paused" ? "Route gepauzeerd" : "De tocht is begonnen"}</span><button type="button" className="group-route-refresh" onClick={() => void load()} aria-label="Groepsinformatie vernieuwen"><RefreshCw aria-hidden="true" /><span>Vernieuwen</span></button></div>
    {outdoor.enabled&&run&&stop&&!['completed','stopped'].includes(run.status)&&<nav className="route-outdoor-shortcuts" aria-label="Direct bij de poort">{snapshot.access.leader&&<><button className="btn" disabled={busy||waitingForArrival||run.status!=='live'} onClick={()=>setScannerOpen(true)}><Camera/>QR scannen</button><button className="btn outline" onClick={()=>scrollToRouteStep('route-scan')}><QrCode/>Korte code</button></>}<button className="route-outdoor-location" onClick={()=>scrollToRouteStep('route-destination')}><MapPin/><span>{stop.portal.systemCode} · {stop.portal.address}</span></button></nav>}
    {run && stop && !["completed", "stopped"].includes(run.status) && <nav className="route-steps" aria-label="Stappen van dit poortbezoek"><button type="button" onClick={() => scrollToRouteStep("route-destination")} className="is-done"><span><MapPin size={15}/></span><div><small>01 · Bestemming</small><strong>Loop naar de poort</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-scan")} className={stop.scanAccepted ? "is-done" : "is-current"}><span>{stop.scanAccepted ? <Check size={16}/> : <QrCode size={16}/>}</span><div><small>02 · Bevestigen</small><strong>{stop.scanAccepted ? "Poort gescand" : "Scan bij aankomst"}</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-children")} className={checkedParticipants === participantTotal ? "is-done" : stop.scanAccepted ? "is-current" : ""}><span><Users size={16}/></span><div><small>03 · Kinderen</small><strong>{checkedParticipants} van {participantTotal} verwerkt</strong></div></button><button type="button" onClick={() => scrollToRouteStep("route-next")} className={checkedParticipants === participantTotal ? "is-current" : ""}><span><ArrowRight size={16}/></span><div><small>04 · Verder</small><strong>{isFinale ? "Rond de avond af" : "Open de volgende poort"}</strong></div></button></nav>}
    {offline && <div className="offline-banner" role="alert"><CloudOff size={18} />De route kon niet worden vernieuwd. Je ziet de laatste geldige opgeslagen opdracht, bijgewerkt om {run ? new Date(run.lastServerConfirmation).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "een eerder moment"}. Een aankomst kan worden bewaard. Wacht op serverbevestiging voordat jullie verdergaan.</div>}
    <ArrivalSyncNotice/>

    {notice && <div className="form-warning" role="status">{notice}</div>}
    {!run && <GroupJourneyPreference groupId={groupId} onSaved={load} />}
    {!run && <div className="pre-event group-pre-event"><div className="pre-art"><img src="/images/avondloop-hero.webp" alt="Verlichte Duindorpse straat in de avond" /><div><p className="kicker">Route nog vergrendeld</p><h2 ref={appointment}>{snapshot.group.start ? new Date(snapshot.group.start.startsAt).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Amsterdam" }) : "Starttijd volgt"}</h2><p>{snapshot.group.start?.addressReleased===false ? `Jullie eerste adres verschijnt ${snapshot.group.start.addressReleaseAt ? new Date(snapshot.group.start.addressReleaseAt).toLocaleString("nl-NL",{day:"numeric",month:"long",hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"}):"één uur vooraf"}. Dat is één uur voor jullie start.` : snapshot.group.start ? `${snapshot.group.start.locationName}${snapshot.group.start.address?` · ${snapshot.group.start.address}`:""}` : "De organisatie publiceert de startlocatie later."}</p></div></div><div className="panel group-check-in"><p className="kicker">Samen vertrekken</p><h2>Controleer aanwezigheid</h2>{snapshot.access.leader ? <>{roster.length === 0 ? <p>De actuele groepslijst wordt opgehaald.</p> : <><div className="attendance-progress" aria-live="polite"><strong>{attendanceState.checked} van {attendanceState.total} gecontroleerd</strong><span>{attendanceState.presentIds.length} aanwezig · {attendanceState.absent} afwezig</span></div>{roster.map((item) => <fieldset className="attendance-row" key={item.registrationChildId}><legend><strong>{item.firstName}</strong><small>{item.householdLabel}</small></legend><div><label className={attendance[item.registrationChildId] === "present" ? "selected present" : "present"}><input type="radio" name={`attendance-${item.registrationChildId}`} checked={attendance[item.registrationChildId] === "present"} onChange={() => setAttendance((current) => ({ ...current, [item.registrationChildId]: "present" }))} />Aanwezig</label><label className={attendance[item.registrationChildId] === "absent" ? "selected absent" : "absent"}><input type="radio" name={`attendance-${item.registrationChildId}`} checked={attendance[item.registrationChildId] === "absent"} onChange={() => setAttendance((current) => ({ ...current, [item.registrationChildId]: "absent" }))} />Afwezig</label></div></fieldset>)}</>}<button className="btn full" disabled={busy || offline || !attendanceState.canStart || snapshot.group.start?.canStart!==true} onClick={() => { if (!attendanceState.canStart || snapshot.group.start?.canStart!==true) return; const message = `Je start met ${attendanceState.presentIds.length} aanwezige ${attendanceState.presentIds.length === 1 ? "kind" : "kinderen"}. ${attendanceState.absent} ${attendanceState.absent === 1 ? "kind is" : "kinderen zijn"} afwezig. Klopt dit?`; if (window.confirm(message)) void command("run_start", { _group_id: groupId, _present_registration_child_ids: attendanceState.presentIds, _expected_group_version: snapshot.group.version, _idempotency_key: crypto.randomUUID(), _request_hash: attendanceState.presentIds.slice().sort().join(":") }); }}>Start groep met {attendanceState.presentIds.length} aanwezig</button>{attendanceState.complete && attendanceState.presentIds.length === 0 && <p className="form-warning" role="alert">Een groep kan niet starten zonder aanwezig kind.</p>}</> : <p>Jullie groepsleider start de tocht. Daarna verschijnt de eerste bestemming.</p>}</div></div>}
    {run?.status === "completed" && <div className="finish-screen"><Check size={54} /><p className="kicker">De cirkel is rond</p><h2>Jullie zijn gefinisht.</h2><p>De bereikte poorten staan in jullie logboek. Ieder kind dat met de groep bij de poort aankwam, krijgt een zegel, ook als het de beleving oversloeg.</p></div>}
    {run?.status === "stopped" && !run.endedEarly && <div className="finish-screen"><LockKeyhole size={54} /><p className="kicker">Route beëindigd</p><h2>Volg de organisatie-instructie.</h2><p>{run.emergencyInstruction ?? "Er worden geen nieuwe poorten vrijgegeven. Blijf bij de verantwoordelijke volwassene en neem bij direct gevaar contact op met de hulpdiensten."}</p></div>}
    {run && <EarlyDeparture run={run} disabled={offline || busy || waitingForArrival} onSaved={load}/>}
    <FamilyPortalThanks key={run?.version??0}/>
    {run?.waitingReason==="finale_window"&&!run.ownEveningFinished&&!stop&&<section className="panel route-safe-wait" role="status"><Clock3 size={32}/><div><p className="kicker">Jullie finale-afspraak</p><h2>Jullie finalemoment staat vast</h2>{run.reservedArrivalAt&&<p>Jullie worden om <strong>{new Date(run.reservedArrivalAt).toLocaleTimeString("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"})}</strong> bij de finale verwacht.</p>}<p>{run.safeWaitingInstruction||"Vraag de organisatie naar een veilige wachtplek."}</p>{run.waitingUntil&&<p className="route-wait-time">Volgende aanwijzing vanaf {new Date(run.waitingUntil).toLocaleTimeString("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"})}</p>}</div></section>}
    {run && run.waitingReason!=="finale_window" && !["completed", "stopped"].includes(run.status) && !run.ownEveningFinished && !stop && <div className="panel loading-state" aria-live="polite">{run.status==="paused"?<Clock3/>:<RefreshCw className="spin"/>}<div><h2>{run.planningConflict?"Organisatiecontrole nodig":run.status==="paused"?"Jullie tocht staat op pauze":"Wacht veilig bij de laatst bevestigde plek"}</h2><p>{run.safeWaitingInstruction||(run.status==="paused"?"Blijf samen. De groepsleider kan de tocht hervatten zodra jullie klaarstaan.":"We zoeken de volgende poort waar jullie terechtkunnen. Blijf samen op een veilige plek tot de nieuwe aanwijzing verschijnt.")}</p>{run.status==="paused"&&!run.planningConflict&&snapshot.access.leader&&<button className="btn" disabled={offline||busy} onClick={()=>void command("run_set_state",{_run_id:run.id,_state:"live",_expected_version:run.version,_reason:"Groepsleider hervat de route"})}>Tocht hervatten</button>}</div></div>}
    {run && !["completed", "stopped"].includes(run.status) && stop && <>
      <div className="live-topbar group-route-metrics"><span><Footprints size={15}/><strong>{isFinale ? "Laatste poort" : `Poort ${stop.sequence}`}</strong></span><span><Clock3 size={15}/>{elapsedMinutes} min onderweg</span><span className="route-stop-time">Gewone poorten tot {snapshot.group.effectiveOrdinaryStopAt ? new Date(snapshot.group.effectiveOrdinaryStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "de afgesproken grens"}</span><span className="route-finale-time">{run.reservedArrivalAt?"Finale gereserveerd om":"Finale verwacht rond"} {snapshot.group.expectedFinaleArrivalAt ? new Date(snapshot.group.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "wordt berekend"}</span><span className="route-update-time">Bijgewerkt {new Date(run.lastServerConfirmation).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</span>{snapshot.access.leader && <button className="text-link" disabled={offline || busy} onClick={() => void command("run_set_state", { _run_id: run.id, _state: run.status === "paused" ? "live" : "paused", _expected_version: run.version, _reason: run.status === "paused" ? "Groepsleider hervat de route" : "Groepsleider pauzeert de route" })}>{run.status === "paused" ? "Route hervatten" : "Route pauzeren"}</button>}</div>
      {run.status === "paused" && <div className="offline-banner"><CloudOff size={18} />Jullie tocht staat even op pauze. De groepsleider kan hem hervatten zodra jullie klaarstaan.</div>}
      {run.currentDestinationNeedsReview&&<div className="form-warning" role="status">De geplande tijd is voorbij. Blijf bij jullie groep en neem contact op met de organisatie. De huidige aanwijzing blijft zichtbaar en eerder bewaarde opdrachten blijven behouden.</div>}
      <div className="live-grid"><section id="route-destination" className="active-portal group-destination" aria-live="polite"><img src="/images/pluvierstraat.webp" alt="Sfeervol verlichte poort" /><div className="active-portal-copy"><p className="kicker">{isFinale ? "Laatste poort" : `Huidige poort · ${stop.portal.world}`}</p><h2 ref={portalHeading} tabIndex={-1}>{stop.portal.name}</h2><p>{stop.portal.description}</p><div className="portal-meta group-destination-details"><span><MapPin size={16} />{stop.portal.address}, {stop.portal.postalCode}</span><span>Spanning {stop.portal.intensity}/4</span><span>{stop.arrivalWindow?`Aankomstvenster ${new Date(stop.arrivalWindow.from).toLocaleTimeString("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"})}–${new Date(stop.arrivalWindow.until).toLocaleTimeString("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"})}`:stop.reservedArrivalAt?`${isFinale?"Jullie finalemoment":"Gereserveerde aankomst"} ${new Date(stop.reservedArrivalAt).toLocaleTimeString("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"})}`:"Aankomstvenster nog niet bekend"}</span></div><DestinationWarnings portal={stop.portal}/>{stop.portal.operationStatus !== "open" && <div className="form-warning">Deze poort is tijdelijk {stop.portal.operationStatus === "paused" ? "gepauzeerd" : "gesloten"}. Volg de instructie van de groepsleiding.</div>}</div></section><aside className="panel live-map-column participant-route-map route-map-card"><div className="route-map-heading"><MapPin size={17}/><div><p className="kicker">Jullie bestemming</p><h3>{isFinale ? "Naar de finale" : "De poort op de kaart"}</h3></div></div><NightMap variant="route" portals={mapPortals} ariaLabel="Kaart met de huidige vrijgegeven poort" /><div className="route-instruction"><MapPin /><span><strong>Loop samen naar de vrijgegeven poort.</strong>Scan bij aankomst de QR-code of vul de korte code van de poort in.</span></div>{!isFinale && <div className="next-hidden"><LockKeyhole /><span><strong>De volgende stop blijft nog een verrassing.</strong>Rond dit bezoek samen af. Daarna ontdek je de volgende bestemming.</span></div>}</aside></div>
      {snapshot.access.leader && !stop.scanAccepted && !isFinale && stop.portal.operationStatus === "closed" && <div className="panel emergency"><AlertTriangle /><h3>Deze poort is gesloten</h3><p>Overleg eerst met de bewoner of organisatie. Bevestig daarna dat de groep deze gesloten poort overslaat.</p><button className="btn outline" disabled={offline || busy} onClick={() => { if (window.confirm("Gesloten poort overslaan en precies de volgende bestemming vrijgeven?")) { const key = crypto.randomUUID(); const reason = "Gesloten poort overgeslagen door groepsleider"; void command("run_system_skip", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Gesloten poort overslaan</button></div>}
      {snapshot.access.leader && <section id="route-scan" className={`panel scan-panel route-scan-card ${stop.scanAccepted ? "is-confirmed" : ""}`}><div className="route-section-title"><span className="route-step-number">02</span><div><p className="kicker">Bij de deur</p><h2>{stop.scanAccepted ? "Poort bevestigd" : "Bevestig jullie aankomst"}</h2></div>{stop.scanAccepted && <CheckCircle2 className="route-confirmed-icon"/>}</div><p>{stop.scanAccepted ? "De bezoekcode klopt. Geef nu per kind aan wie deze poort heeft bezocht." : "Scan de QR-poster of vul de korte code in. Bevestig wie erbij is en open direct jullie volgende poort."}</p><div className="actions"><button className="btn" disabled={busy||waitingForArrival||run.status!=="live"} onClick={() => setScannerOpen(true)}><Camera size={18} />QR scannen</button><input aria-label="Korte poortcode" autoCapitalize="characters" autoComplete="off" value={manualCode} onChange={(event) => setManualCode(event.target.value)} placeholder="Korte bezoekcode" /><button className="btn outline" disabled={busy||waitingForArrival||run.status!=="live"||!manualCode} onClick={() => void prepareArrival(manualCode, "short_code")}>Code controleren</button></div>{stop.scanAccepted && <p className="success-line"><Check size={16} />Bezoekcode gecontroleerd</p>}</section>}
      <section id="route-children" className="panel participant-panel route-children-card"><div className="row-between"><div className="route-section-title"><span className="route-step-number">03</span><div><p className="kicker">Samen controleren</p><h2>{isFinale ? "Wie doet mee aan de finale?" : "Wie doet mee aan de beleving?"}</h2></div></div><span className="status route-checked-count">{checkedParticipants}/{participantTotal} klaar</span></div><div className="route-visit-progress" role="progressbar" aria-label="Kinderen verwerkt" aria-valuemin={0} aria-valuemax={participantTotal} aria-valuenow={checkedParticipants}><span style={{width:`${participantTotal ? checkedParticipants/participantTotal*100 : 0}%`}}/></div>{!stop.scanAccepted && <p className="route-inline-guide"><LockKeyhole size={15}/>Bevestig jullie aankomst bij de poort. Een beleving overslaan mag altijd.</p>}{run.participants.map((participant) => <div className="participant-row" key={participant.id}><div className="avatar">{participant.firstName.slice(0, 1)}</div><div><strong>{participant.firstName}</strong><small>{participant.attendance === "present" ? "Aanwezig" : participant.attendance === "absent" ? "Afwezig" : participant.attendance === "departed" ? "Avond afgerond" : "Aangemeld"}</small></div><span className={`status ${participant.status ?? "pending"}`}>{participant.status === "visited" ? "Meegedaan" : participant.status === "skipped" ? "Beleving overgeslagen" : "Wacht"}</span><div className="participant-actions">{participant.attendance === "present" && participant.status === "pending" && snapshot.access.leader && <button disabled={!canAct || !stop.scanAccepted} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "visited", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}><Check size={14} />Doet mee</button>}{(!isFinale || stop.scanAccepted) && participant.status === "pending" && (snapshot.access.leader || participant.isOwnChild) && <button disabled={!canAct} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "skipped", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: snapshot.access.leader ? "Bevestigd met ouder bij de poort" : null })}><SkipForward size={14} />Overslaan</button>}{(!isFinale || stop.scanAccepted) && participant.status === "skipped" && participant.isOwnChild && !snapshot.access.leader && <button disabled={!canAct} onClick={() => void command("run_update_participant", { _run_id: run.id, _stop_id: stop.id, _run_participant_id: participant.id, _new_status: "pending", _expected_run_version: run.version, _expected_status_version: participant.statusVersion, _reason: null })}>Herstellen</button>}</div></div>)}{(!isFinale || stop.scanAccepted) && snapshot.access.leader && run.participants.some((item) => item.required && item.status === "pending") && <button className="btn outline full" disabled={!canAct} onClick={() => { if (window.confirm("De nog wachtende kinderen slaan de beleving over. Na bevestigde aankomst krijgen zij gewoon hun zegel. Klopt dat?")) { const key = crypto.randomUUID(); const reason = "Resterende kinderen overgeslagen door groepsleider"; void command("run_bulk_skip_pending", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _reason: reason, _idempotency_key: key, _request_hash: `${run.id}:${stop.id}:${run.version}:${reason}` }); } }}>Resterende kinderen overslaan</button>}{snapshot.access.leader && <div id="route-next" className="route-next-block"><div><span className="route-step-number">04</span><div><strong>{isFinale ? "De laatste stap van jullie avond" : "Klaar voor de volgende poort?"}</strong><p>{!stop.scanAccepted ? "Bevestig eerst jullie aankomst met de poortcode. Zo krijgt ieder aanwezig kind zijn zegel." : checkedParticipants === participantTotal ? "Iedereen is verwerkt. Je kunt dit bezoek afronden." : "Leg eerst voor ieder aanwezig kind een keuze vast."}</p></div></div><button className="btn full route-finish-button" disabled={!canAct || !stop.scanAccepted || run.participants.some((item) => item.required && item.status === "pending")} onClick={() => { const allSkipped = run.participants.every((item) => !item.required || item.status === "skipped"); if (!allSkipped || window.confirm("Iedereen slaat de beleving over. Bij bevestigde aankomst krijgt ieder aanwezig kind gewoon een zegel. Bezoek afronden?")) void command("run_complete_stop", { _run_id: run.id, _stop_id: stop.id, _expected_run_version: run.version, _all_skip_confirmed: allSkipped, _idempotency_key: crypto.randomUUID(), _request_hash: `${run.id}:${stop.id}:${run.version}:${allSkipped}` }); }}>{isFinale ? "Laatste poort afronden" : "Poort afronden"}<ArrowRight size={18}/></button></div>}</section>
      {scannerOpen && <QrScanner onCancel={() => setScannerOpen(false)} onResult={(value) => { setScannerOpen(false); void prepareArrival(value, "qr"); }} />}
    </>}
    <Dialog open={!!arrival} onOpenChange={open => { if (!open && !busy) setArrival(null); }}><DialogContent className="gate-arrival-dialog" showCloseButton={!busy} onEscapeKeyDown={e => { if (busy) e.preventDefault(); }} onInteractOutside={e => e.preventDefault()}><span className="gate-arrival-icon"><QrCode size={27}/></span><p className="kicker">{arrival?.credentialVerified?"Jullie zijn bij de juiste poort":"Poortcode nog niet bevestigd"}</p><DialogTitle>Aangekomen bij {arrival?.portalName}</DialogTitle><DialogDescription>{arrival?.credentialVerified?"Iedereen is bij de poort en krijgt na bevestigde aankomst een zegel.":"De code moet nog door de server worden gecontroleerd. Bewaar jullie aankomst op deze telefoon. Pas na serverbevestiging verschijnen de zegels en de volgende bestemming."} Geef alleen aan wie aan de beleving meedoet. Daarna verschijnt {arrival?.finale ? "de afronding van jullie avond" : "alleen de volgende bestemming"}. Blijf samen en neem de tijd bij de poort.</DialogDescription><div className="gate-arrival-children">{arrival?.participants.map(p => <label key={p.id}><span><strong>{p.firstName}</strong><small>{p.status === "skipped" ? "Beleving eerder overgeslagen · wel een zegel" : p.status === "visited" ? "Bezoek al vastgelegd" : "Bij jullie groep"}</small></span><span><input type="checkbox" checked={arrival.choices[p.id] === "visited"} disabled={busy || p.status === "skipped" || p.status === "visited"} onChange={e => setArrival(current => current ? {...current, choices:{...current.choices,[p.id]:e.target.checked ? "visited" : "skipped"}} : null)}/>{arrival.choices[p.id] === "visited" ? "Doet mee" : "Kijkt rustig mee"}</span></label>)}</div><p className="gate-arrival-note">Ieder aanwezig kind krijgt na serverbevestiging van deze aankomst een zegel. Buiten blijven of de beleving overslaan is helemaal goed.</p>{arrivalError && <p className="form-warning" role="alert">{arrivalError}</p>}<button type="button" className="btn gate-arrival-confirm" disabled={busy} onClick={() => void confirmArrival(true)}>{busy ? "Aankomst vastleggen…" : !arrival?.credentialVerified?"Aankomst bewaren voor bevestiging":arrival?.finale ? "Aankomst bevestigen & avond afronden" : "Aankomst bevestigen & volgende poort"}<ArrowRight size={17}/></button><button type="button" className="gate-arrival-separate" disabled={busy} onClick={() => void confirmArrival(false)}>Alleen code bevestigen, kinderen apart verwerken</button></DialogContent></Dialog>
    {run && run.history.length > 0 && <div className="panel timeline group-route-history"><p className="kicker">Logboek</p><h2>Afgeronde poorten</h2>{run.history.map((item) => <div className="summary-row" key={item.sequence}><span>{item.sequence}. {item.portalName} · {item.world}</span><strong>{item.outcome === "system_skipped" ? "Poort gesloten" : item.arrivalConfirmed || item.outcome === "visited" || item.outcome === "mixed" ? "Aangekomen" : "Poort overgeslagen"}</strong></div>)}</div>}
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
          if (result && !stopped) { stopped = true; release(); resultHandler.current(result.getText()); }
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
