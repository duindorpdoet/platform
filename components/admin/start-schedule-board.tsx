"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, Clock3, MapPinned, RefreshCw, Save, Send, UsersRound } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { proposePlan, type PlannedGroup, type PlanningInput } from "@/lib/domain/route-planner";
import { NightMap } from "@/components/maps/night-map";

type RouteSettings = {
  version: number;
  plannerMode: "disabled" | "shadow" | "dynamic";
  firstStartAt: string | null;
  earlyPreferenceLatestAt: string | null;
  laterPreferenceEarliestAt: string | null;
  globalOrdinaryStopAt: string | null;
  allowedStopTimes: string[];
  ordinaryVisitSeconds: number;
  bufferSeconds: number;
  finalPortalId: string | null;
  finaleOpensAt: string | null;
  finaleLastArrivalAt: string | null;
  finaleClosesAt: string | null;
  finaleShowSeconds: number;
  finaleTurnoverSeconds: number;
  finalePlanningTransferSeconds: number;
  finaleMaxGroups: number;
  finaleMaxChildren: number;
  finaleSafeApproach?: string | null;
  finaleWaitingArea?: string | null;
  finaleExitRoute?: string | null;
  finaleAccessibleEntrance?: string | null;
  finaleContact?: string | null;
  finaleAvailable: boolean;
  emergencyDestinationName?: string | null;
  emergencyInstructions?: string | null;
};
type Slot = { id: string; startsAt: string; maxGroups: number; maxChildren: number; active: boolean };
type StartPoint = {
  id: string; name: string; privateAddress: string; latitude: number | null; longitude: number | null;
  walkingNodeId: string | null; verified: boolean; accessible: boolean | null; maxGroups: number;
  maxChildren: number; version: number; slots: Slot[];
};
type Portal = { id: string; name: string; world: string; operationStatus: string; verified: boolean; isFinal: boolean };
type RegistrationRow = { id: string; reference: string; startPreference: string; ordinaryStopAt: string | null; paymentEligible: boolean };
type Schedule = { id: string; revision: number; state: string; startSlotId: string; effectiveStopAt: string; expectedFinaleArrivalAt: string; preferenceMatch: string; warnings: string[] };
type Group = { id: string; code: string; status: string; version: number; routeMode: string; childCount: number; registrations: RegistrationRow[]; schedule: Schedule | null };
type Unassigned = { id: string; reference: string; childCount: number; startPreference: "early" | "indifferent" | "later"; ordinaryStopAt: string | null; togetherKey?: string | null; paymentStatus?: string | null; paymentEligible: boolean };
type Snapshot = { settings: RouteSettings; startPoints: StartPoint[]; portals: Portal[]; groups: Group[]; unassigned: Unassigned[]; finaleFlow: Array<{ window: string; groups: number; children: number }> };
type DraftPoint = {
  name: string;
  privateAddress: string;
  latitude: string;
  longitude: string;
  walkingNodeId: string;
  maxGroups: string;
  maxChildren: string;
  accessible: "" | "true" | "false";
  accessibilityNotes: string;
};

const emptyPoint: DraftPoint = {
  name: "", privateAddress: "", latitude: "", longitude: "", walkingNodeId: "",
  maxGroups: "1", maxChildren: "20", accessible: "", accessibilityNotes: "",
};
const matchLabels: Record<string, string> = { good: "past bij voorkeur", small_deviation: "kleine afwijking", large_deviation: "grote afwijking", neutral: "geen voorkeur" };

function datetimeLocal(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 16);
}

function iso(value: string) {
  return value ? new Date(value).toISOString() : null;
}

function matchPreference(group: Group, slot: Slot, settings: RouteSettings): Schedule["preferenceMatch"] {
  const preferences = [...new Set(group.registrations.map((registration) => registration.startPreference).filter((value) => value !== "indifferent"))];
  if (preferences.length === 0) return "neutral";
  if (preferences.length > 1) return "large_deviation";
  const start = new Date(slot.startsAt).getTime();
  const early = settings.earlyPreferenceLatestAt ? new Date(settings.earlyPreferenceLatestAt).getTime() : null;
  const later = settings.laterPreferenceEarliestAt ? new Date(settings.laterPreferenceEarliestAt).getTime() : null;
  if (preferences[0] === "early") {
    if (early === null || start <= early) return "good";
    return later === null || start < later ? "small_deviation" : "large_deviation";
  }
  if (later === null || start >= later) return "good";
  return early === null || start > early ? "small_deviation" : "large_deviation";
}

async function digest(value: unknown) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function StartScheduleBoard({ eventSlug, maxGroupSize }: { eventSlug: string; maxGroupSize: number }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [settingsDraft, setSettingsDraft] = useState<RouteSettings | null>(null);
  const [pointDraft, setPointDraft] = useState<DraftPoint>(emptyPoint);
  const [proposal, setProposal] = useState<ReturnType<typeof proposePlan> | null>(null);
  const [scheduleIds, setScheduleIds] = useState<string[]>([]);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_route_configuration_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice(`Indeling ophalen mislukt: ${error.message}`);
    const next = data as Snapshot;
    setSnapshot(next); setSettingsDraft(next.settings);
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  const starts = useMemo(() => snapshot?.startPoints.flatMap((point) => point.slots.filter((slot) => slot.active).map((slot) => ({ ...slot, startPointId: point.id }))) ?? [], [snapshot]);
  const mapPoints = useMemo(() => snapshot?.startPoints.filter((point) => point.latitude !== null && point.longitude !== null).map((point) => ({
    id: point.id, name: point.name, world: "Startpunt", coordinate: [point.longitude!, point.latitude!] as [number, number], address: point.privateAddress,
  })) ?? [], [snapshot]);

  async function saveSettings() {
    if (!snapshot || !settingsDraft) return;
    const reason = window.prompt("Waarom wijzig je de route-instellingen? (minimaal 10 tekens)")?.trim();
    if (!reason || reason.length < 10) return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_save_route_settings", {
      _event_slug: eventSlug,
      _settings: settingsDraft,
      _expected_version: snapshot.settings.version,
      _reason: reason,
    });
    setBusy(false);
    setNotice(error ? `Instellingen geweigerd: ${error.message}` : "Route-instellingen versieerbaar opgeslagen.");
    if (!error) await load();
  }

  async function addStartPoint() {
    const reason = window.prompt("Hoe is dit startpunt gecontroleerd? (minimaal 10 tekens)")?.trim();
    if (!reason || reason.length < 10) return setNotice("Leg de verificatie in minimaal tien tekens vast.");
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_start_point_save", {
      _event_slug: eventSlug,
      _point_id: null,
      _payload: {
        ...pointDraft,
        latitude: pointDraft.latitude,
        longitude: pointDraft.longitude,
        maxGroups: Number(pointDraft.maxGroups),
        maxChildren: Number(pointDraft.maxChildren),
        accessible: pointDraft.accessible === "" ? null : pointDraft.accessible === "true",
        accessibilityNotes: pointDraft.accessibilityNotes,
        verified: true,
      },
      _expected_version: null,
      _reason: reason,
    });
    setBusy(false);
    setNotice(error ? `Startpunt geweigerd: ${error.message}` : "Geverifieerd startpunt toegevoegd. Voeg nu één of meer exacte tijden toe.");
    if (!error) { setPointDraft(emptyPoint); await load(); }
  }

  async function addSlot(point: StartPoint) {
    const value = window.prompt("Exact startmoment (ISO of datum en tijd), bijvoorbeeld 2026-10-31T17:30")?.trim();
    if (!value) return;
    const startsAt = new Date(value);
    if (Number.isNaN(startsAt.getTime())) return setNotice("Het startmoment is niet geldig.");
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("admin_start_slot_save", {
      _event_slug: eventSlug, _slot_id: null, _start_point_id: point.id,
      _starts_at: startsAt.toISOString(), _max_groups: point.maxGroups, _max_children: point.maxChildren,
      _reason: "Exact startmoment toegevoegd aan geverifieerd fysiek startpunt",
    });
    setNotice(error ? `Starttijd geweigerd: ${error.message}` : "Starttijd toegevoegd.");
    if (!error) await load();
  }

  function calculate() {
    if (!snapshot?.settings || !starts.length) return setNotice("Configureer eerst de tijden, eindpoort en geverifieerde startpunten.");
    const settings = snapshot.settings;
    const input: PlanningInput = {
      parties: snapshot.unassigned.map((party) => ({
        id: party.id, childCount: party.childCount, startPreference: party.startPreference,
        requestedStopAt: party.ordinaryStopAt, togetherKey: party.togetherKey ?? undefined,
        paymentEligible: party.paymentEligible,
      })),
      starts,
      targetGroupSize: Math.min(7, maxGroupSize), maxGroupSize,
      globalOrdinaryStopAt: settings.globalOrdinaryStopAt ?? "",
      finaleOpensAt: settings.finaleOpensAt ?? "", finaleLastArrivalAt: settings.finaleLastArrivalAt ?? "",
      finaleClosesAt: settings.finaleClosesAt ?? "", finaleShowSeconds: settings.finaleShowSeconds,
      finaleTurnoverSeconds: settings.finaleTurnoverSeconds,
      finalePlanningTransferSeconds: settings.finalePlanningTransferSeconds,
      finaleMaxGroups: settings.finaleMaxGroups, finaleMaxChildren: settings.finaleMaxChildren,
      earlyPreferenceLatestAt: settings.earlyPreferenceLatestAt,
      laterPreferenceEarliestAt: settings.laterPreferenceEarliestAt,
    };
    const result = proposePlan(input);
    setProposal(result); setScheduleIds([]);
    setNotice(result.conflicts.length ? "Het voorstel bevat blokkerende conflicten." : "Concept berekend. Startbesluiten blijven ongewijzigd totdat je opslaat en publiceert.");
  }

  async function saveProposal() {
    if (!proposal?.groups.length || proposal.conflicts.length) return;
    const client = createClient(); if (!client) return;
    const key = crypto.randomUUID();
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_apply_dynamic_plan", {
      _event_slug: eventSlug, _proposal: proposal, _input_hash: await digest(proposal),
      _idempotency_key: key, _request_hash: await digest({ proposal, key }),
    });
    setBusy(false);
    if (error) return setNotice(`Concept opslaan geweigerd: ${error.message}`);
    setScheduleIds((data as { scheduleIds: string[] }).scheduleIds);
    setNotice("Groepen en startafspraken als concept opgeslagen. Er is nog niets aan deelnemers gepubliceerd.");
    await load();
  }

  async function publish() {
    if (!scheduleIds.length || !window.confirm("Bevestig deze indeling en verstuur één bericht per bevoegde volwassene?")) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_publish_group_schedules", {
      _event_slug: eventSlug, _schedule_ids: scheduleIds,
      _reason: "Indeling expliciet bevestigd na controle van start- en finale-capaciteit",
    });
    setBusy(false);
    setNotice(error ? `Publicatie geblokkeerd: ${error.message}` : "Indeling bevestigd; startgegevens zijn vrijgegeven en berichten staan in de verzendwachtrij.");
    if (!error) { setScheduleIds([]); setProposal(null); await load(); }
  }

  async function moveGroup(group: Group, startSlotId: string) {
    if (!group.schedule || startSlotId === group.schedule.startSlotId || !snapshot) return;
    const slot = starts.find((candidate) => candidate.id === startSlotId);
    if (!slot) return setNotice("Het gekozen startmoment is niet meer beschikbaar.");
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_save_group_schedule", {
      _group_id: group.id, _start_slot_id: startSlotId,
      _effective_stop_at: group.schedule.effectiveStopAt,
      _expected_finale_arrival_at: group.schedule.expectedFinaleArrivalAt,
      _queue_number: null, _preference_match: matchPreference(group, slot, snapshot.settings),
      _reason: "Handmatige startcorrectie op het planbord",
    });
    if (error) return setNotice(`Verplaatsen geblokkeerd: ${error.message}`);
    const next = data as { id: string };
    setScheduleIds((current) => [...new Set([...current, next.id])]);
    setNotice("Nieuwe conceptrevisie gemaakt. Publiceer alleen deze betrokken groep na controle.");
    await load();
  }

  if (!snapshot || !settingsDraft) return <section className="panel loading-state"><RefreshCw className="spin" />Startpunten en indeling ophalen…</section>;
  return <div className="dashboard-stack start-schedule-board">
    {notice && <div className="form-notice" role="status">{notice}</div>}
    <section className="panel">
      <p className="kicker">Configureerbaar · Europe/Amsterdam</p><h2>Route- en eindpoortinstellingen</h2>
      <div className="settings-grid">
        <label className="field"><span>Eerste mogelijke start</span><input type="datetime-local" value={datetimeLocal(settingsDraft.firstStartAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, firstStartAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Vroeg geldt tot</span><input type="datetime-local" value={datetimeLocal(settingsDraft.earlyPreferenceLatestAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, earlyPreferenceLatestAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Later geldt vanaf</span><input type="datetime-local" value={datetimeLocal(settingsDraft.laterPreferenceEarliestAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, laterPreferenceEarliestAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Geen nieuwe gewone poorten vanaf</span><input type="datetime-local" value={datetimeLocal(settingsDraft.globalOrdinaryStopAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, globalOrdinaryStopAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Gemiddelde duur gewone poort (seconden)</span><input type="number" min={60} value={settingsDraft.ordinaryVisitSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, ordinaryVisitSeconds: Number(event.target.value) })} /></label>
        <label className="field"><span>Veiligheidsbuffer per stap (seconden)</span><input type="number" min={0} value={settingsDraft.bufferSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, bufferSeconds: Number(event.target.value) })} /></label>
        <label className="field"><span>Aangewezen laatste poort</span><select value={settingsDraft.finalPortalId ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finalPortalId: event.target.value || null })}><option value="">Kies een geverifieerde poort</option>{snapshot.portals.filter((portal) => portal.verified).map((portal) => <option key={portal.id} value={portal.id}>{portal.name} · {portal.world}</option>)}</select></label>
        <label className="field"><span>Plannerstand</span><select value={settingsDraft.plannerMode} onChange={(event) => setSettingsDraft({ ...settingsDraft, plannerMode: event.target.value as RouteSettings["plannerMode"] })}><option value="disabled">Uit</option><option value="shadow">Schaduwberekening</option><option value="dynamic">Live dynamisch</option></select></label>
        <label className="check-row"><input type="checkbox" checked={settingsDraft.finaleAvailable} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleAvailable: event.target.checked })} /><span>Laatste poort is veilig beschikbaar</span></label>
        <label className="field"><span>Opening laatste poort</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleOpensAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleOpensAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Laatste aankomst</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleLastArrivalAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleLastArrivalAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Sluiting laatste poort</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleClosesAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleClosesAt: iso(event.target.value) })} /></label>
        <label className="field"><span>Showduur (seconden)</span><input type="number" min={60} value={settingsDraft.finaleShowSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleShowSeconds: Number(event.target.value) })} /></label>
        <label className="field"><span>Tijd tussen ontvangsten (seconden)</span><input type="number" min={0} value={settingsDraft.finaleTurnoverSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleTurnoverSeconds: Number(event.target.value) })} /></label>
        <label className="field"><span>Gereserveerde looptijd naar finale (seconden)</span><input type="number" min={60} value={settingsDraft.finalePlanningTransferSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, finalePlanningTransferSeconds: Number(event.target.value) })} /></label>
        <label className="field"><span>Groepen tegelijk</span><input type="number" min={1} value={settingsDraft.finaleMaxGroups} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleMaxGroups: Number(event.target.value) })} /></label>
        <label className="field"><span>Kinderen tegelijk</span><input type="number" min={1} value={settingsDraft.finaleMaxChildren} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleMaxChildren: Number(event.target.value) })} /></label>
        <label className="field"><span>Veilige aanloop</span><textarea value={settingsDraft.finaleSafeApproach ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleSafeApproach: event.target.value })} /></label>
        <label className="field"><span>Wachtruimte</span><textarea value={settingsDraft.finaleWaitingArea ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleWaitingArea: event.target.value })} /></label>
        <label className="field"><span>Afvoerroute</span><textarea value={settingsDraft.finaleExitRoute ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleExitRoute: event.target.value })} /></label>
        <label className="field"><span>Toegankelijke ingang</span><textarea value={settingsDraft.finaleAccessibleEntrance ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleAccessibleEntrance: event.target.value })} /></label>
        <label className="field"><span>Contactpersoon laatste poort</span><input value={settingsDraft.finaleContact ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleContact: event.target.value })} /></label>
        <label className="field"><span>Veilige alternatieve verzamelplek</span><input value={settingsDraft.emergencyDestinationName ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, emergencyDestinationName: event.target.value })} /></label>
        <label className="field"><span>Noodinstructie bij uitval laatste poort</span><textarea value={settingsDraft.emergencyInstructions ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, emergencyInstructions: event.target.value })} /></label>
      </div>
      <div className="separator" /><h3>Aangeboden persoonlijke stopmomenten</h3>
      <div className="settings-grid">{settingsDraft.allowedStopTimes.map((value, index) => <label className="field" key={`${value}-${index}`}><span>Stopmoment {index + 1}</span><input type="datetime-local" value={datetimeLocal(value)} onChange={(event) => { const next = [...settingsDraft.allowedStopTimes]; const parsed = iso(event.target.value); if (parsed) next[index] = parsed; setSettingsDraft({ ...settingsDraft, allowedStopTimes: next }); }} /><button type="button" className="text-link" onClick={() => setSettingsDraft({ ...settingsDraft, allowedStopTimes: settingsDraft.allowedStopTimes.filter((_, candidate) => candidate !== index) })}>Verwijderen</button></label>)}</div>
      <button type="button" className="btn outline" onClick={() => { const fallback = settingsDraft.globalOrdinaryStopAt ?? settingsDraft.finaleOpensAt; if (fallback) setSettingsDraft({ ...settingsDraft, allowedStopTimes: [...settingsDraft.allowedStopTimes, fallback] }); }}>Stopmoment toevoegen</button>
      <button className="btn" disabled={busy} onClick={() => void saveSettings()}><Save />Instellingen opslaan</button>
    </section>

    <section className="panel"><p className="kicker">Privé beheerkaart</p><h2>Fysieke startpunten</h2><p>Alleen beheerders zien deze adressen. Een startpunt wordt pas bruikbaar na koppeling aan een geverifieerde node in het veilige wandelnetwerk.</p>
      {mapPoints.length > 0 && <NightMap variant="admin" portals={mapPoints} ariaLabel="Beheerkaart met geverifieerde startpunten" />}
      {snapshot.startPoints.map((point) => <article className="summary-row" key={point.id}><span><strong>{point.name}</strong><br />{point.privateAddress} · {point.verified ? "geverifieerd" : "niet geverifieerd"}<span className="start-slot-drop-list">{point.slots.length ? point.slots.map((slot) => <button type="button" className="start-slot-drop" key={slot.id} onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); const group = snapshot.groups.find((item) => item.id === event.dataTransfer.getData("text/group-id")); if (group) void moveGroup(group, slot.id); }} onClick={() => setNotice(`${point.name} om ${new Date(slot.startsAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}: sleep hier een groepskaart naartoe of kies dit tijdstip in het formulier.`)}>{new Date(slot.startsAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</button>) : "nog geen tijden"}</span></span><button className="btn outline" onClick={() => void addSlot(point)}><Clock3 />Tijd toevoegen</button></article>)}
      <div className="separator" /><h3>Startpunt toevoegen</h3><div className="settings-grid">
        <label className="field"><span>Naam</span><input value={pointDraft.name} onChange={(event) => setPointDraft({ ...pointDraft, name: event.target.value })} /></label>
        <label className="field"><span>Privéadres</span><input value={pointDraft.privateAddress} onChange={(event) => setPointDraft({ ...pointDraft, privateAddress: event.target.value })} /></label>
        <label className="field"><span>Latitude uit geverifieerde kaartdata</span><input inputMode="decimal" value={pointDraft.latitude} onChange={(event) => setPointDraft({ ...pointDraft, latitude: event.target.value })} /></label>
        <label className="field"><span>Longitude uit geverifieerde kaartdata</span><input inputMode="decimal" value={pointDraft.longitude} onChange={(event) => setPointDraft({ ...pointDraft, longitude: event.target.value })} /></label>
        <label className="field"><span>Geverifieerde wandelnode-ID</span><input value={pointDraft.walkingNodeId} onChange={(event) => setPointDraft({ ...pointDraft, walkingNodeId: event.target.value })} /></label>
        <label className="field"><span>Bereikbaarheid</span><select value={pointDraft.accessible} onChange={(event) => setPointDraft({ ...pointDraft, accessible: event.target.value as DraftPoint["accessible"] })}><option value="">Nog te beoordelen</option><option value="true">Toegankelijk</option><option value="false">Niet volledig toegankelijk</option></select></label>
        <label className="field"><span>Toelichting bereikbaarheid</span><textarea value={pointDraft.accessibilityNotes} onChange={(event) => setPointDraft({ ...pointDraft, accessibilityNotes: event.target.value })} /></label>
        <label className="field"><span>Maximaal groepen op verzamelplek</span><input type="number" min={1} value={pointDraft.maxGroups} onChange={(event) => setPointDraft({ ...pointDraft, maxGroups: event.target.value })} /></label>
        <label className="field"><span>Maximaal kinderen op verzamelplek</span><input type="number" min={1} value={pointDraft.maxChildren} onChange={(event) => setPointDraft({ ...pointDraft, maxChildren: event.target.value })} /></label>
      </div><button className="btn outline" disabled={busy || !pointDraft.name || !pointDraft.privateAddress || !pointDraft.walkingNodeId} onClick={() => void addStartPoint()}><MapPinned />Geverifieerd startpunt bewaren</button>
    </section>

    <section className="panel"><p className="kicker">Geen vast aantal huizen</p><h2>Groepen en startafspraken</h2><p>Het voorstel maakt alleen groepen en reserveert finale-instroom. Gewone poorten worden pas live, één voor één, door de server gekozen.</p>
      <div className="actions"><button className="btn" disabled={busy || snapshot.unassigned.length === 0} onClick={calculate}>Bereken concept</button><button className="btn outline" disabled={busy || !proposal?.groups.length || Boolean(proposal?.conflicts.length)} onClick={() => void saveProposal()}>Concept bewaren</button><button className="btn outline" disabled={busy || !scheduleIds.length} onClick={() => void publish()}><Send />Indeling bevestigen</button>{proposal && <button className="text-link" onClick={() => { setProposal(null); setScheduleIds([]); setNotice("Lokale berekening ongedaan gemaakt."); }}>Ongedaan maken</button>}</div>
      {proposal?.conflicts.map((conflict) => <div className="form-warning" key={`${conflict.code}-${conflict.subjectId}`}><AlertTriangle />{conflict.code}: {conflict.message}</div>)}
      {proposal?.groups.map((group: PlannedGroup) => {
        const registrations = group.partyIds.map((id) => snapshot.unassigned.find((party) => party.id === id)).filter((party): party is Unassigned => Boolean(party));
        return <article className={`schedule-card match-${group.preferenceMatch}`} key={group.key}><div><strong>{group.key} · {group.childCount} kinderen</strong><p>{matchLabels[group.preferenceMatch]} · stop gewone poorten {new Date(group.effectiveStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })} · finale circa {new Date(group.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</p><small>{registrations.map((registration) => `${registration.reference}: ${registration.startPreference}, ${registration.paymentEligible ? "betaald" : "betaling open"}`).join(" · ")}</small>{group.warnings.includes("PAYMENT_NOT_CONFIRMED") && <small>Conceptraming: betaling nog niet bevestigd; publicatie blokkeert.</small>}</div><UsersRound /></article>;
      })}
      {snapshot.groups.filter((group) => group.routeMode === "dynamic" && group.schedule).map((group) => <article className={`schedule-card match-${group.schedule!.preferenceMatch}`} key={group.id} draggable onDragStart={(event) => event.dataTransfer.setData("text/group-id", group.id)}><div><strong>{group.code} · {group.childCount} kinderen · revisie {group.schedule!.revision}</strong><p>{matchLabels[group.schedule!.preferenceMatch]} · {group.schedule!.state} · finale {new Date(group.schedule!.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</p><small>{group.registrations.map((registration) => `${registration.reference}: ${registration.startPreference}, ${registration.paymentEligible ? "betaald" : "betaling open"}`).join(" · ")}</small><label className="field"><span>Startpunt en tijd (toetsenbord/formulier)</span><select value={group.schedule!.startSlotId} onChange={(event) => void moveGroup(group, event.target.value)}>{snapshot.startPoints.flatMap((point) => point.slots.map((slot) => <option key={slot.id} value={slot.id}>{point.name} · {new Date(slot.startsAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</option>))}</select></label></div>{group.schedule!.state === "published" ? <CheckCircle2 /> : <Clock3 />}</article>)}
      <div className="separator" /><h3>Voorspelde druk op de laatste poort</h3>{snapshot.finaleFlow.length ? snapshot.finaleFlow.map((row) => <div className="summary-row" key={row.window}><span>{new Date(row.window).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</span><strong>{row.groups} groepen · {row.children} kinderen</strong></div>) : <p>Nog geen concept- of gepubliceerde finalevensters.</p>}
    </section>
  </div>;
}
