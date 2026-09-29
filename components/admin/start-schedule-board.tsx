"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  AlertTriangle, Archive, CalendarClock, Check, CheckCircle2, ChevronRight, CircleGauge,
  Clock3, Eye, Filter, Map as MapIcon, MapPin, MapPinned, Plus, Radio, RefreshCw, Save, Send,
  Settings2, ShieldAlert, Sparkles, Undo2, UsersRound, X,
} from "lucide-react";
import { LocationEditor, type LocationSave } from "@/components/admin/location-editor";
import { NightMap } from "@/components/maps/night-map";
import { proposePlan, type PlannedGroup, type PlanningInput, type PreferenceMatch } from "@/lib/domain/route-planner";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { createClient } from "@/lib/supabase/client";

type RouteSettings = {
  version: number;
  plannerMode: "disabled" | "shadow" | "dynamic";
  firstStartAt: string | null;
  earlyPreferenceLatestAt: string | null;
  laterPreferenceEarliestAt: string | null;
  globalOrdinaryStopAt: string | null;
  allowedStopTimes: string[];
  allowedStartTimes: string[];
  allowedEndTimes: string[];
  startIntervalMinutes: number;
  preferenceGreenMinutes: number;
  preferenceAmberMinutes: number;
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
  id: string; name: string; publicLabel: string; pointType: "gathering" | "portal"; linkedPortalId: string | null;
  privateAddress: string | null; publicArrivalInstructions: string | null; internalNotes: string | null;
  availableFrom: string | null; availableUntil: string | null; safeApproach: string | null;
  countsAsFirstPortalVisit: boolean; contactName: string | null; contactPhone: string | null;
  geocodedLatitude: number | null; geocodedLongitude: number | null; markerLatitude: number | null; markerLongitude: number | null;
  latitude: number | null; longitude: number | null; locationSource: "address" | "manual"; markerReason: string | null;
  markerDistanceMeters: number | null; markerUpdatedAt: string | null; walkingNodeId: string | null; walkingNodeUpdatedAt: string | null;
  verified: boolean; accessible: boolean | null; accessibilityNotes: string | null; maxGroups: number; maxChildren: number;
  active: boolean; version: number; slots: Slot[];
};

type Portal = {
  id: string; code: string; systemCode: string; name: string; world: string; worldSlug: string; color: string | null;
  description: string; approvalStatus: string; lifecycleStatus: string; operationStatus: string; recordSource: string;
  contactName: string | null; phone: string | null; email: string | null; address: string | null; postalCode: string | null;
  city: string | null; geocodedLatitude: number | null; geocodedLongitude: number | null; markerLatitude: number | null;
  markerLongitude: number | null; latitude: number | null; longitude: number | null; locationSource: "address" | "manual";
  markerReason: string | null; markerUpdatedAt: string | null; plannedOpensAt: string | null; plannedClosesAt: string | null;
  maxGroups: number | null; maxChildren: number | null; candidateStartPoint: boolean; isFinal: boolean; version: number;
};

type RegistrationRow = {
  id: string; reference: string; startPreference: string; ordinaryStopAt: string | null;
  preferredStartAt: string | null; desiredEndAt: string | null; paymentEligible: boolean;
};
type Schedule = {
  id: string; revision: number; state: string; startSlotId: string; effectiveStopAt: string;
  expectedFinaleArrivalAt: string; preferenceMatch: PreferenceMatch; warnings: string[];
};
type Group = {
  id: string; code: string; systemCode?: string; displayName?: string | null; status: string; version: number;
  routeMode: string; childCount: number; registrations: RegistrationRow[]; schedule: Schedule | null;
};
type Unassigned = {
  id: string; reference: string; childCount: number; startPreference: "early" | "indifferent" | "later";
  ordinaryStopAt: string | null; preferredStartAt: string | null; desiredEndAt: string | null;
  togetherKey?: string | null; paymentStatus?: string | null; paymentEligible: boolean;
};
type Warning = { code: string; message: string; action: "indeling" | "kaart"; resourceId: string | null };
type Stats = {
  activeStartPoints: number; plannedGroups: number; unassignedGroups: number; withinPreferencePercent: number;
  capacityConflicts: number; missingMarkers: number; unavailableLinkedPortals: number; publicationStatus: string;
};
type Snapshot = {
  eventId: string; realtimeTopic: string | null; settings: RouteSettings; startPoints: StartPoint[]; portals: Portal[];
  groups: Group[]; unassigned: Unassigned[]; finaleFlow: Array<{ window: string; groups: number; children: number }>;
  warnings: Warning[]; stats: Stats; planningVersions: Array<{ id: string; version: number; state: string; publishedAt: string; reason: string }>;
};

type PointDraft = {
  id: string | null; version: number | null; name: string; publicLabel: string; pointType: "gathering" | "portal";
  linkedPortalId: string; privateAddress: string; publicArrivalInstructions: string; internalNotes: string;
  availableFrom: string; availableUntil: string; maxGroups: string; maxChildren: string; accessible: "" | "true" | "false";
  accessibilityNotes: string; safeApproach: string; countsAsFirstPortalVisit: boolean; contactName: string; contactPhone: string;
  geocodedLatitude: string; geocodedLongitude: string; markerLatitude: string; markerLongitude: string; markerReason: string; active: boolean;
};

type PlanningTab = "planning" | "points" | "map" | "settings";
type MoveTarget = { pointId: string; startsAt: string };
type UndoMove = { groupId: string; pointId: string; startsAt: string; groupVersion: number };

const matchLabels: Record<PreferenceMatch, string> = {
  good: "Binnen voorkeur", small_deviation: "Kleine afwijking", large_deviation: "Duidelijke afwijking", neutral: "Maakt niet uit",
};
const matchIcons: Record<PreferenceMatch, typeof CheckCircle2> = {
  good: CheckCircle2, small_deviation: Clock3, large_deviation: AlertTriangle, neutral: CircleGauge,
};
const emptyPoint: PointDraft = {
  id: null, version: null, name: "", publicLabel: "", pointType: "gathering", linkedPortalId: "", privateAddress: "",
  publicArrivalInstructions: "", internalNotes: "", availableFrom: "", availableUntil: "", maxGroups: "1", maxChildren: "20",
  accessible: "", accessibilityNotes: "", safeApproach: "", countsAsFirstPortalVisit: false, contactName: "", contactPhone: "",
  geocodedLatitude: "", geocodedLongitude: "", markerLatitude: "", markerLongitude: "", markerReason: "", active: true,
};

function datetimeLocal(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}

function iso(value: string) { return value ? new Date(value).toISOString() : null; }
function timeLabel(value: string | null | undefined) {
  return value ? new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "–";
}
async function digest(value: unknown) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
function coordinate(longitude: number | null, latitude: number | null): [number, number] | null {
  return longitude === null || latitude === null ? null : [longitude, latitude];
}
function planningTimes(settings: RouteSettings) {
  const configured = [...new Set(settings.allowedStartTimes ?? [])].filter((value) => Number.isFinite(Date.parse(value))).sort();
  if (configured.length) return configured;
  const start = settings.firstStartAt ? Date.parse(settings.firstStartAt) : Number.NaN;
  const absoluteEnd = settings.globalOrdinaryStopAt ? Date.parse(settings.globalOrdinaryStopAt) : Number.NaN;
  if (!Number.isFinite(start) || !Number.isFinite(absoluteEnd)) return [];
  const defaultPreferenceWindow = 150 * 60_000;
  const end = Math.min(absoluteEnd, start + defaultPreferenceWindow);
  const step = Math.max(5, settings.startIntervalMinutes || 15) * 60_000;
  return Array.from({ length: Math.floor((end - start) / step) + 1 }, (_, index) => new Date(start + index * step).toISOString());
}
function groupLocation(group: Group, points: StartPoint[]) {
  if (!group.schedule) return null;
  for (const point of points) {
    const slot = point.slots.find((candidate) => candidate.id === group.schedule?.startSlotId);
    if (slot) return { point, slot };
  }
  return null;
}
function groupDeviation(group: Group, startsAt: string) {
  const preferences = group.registrations.flatMap((registration) => registration.preferredStartAt ? [Date.parse(registration.preferredStartAt)] : []);
  if (!preferences.length) return null;
  const value = Date.parse(startsAt);
  return Math.max(...preferences.map((preference) => Math.round(Math.abs(value - preference) / 60_000)));
}
function pointDraft(point: StartPoint): PointDraft {
  return {
    id: point.id, version: point.version, name: point.name, publicLabel: point.publicLabel, pointType: point.pointType,
    linkedPortalId: point.linkedPortalId ?? "", privateAddress: point.privateAddress ?? "",
    publicArrivalInstructions: point.publicArrivalInstructions ?? "", internalNotes: point.internalNotes ?? "",
    availableFrom: datetimeLocal(point.availableFrom), availableUntil: datetimeLocal(point.availableUntil),
    maxGroups: String(point.maxGroups), maxChildren: String(point.maxChildren),
    accessible: point.accessible === null ? "" : point.accessible ? "true" : "false",
    accessibilityNotes: point.accessibilityNotes ?? "", safeApproach: point.safeApproach ?? "",
    countsAsFirstPortalVisit: point.countsAsFirstPortalVisit, contactName: point.contactName ?? "", contactPhone: point.contactPhone ?? "",
    geocodedLatitude: point.geocodedLatitude?.toString() ?? "", geocodedLongitude: point.geocodedLongitude?.toString() ?? "",
    markerLatitude: point.markerLatitude?.toString() ?? "", markerLongitude: point.markerLongitude?.toString() ?? "",
    markerReason: point.markerReason ?? "", active: point.active,
  };
}

function readableError(message: string) {
  const mappings: Array<[string, string]> = [
    ["START_POINT_CAPACITY_EXCEEDED", "Dit startmoment heeft niet genoeg ruimte voor deze routegroep."],
    ["LINKED_PORTAL_NOT_OPEN", "De gekoppelde poort is op dit moment niet gepland geopend."],
    ["START_POINT_MARKER_INVALID", "Dit startpunt heeft nog geen geldige routingmarker en wandelkoppeling."],
    ["START_POINT_CLOSED", "Dit startpunt is buiten zijn geplande beschikbaarheid."],
    ["START_TIME_OUTSIDE_EVENT", "Dit tijdstip valt buiten het ingestelde startvenster."],
    ["STALE_VERSION", "Iemand anders heeft deze gegevens zojuist gewijzigd. De actuele planning is opnieuw geladen."],
    ["MOVE_GROUPS_FIRST", "Verplaats eerst de gekoppelde routegroepen naar een ander startpunt."],
  ];
  return mappings.find(([code]) => message.includes(code))?.[1] ?? message;
}

function GroupCard({ group, points, times, visitCycleSeconds, compact = false, onMove }: {
  group: Group; points: StartPoint[]; times: string[]; visitCycleSeconds: number; compact?: boolean; onMove: (group: Group, target: MoveTarget) => void;
}) {
  const location = groupLocation(group, points);
  const [target, setTarget] = useState(location ? `${location.point.id}|${location.slot.startsAt}` : "");
  const match = group.schedule?.preferenceMatch ?? "neutral";
  const Icon = matchIcons[match];
  const deviation = location ? groupDeviation(group, location.slot.startsAt) : null;
  const preferred = group.registrations.find((registration) => registration.preferredStartAt)?.preferredStartAt;
  const desiredEnd = group.registrations.map((registration) => registration.desiredEndAt).filter(Boolean).sort()[0] ?? null;
  const estimatedStops = desiredEnd && (location?.slot.startsAt ?? preferred)
    ? Math.max(0, Math.floor((Date.parse(desiredEnd) - Date.parse(location?.slot.startsAt ?? preferred!)) / (Math.max(60, visitCycleSeconds) * 1_000)))
    : null;
  const warnings = [...new Set(group.schedule?.warnings ?? [])];
  return <article
    className={`start-group-card match-${match}${compact ? " compact" : ""}`}
    draggable
    onDragStart={(event) => { event.dataTransfer.effectAllowed = "move"; event.dataTransfer.setData("text/group-id", group.id); }}
    data-group-id={group.id}
  >
    <header><div><strong>{group.systemCode || group.code}</strong>{group.displayName && <span>{group.displayName}</span>}</div><span className={`preference-badge match-${match}`}><Icon />{matchLabels[match]}</span></header>
    <div className="start-group-facts">
      <span><UsersRound />{group.registrations.length} inschrijving(en) · {group.childCount} kinderen</span>
      <span><UsersRound />{group.registrations.length > 1 ? `Samenloop/routegroep met ${group.registrations.length} inschrijvingen` : "Zelfstandige inschrijving"}</span>
      <span><Clock3 />Voorkeur {timeLabel(preferred)}{location ? ` · gepland ${timeLabel(location.slot.startsAt)}` : " · nog niet gepland"}</span>
      <span><CalendarClock />{deviation === null ? "Geen vaste startvoorkeur" : deviation === 0 ? "Exact op voorkeur" : `${deviation} minuten verschil`} · einde gewenst {timeLabel(desiredEnd)}{estimatedStops === null ? "" : ` · circa ${estimatedStops} stops`}</span>
      <span><MapPin />{location?.point.publicLabel ?? "Nog geen startpunt"}</span>
    </div>
    {group.registrations.some((registration) => !registration.paymentEligible) && <p className="group-inline-warning"><ShieldAlert />Betaling nog niet bevestigd; publiceren blijft geblokkeerd.</p>}
    {warnings.map((warning) => <p className="group-inline-warning" key={warning}><AlertTriangle />{warning.replaceAll("_", " ").toLowerCase()}</p>)}
    <label className="start-move-control"><span>Verplaats naar…</span><select value={target} onChange={(event) => {
      setTarget(event.target.value);
      const [pointId, startsAt] = event.target.value.split("|");
      if (pointId && startsAt) onMove(group, { pointId, startsAt });
    }}><option value="">Kies startpunt en tijd</option>{points.filter((point) => point.active).flatMap((point) => times.map((startsAt) => <option key={`${point.id}-${startsAt}`} value={`${point.id}|${startsAt}`}>{point.publicLabel} · {timeLabel(startsAt)}</option>))}</select></label>
  </article>;
}

export function StartScheduleBoard({ eventSlug, maxGroupSize, onOpenPortals }: { eventSlug: string; maxGroupSize: number; onOpenPortals?: () => void }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [settingsDraft, setSettingsDraft] = useState<RouteSettings | null>(null);
  const [tab, setTab] = useState<PlanningTab>("planning");
  const [pointEditor, setPointEditor] = useState<PointDraft | null>(null);
  const [mapSelection, setMapSelection] = useState<{ kind: "start" | "portal"; id: string } | null>(null);
  const [proposal, setProposal] = useState<ReturnType<typeof proposePlan> | null>(null);
  const [scheduleIds, setScheduleIds] = useState<string[]>([]);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [undoMove, setUndoMove] = useState<UndoMove | null>(null);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [filters, setFilters] = useState({ time: "", point: "", preference: "", status: "", warning: false });

  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_startregie_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice(`Startregie ophalen mislukt: ${readableError(error.message)}`);
    const next = data as Snapshot;
    setSnapshot(next);
    setSettingsDraft((current) => current && current.version !== next.settings.version ? current : next.settings);
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  const realtimeConnected = usePrivateBroadcast(snapshot?.realtimeTopic, () => void load());

  const times = useMemo(() => snapshot ? planningTimes(snapshot.settings) : [], [snapshot]);
  const activePoints = useMemo(() => snapshot?.startPoints.filter((point) => point.active) ?? [], [snapshot]);
  const selectedMapResource = useMemo(() => {
    if (!snapshot || !mapSelection) return null;
    return mapSelection.kind === "start"
      ? snapshot.startPoints.find((point) => point.id === mapSelection.id) ?? null
      : snapshot.portals.find((portal) => portal.id === mapSelection.id) ?? null;
  }, [mapSelection, snapshot]);
  const mapItems = useMemo(() => snapshot ? [
    ...snapshot.startPoints.filter((point) => point.active && point.latitude !== null && point.longitude !== null).map((point) => ({
      id: `start-${point.id}`, code: "S", name: point.publicLabel, world: point.pointType === "portal" ? "Startpoort" : "Verzamelpunt",
      coordinate: [point.longitude!, point.latitude!] as [number, number], address: point.privateAddress ?? undefined, status: "scheduled" as const,
    })),
    ...snapshot.portals.filter((portal) => portal.latitude !== null && portal.longitude !== null).map((portal) => ({
      id: `portal-${portal.id}`, code: portal.systemCode, name: portal.name, world: portal.world,
      coordinate: [portal.longitude!, portal.latitude!] as [number, number], address: portal.address ?? undefined,
      contactName: portal.contactName ?? undefined, phone: portal.phone ?? undefined, status: portal.operationStatus,
      isFinal: portal.isFinal, color: portal.color ?? undefined,
    })),
  ] : [], [snapshot]);

  const visibleTimes = times.filter((value) => !filters.time || value === filters.time);
  const visiblePoints = activePoints.filter((point) => !filters.point || point.id === filters.point);
  const visibleGroups = (snapshot?.groups ?? []).filter((group) => {
    const location = snapshot ? groupLocation(group, snapshot.startPoints) : null;
    return (!filters.preference || group.schedule?.preferenceMatch === filters.preference)
      && (!filters.status || group.schedule?.state === filters.status)
      && (!filters.warning || Boolean(group.schedule?.warnings.length) || group.registrations.some((registration) => !registration.paymentEligible))
      && (!filters.point || location?.point.id === filters.point)
      && (!filters.time || location?.slot.startsAt === filters.time);
  });

  async function saveSettings() {
    if (!snapshot || !settingsDraft) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_startregie_settings_save", {
      _event_slug: eventSlug, _settings: settingsDraft, _expected_version: snapshot.settings.version,
      _reason: "Startregie-kaders bijgewerkt via de beheeromgeving",
    });
    setBusy(false);
    setNotice(error ? `Kaders opslaan geweigerd: ${readableError(error.message)}` : "De planningskaders zijn versieerbaar opgeslagen.");
    if (!error) await load();
  }

  async function calculate() {
    if (!snapshot || !times.length || !activePoints.length) return setNotice("Voeg eerst minimaal één routeklaar startpunt en een geldig startvenster toe.");
    const client = createClient(); if (!client) return;
    setBusy(true);
    const prepared = await client.schema("api").rpc("admin_startregie_slots_prepare", {
      _event_slug: eventSlug, _starts_at: times,
    });
    setBusy(false);
    if (prepared.error) return setNotice(`Startmomenten voorbereiden mislukt: ${readableError(prepared.error.message)}`);
    const preparedStarts = (prepared.data as { starts: Array<{ id: string; startPointId: string; startsAt: string; maxGroups: number; maxChildren: number }> }).starts;
    const portalById = new Map(snapshot.portals.map((portal) => [portal.id, portal]));
    const pointById = new Map(activePoints.map((point) => [point.id, point]));
    const starts = preparedStarts.flatMap((start) => {
      const point = pointById.get(start.startPointId);
      if (!point) return [];
      const portal = point.linkedPortalId ? portalById.get(point.linkedPortalId) : null;
      return [{
        ...start, pointName: point.publicLabel,
        availableFrom: point.availableFrom, availableUntil: point.availableUntil,
        portalOpensAt: portal?.plannedOpensAt, portalClosesAt: portal?.plannedClosesAt,
        markerValid: point.verified,
      }];
    });
    const settings = snapshot.settings;
    const input: PlanningInput = {
      parties: snapshot.unassigned.map((party) => ({
        id: party.id, childCount: party.childCount, startPreference: party.startPreference,
        requestedStopAt: party.ordinaryStopAt, preferredStartAt: party.preferredStartAt, desiredEndAt: party.desiredEndAt,
        togetherKey: party.togetherKey ?? undefined, paymentEligible: party.paymentEligible,
      })),
      starts, targetGroupSize: Math.min(7, maxGroupSize), maxGroupSize,
      globalOrdinaryStopAt: settings.globalOrdinaryStopAt ?? "", finaleOpensAt: settings.finaleOpensAt ?? "",
      finaleLastArrivalAt: settings.finaleLastArrivalAt ?? "", finaleClosesAt: settings.finaleClosesAt ?? "",
      finaleShowSeconds: settings.finaleShowSeconds, finaleTurnoverSeconds: settings.finaleTurnoverSeconds,
      finalePlanningTransferSeconds: settings.finalePlanningTransferSeconds, finaleMaxGroups: settings.finaleMaxGroups,
      finaleMaxChildren: settings.finaleMaxChildren, earlyPreferenceLatestAt: settings.earlyPreferenceLatestAt,
      laterPreferenceEarliestAt: settings.laterPreferenceEarliestAt, preferenceGreenMinutes: settings.preferenceGreenMinutes,
      preferenceAmberMinutes: settings.preferenceAmberMinutes,
    };
    const result = proposePlan(input);
    setProposal(result); setScheduleIds([]);
    setNotice(result.conflicts.length ? "Het voorstel bevat conflicten die eerst moeten worden opgelost." : "Conceptvoorstel berekend. Er is nog niets gepubliceerd of gemaild.");
  }

  async function saveProposal() {
    if (!proposal?.groups.length || proposal.conflicts.length) return;
    const client = createClient(); if (!client) return;
    const key = crypto.randomUUID(); setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_apply_dynamic_plan", {
      _event_slug: eventSlug, _proposal: proposal, _input_hash: await digest(proposal),
      _idempotency_key: key, _request_hash: await digest({ proposal, key }),
    });
    setBusy(false);
    if (error) return setNotice(`Concept opslaan geweigerd: ${readableError(error.message)}`);
    setScheduleIds((data as { scheduleIds: string[] }).scheduleIds);
    setNotice("Het voorstel is als concept opgeslagen. Deelnemers zien nog geen wijziging.");
    await load();
  }

  async function publish() {
    if (!scheduleIds.length || !snapshot) return;
    if (snapshot.warnings.some((warning) => ["CAPACITY", "MISSING_MARKER", "PORTAL_UNAVAILABLE"].includes(warning.code))) {
      return setNotice("Los de blokkerende marker-, capaciteit- en poortwaarschuwingen op vóór publicatie.");
    }
    if (!window.confirm(`Publiceer ${scheduleIds.length} nieuwe of gewijzigde startafspraak/afspraken? Alleen deze wijzigingen worden verzonden.`)) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_startregie_publish", {
      _event_slug: eventSlug, _schedule_ids: scheduleIds,
      _reason: "Startplanning gecontroleerd, conflicten opgelost en wijzigingen expliciet gepubliceerd",
    });
    setBusy(false);
    const result = data as { planningVersion?: number } | null;
    setNotice(error ? `Publicatie geblokkeerd: ${readableError(error.message)}` : `Planning gepubliceerd${result?.planningVersion ? ` als versie ${result.planningVersion}` : ""}. Alleen werkelijk gewijzigde toewijzingen zijn verzonden.`);
    if (!error) { setScheduleIds([]); setProposal(null); await load(); }
  }

  async function moveGroup(group: Group, target: MoveTarget, isUndo = false) {
    if (!snapshot) return;
    const current = groupLocation(group, snapshot.startPoints);
    if (current?.point.id === target.pointId && Math.abs(Date.parse(current.slot.startsAt) - Date.parse(target.startsAt)) < 1000) return;
    const deviation = groupDeviation(group, target.startsAt);
    const match: PreferenceMatch = deviation === null ? "neutral"
      : deviation <= snapshot.settings.preferenceGreenMinutes ? "good"
      : deviation <= snapshot.settings.preferenceAmberMinutes ? "small_deviation" : "large_deviation";
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_startregie_move_group", {
      _group_id: group.id, _start_point_id: target.pointId, _starts_at: target.startsAt,
      _expected_group_version: group.version, _preference_match: match,
      _reason: isUndo ? "Vorige startplaatsing hersteld via Ongedaan maken" : "Routegroep handmatig verplaatst op het Startregie-planbord",
    });
    setBusy(false);
    if (error) { setNotice(`Verplaatsen geblokkeerd: ${readableError(error.message)}`); await load(); return; }
    const result = data as { id: string };
    setScheduleIds((currentIds) => [...new Set([...currentIds, result.id])]);
    if (!isUndo && current) setUndoMove({ groupId: group.id, pointId: current.point.id, startsAt: current.slot.startsAt, groupVersion: group.version + 1 });
    else setUndoMove(null);
    setNotice(isUndo ? "De vorige plaatsing is als nieuwe conceptrevisie hersteld." : "Nieuwe conceptplaatsing opgeslagen. Publiceren blijft een aparte stap.");
    await load();
  }

  async function undoLastMove() {
    if (!undoMove || !snapshot) return;
    const group = snapshot.groups.find((item) => item.id === undoMove.groupId);
    if (!group) return;
    await moveGroup({ ...group, version: undoMove.groupVersion }, { pointId: undoMove.pointId, startsAt: undoMove.startsAt }, true);
  }

  async function savePoint() {
    if (!pointEditor) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const payload = {
      ...pointEditor, linkedPortalId: pointEditor.pointType === "portal" ? pointEditor.linkedPortalId : null,
      availableFrom: iso(pointEditor.availableFrom), availableUntil: iso(pointEditor.availableUntil),
      maxGroups: Number(pointEditor.maxGroups), maxChildren: Number(pointEditor.maxChildren),
      accessible: pointEditor.accessible === "" ? null : pointEditor.accessible === "true",
    };
    const { error } = await client.schema("api").rpc("admin_startregie_start_point_save", {
      _event_slug: eventSlug, _point_id: pointEditor.id, _payload: payload,
      _expected_version: pointEditor.version,
      _reason: pointEditor.id ? "Startpuntgegevens bijgewerkt via Startregie" : "Nieuw startpunt toegevoegd via Startregie",
    });
    setBusy(false);
    setNotice(error ? `Startpunt opslaan geweigerd: ${readableError(error.message)}` : pointEditor.id ? "Startpunt bijgewerkt." : "Startpunt aangemaakt. De wandelkoppeling is automatisch berekend.");
    if (!error) { setPointEditor(null); await load(); }
  }

  async function archivePoint(point: StartPoint) {
    if (!window.confirm(`Archiveer ${point.name}? Gekoppelde routegroepen blokkeren deze actie.`)) return;
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("admin_startregie_start_point_archive", {
      _point_id: point.id, _expected_version: point.version, _reason: "Startpunt gearchiveerd vanuit Startregie",
    });
    setNotice(error ? `Archiveren geblokkeerd: ${readableError(error.message)}` : "Startpunt gearchiveerd.");
    if (!error) await load();
  }

  async function saveMarker(kind: "start" | "portal", resource: StartPoint | Portal, change: LocationSave) {
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_location_marker_save", {
      _event_slug: eventSlug, _resource_type: kind === "start" ? "start_point" : ("isFinal" in resource && resource.isFinal ? "final_portal" : "portal"),
      _resource_id: resource.id, _latitude: change.latitude, _longitude: change.longitude,
      _reason: change.reason, _restore_from_address: change.restoreFromAddress, _expected_version: resource.version,
    });
    setBusy(false);
    setNotice(error ? `Locatie opslaan geweigerd: ${readableError(error.message)}` : "Routingmarker opgeslagen, wandelnode opnieuw berekend en routecache ongeldig gemaakt.");
    if (!error) await load();
  }

  if (!snapshot || !settingsDraft) return <section className="panel loading-state"><RefreshCw className="spin" />Startregie ophalen…</section>;

  const publicationStep = scheduleIds.length ? 3 : proposal?.groups.length ? 2 : snapshot.stats.plannedGroups ? 1 : 0;
  return <div className="start-regie">
    <header className="start-regie-heading">
      <div><p className="kicker">Startpunten · tijden · routegroepen</p><h2>Startregie</h2><p>Plan iedere routegroep op een veilige plek en een haalbaar moment, controleer het concept en publiceer uitsluitend bewuste wijzigingen.</p></div>
      <div className="start-regie-live" data-connected={realtimeConnected}><Radio />{realtimeConnected ? "Live gesynchroniseerd" : "Verbinding herstellen…"}<button type="button" className="btn outline" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>
    </header>

    <section className="start-regie-cockpit" aria-label="Actuele kengetallen Startregie">
      <article><MapPinned /><strong>{snapshot.stats.activeStartPoints}</strong><span>actieve startpunten</span></article>
      <article><UsersRound /><strong>{snapshot.stats.plannedGroups}</strong><span>groepen gepland</span></article>
      <article className={snapshot.stats.unassignedGroups ? "needs-attention" : ""}><Clock3 /><strong>{snapshot.stats.unassignedGroups}</strong><span>nog niet ingedeeld</span></article>
      <article><CheckCircle2 /><strong>{snapshot.stats.withinPreferencePercent}%</strong><span>binnen voorkeur</span></article>
      <article className={snapshot.stats.capacityConflicts ? "is-danger" : ""}><UsersRound /><strong>{snapshot.stats.capacityConflicts}</strong><span>capaciteitsconflicten</span></article>
      <article className={snapshot.stats.missingMarkers ? "needs-attention" : ""}><MapPin /><strong>{snapshot.stats.missingMarkers}</strong><span>markers ongeldig</span></article>
      <article className={snapshot.stats.unavailableLinkedPortals ? "is-danger" : ""}><ShieldAlert /><strong>{snapshot.stats.unavailableLinkedPortals}</strong><span>startpoorten niet beschikbaar</span></article>
      <article className="publication-stat"><Send /><strong>{snapshot.stats.publicationStatus}</strong><span>publicatiestatus</span></article>
    </section>

    {snapshot.warnings.length > 0 && <section className="start-regie-warnings" aria-label="Waarschuwingen">
      <header><div><p className="kicker">Direct herstellen</p><h3>{snapshot.warnings.length} aandachtspunt(en)</h3></div><AlertTriangle /></header>
      <div>{snapshot.warnings.map((warning, index) => <button type="button" key={`${warning.code}-${warning.resourceId}-${index}`} onClick={() => {
        setTab(warning.action === "kaart" ? "map" : "planning");
        if (warning.resourceId && warning.action === "kaart") setMapSelection({ kind: "start", id: warning.resourceId });
      }}><span>{warning.message}</span><ChevronRight /></button>)}</div>
    </section>}

    {notice && <div className="form-notice start-regie-notice" role="status"><span>{notice}</span>{undoMove && <button className="text-link" type="button" onClick={() => void undoLastMove()}><Undo2 />Ongedaan maken</button>}</div>}

    <nav className="start-regie-tabs" role="tablist" aria-label="Startregie onderdelen">
      {([
        ["planning", CalendarClock, "Indeling"], ["points", MapPinned, "Startpunten"], ["map", MapIcon, "Kaart"], ["settings", Settings2, "Kaders"],
      ] as const).map(([value, Icon, label]) => <button key={value} type="button" role="tab" aria-selected={tab === value} className={tab === value ? "active" : ""} onClick={() => setTab(value)}><Icon />{label}</button>)}
    </nav>

    {tab === "planning" && <PlanningPanel snapshot={snapshot} activePoints={activePoints} times={times} visibleTimes={visibleTimes}
      visiblePoints={visiblePoints} visibleGroups={visibleGroups} filters={filters} setFilters={setFilters}
      filtersOpen={filtersOpen} setFiltersOpen={setFiltersOpen} busy={busy} proposal={proposal}
      scheduleIds={scheduleIds} publicationStep={publicationStep} calculate={calculate} saveProposal={saveProposal}
      publish={publish} moveGroup={moveGroup} maxGroupSize={maxGroupSize} />}

    {tab === "points" && <section className="start-regie-tab" role="tabpanel">
      <div className="start-points-heading"><div><p className="kicker">Veilige verzamelplekken</p><h3>Startpunten</h3><p>Een startpunt kan een zelfstandig hof of plein zijn, of gekoppeld zijn aan een bestaande poort.</p></div><button className="btn" type="button" onClick={() => setPointEditor({ ...emptyPoint })}><Plus />Startpunt toevoegen</button></div>
      <div className="start-point-list">{snapshot.startPoints.map((point) => <article className={`start-point-card${point.active ? "" : " is-archived"}`} key={point.id}>
        <header><span className={`start-point-symbol type-${point.pointType}`}>{point.pointType === "portal" ? "P" : "S"}</span><div><strong>{point.name}</strong><small>{point.publicLabel} · {point.pointType === "portal" ? "startpoort" : "zelfstandig verzamelpunt"}</small></div><span className={`route-ready ${point.verified ? "ready" : "warning"}`}>{point.verified ? <Check /> : <AlertTriangle />}{point.verified ? "Routeklaar" : "Marker controleren"}</span></header>
        <dl><div><dt>Beschikbaar</dt><dd>{point.availableFrom || point.availableUntil ? `${timeLabel(point.availableFrom)}–${timeLabel(point.availableUntil)}` : "Volledig startvenster"}</dd></div><div><dt>Capaciteit</dt><dd>{point.maxGroups} groepen · {point.maxChildren} kinderen</dd></div><div><dt>Aankomst</dt><dd>{point.publicArrivalInstructions || "Nog geen publieke instructie"}</dd></div><div><dt>Routing</dt><dd>{point.locationSource === "manual" ? `Handmatige marker${point.markerDistanceMeters ? ` · ${point.markerDistanceMeters} m van adres` : ""}` : "Vanaf officieel adres"}</dd></div></dl>
        <div className="actions"><button className="btn outline" type="button" onClick={() => setPointEditor(pointDraft(point))}><Settings2 />Bewerken</button><button className="btn outline" type="button" onClick={() => { setMapSelection({ kind: "start", id: point.id }); setTab("map"); }}><MapPin />Marker</button>{point.linkedPortalId && <button className="btn outline" type="button" onClick={onOpenPortals}>Gekoppelde poort</button>}{point.active && <button className="text-link danger" type="button" onClick={() => void archivePoint(point)}><Archive />Archiveren</button>}</div>
      </article>)}</div>
    </section>}

    {tab === "map" && <section className="start-regie-tab start-map-tab" role="tabpanel">
      <div className="start-map-heading"><div><p className="kicker">Privé beheerkaart</p><h3>Startpunten en poorten</h3><p>De overzichtskaart toont effectieve routingposities. Selecteer één locatie om de marker gecontroleerd te verplaatsen.</p></div><label className="field"><span>Locatie bewerken</span><select value={mapSelection ? `${mapSelection.kind}|${mapSelection.id}` : ""} onChange={(event) => { const [kind, id] = event.target.value.split("|"); setMapSelection(kind && id ? { kind: kind as "start" | "portal", id } : null); }}><option value="">Kies een locatie</option><optgroup label="Startpunten">{snapshot.startPoints.filter((point) => point.active).map((point) => <option key={point.id} value={`start|${point.id}`}>{point.publicLabel}</option>)}</optgroup><optgroup label="Poorten">{snapshot.portals.map((portal) => <option key={portal.id} value={`portal|${portal.id}`}>{portal.systemCode} · {portal.name}</option>)}</optgroup></select></label></div>
      <NightMap variant="admin" portals={mapItems} ariaLabel="Beheerkaart met alle startpunten en relevante poorten" />
      {!selectedMapResource && <div className="planning-empty"><MapPin /><p>Selecteer een startpunt of poort om de routingmarker te controleren.</p></div>}
      {selectedMapResource && mapSelection?.kind === "start" && "publicLabel" in selectedMapResource && <LocationEditor
        key={`start-${selectedMapResource.id}-${selectedMapResource.version}`} label={selectedMapResource.publicLabel}
        coordinate={coordinate(selectedMapResource.longitude, selectedMapResource.latitude)}
        addressCoordinate={coordinate(selectedMapResource.geocodedLongitude, selectedMapResource.geocodedLatitude)}
        markerKind="start" reason={selectedMapResource.markerReason} busy={busy}
        onSave={(change) => saveMarker("start", selectedMapResource, change)}
      />}
      {selectedMapResource && mapSelection?.kind === "portal" && "systemCode" in selectedMapResource && <LocationEditor
        key={`portal-${selectedMapResource.id}-${selectedMapResource.version}`} label={`${selectedMapResource.systemCode} · ${selectedMapResource.name}`}
        coordinate={coordinate(selectedMapResource.longitude, selectedMapResource.latitude)}
        addressCoordinate={coordinate(selectedMapResource.geocodedLongitude, selectedMapResource.geocodedLatitude)}
        markerKind={selectedMapResource.isFinal ? "final" : "portal"} color={selectedMapResource.color}
        reason={selectedMapResource.markerReason} busy={busy}
        onSave={(change) => saveMarker("portal", selectedMapResource, change)}
      />}
    </section>}

    {tab === "settings" && <SettingsPanel snapshot={snapshot} settingsDraft={settingsDraft} setSettingsDraft={setSettingsDraft} busy={busy} saveSettings={saveSettings} />}

    {pointEditor && <PointEditor draft={pointEditor} setDraft={setPointEditor} snapshot={snapshot} busy={busy} savePoint={savePoint} />}
  </div>;
}

type FilterState = { time: string; point: string; preference: string; status: string; warning: boolean };

function PlanningPanel({ snapshot, activePoints, times, visibleTimes, visiblePoints, visibleGroups, filters, setFilters,
  filtersOpen, setFiltersOpen, busy, proposal, scheduleIds, publicationStep, calculate, saveProposal, publish, moveGroup }:
  { snapshot: Snapshot; activePoints: StartPoint[]; times: string[]; visibleTimes: string[]; visiblePoints: StartPoint[];
    visibleGroups: Group[]; filters: FilterState; setFilters: (value: FilterState) => void; filtersOpen: boolean;
    setFiltersOpen: (value: boolean) => void; busy: boolean; proposal: ReturnType<typeof proposePlan> | null;
    scheduleIds: string[]; publicationStep: number; calculate: () => void; saveProposal: () => Promise<void>; publish: () => Promise<void>;
    moveGroup: (group: Group, target: MoveTarget) => Promise<void>; maxGroupSize: number }) {
  return <section className="start-regie-tab start-planning-tab" role="tabpanel">
    <div className="planning-toolbar">
      <div><p className="kicker">Conceptplanning</p><h3>Wie begint waar en wanneer?</h3><p>Tijdsloten staan onder elkaar; startpunten staan naast elkaar. Sleep een kaart of gebruik “Verplaats naar…”.</p></div>
      <div className="actions"><button type="button" className="btn outline" aria-expanded={filtersOpen} onClick={() => setFiltersOpen(!filtersOpen)}><Filter />Filters</button><button type="button" className="btn" disabled={busy || snapshot.unassigned.length === 0} onClick={() => void calculate()}><Sparkles />Maak planningsvoorstel</button></div>
    </div>
    {filtersOpen && <div className="planning-filters">
      <label className="field"><span>Tijd</span><select value={filters.time} onChange={(event) => setFilters({ ...filters, time: event.target.value })}><option value="">Alle tijden</option>{times.map((value) => <option key={value} value={value}>{timeLabel(value)}</option>)}</select></label>
      <label className="field"><span>Startpunt</span><select value={filters.point} onChange={(event) => setFilters({ ...filters, point: event.target.value })}><option value="">Alle startpunten</option>{activePoints.map((point) => <option key={point.id} value={point.id}>{point.publicLabel}</option>)}</select></label>
      <label className="field"><span>Voorkeur</span><select value={filters.preference} onChange={(event) => setFilters({ ...filters, preference: event.target.value })}><option value="">Alle voorkeuren</option>{Object.entries(matchLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      <label className="field"><span>Status</span><select value={filters.status} onChange={(event) => setFilters({ ...filters, status: event.target.value })}><option value="">Concept en gepubliceerd</option><option value="draft">Concept</option><option value="published">Gepubliceerd</option></select></label>
      <label className="check-row"><input type="checkbox" checked={filters.warning} onChange={(event) => setFilters({ ...filters, warning: event.target.checked })} /><span>Alleen met waarschuwing</span></label>
      <button type="button" className="text-link" onClick={() => setFilters({ time: "", point: "", preference: "", status: "", warning: false })}><X />Wis filters</button>
    </div>}

    <div className="planning-workspace">
      <aside className="unassigned-route-groups">
        <header><span><strong>Nog niet ingedeeld</strong><small>{snapshot.groups.filter((group) => !group.schedule).length} routegroepen</small></span><UsersRound /></header>
        <div>{snapshot.groups.filter((group) => !group.schedule).map((group) => <GroupCard key={group.id} group={group} points={activePoints} times={times} visitCycleSeconds={snapshot.settings.ordinaryVisitSeconds + snapshot.settings.bufferSeconds} compact onMove={(item, target) => void moveGroup(item, target)} />)}
          {snapshot.groups.every((group) => group.schedule) && <div className="planning-empty"><CheckCircle2 /><p>Alle bestaande routegroepen hebben een startafspraak.</p></div>}
        </div>
      </aside>
      <div className="planning-board-scroll" tabIndex={0} aria-label="Horizontaal en verticaal scrollbaar planningsbord">
        <div className="planning-board" style={{ gridTemplateColumns: `92px repeat(${Math.max(1, visiblePoints.length)}, minmax(280px, 1fr))` }}>
          <div className="planning-corner">Tijd</div>
          {visiblePoints.map((point) => <header className="planning-point-head" key={point.id}><span>{point.publicLabel}</span><small>{point.pointType === "portal" ? "Gekoppelde poort" : "Zelfstandig verzamelpunt"} · max. {point.maxChildren} kinderen</small>{!point.verified && <b><AlertTriangle />Marker controleren</b>}</header>)}
          {visibleTimes.flatMap((startsAt) => [
            <time className="planning-time" key={`time-${startsAt}`} dateTime={startsAt}>{timeLabel(startsAt)}</time>,
            ...visiblePoints.map((point) => {
              const groups = visibleGroups.filter((group) => {
                const location = groupLocation(group, snapshot.startPoints);
                return location?.point.id === point.id && Math.abs(Date.parse(location.slot.startsAt) - Date.parse(startsAt)) < 1000;
              });
              const children = groups.reduce((sum, group) => sum + group.childCount, 0);
              const full = groups.length >= point.maxGroups || children >= point.maxChildren;
              return <div className={`planning-cell${full ? " is-full" : ""}`} key={`${point.id}-${startsAt}`}
                onDragOver={(event) => { event.preventDefault(); event.dataTransfer.dropEffect = "move"; }}
                onDrop={(event) => { event.preventDefault(); const group = snapshot.groups.find((item) => item.id === event.dataTransfer.getData("text/group-id")); if (group) void moveGroup(group, { pointId: point.id, startsAt }); }}>
                <div className="planning-cell-load"><span>{groups.length}/{point.maxGroups} groepen</span><span>{children}/{point.maxChildren} kinderen</span></div>
                {groups.map((group) => <GroupCard key={group.id} group={group} points={activePoints} times={times} visitCycleSeconds={snapshot.settings.ordinaryVisitSeconds + snapshot.settings.bufferSeconds} compact onMove={(item, target) => void moveGroup(item, target)} />)}
                {!groups.length && <span className="planning-drop-hint">Sleep hierheen</span>}
              </div>;
            }),
          ])}
        </div>
      </div>
    </div>

    <section className="planning-proposal">
      <header><div><p className="kicker">Controleer vóór publicatie</p><h3>Voorstel en publicatie</h3></div><div className="publication-steps" aria-label={`Publicatiestap ${publicationStep + 1} van 5`}>{["Berekenen", "Conflicten", "Controleren", "Voorbeeld", "Publiceren"].map((label, index) => <span key={label} className={index <= publicationStep ? "active" : ""}><b>{index + 1}</b>{label}</span>)}</div></header>
      <div className="actions"><button className="btn" type="button" disabled={busy || snapshot.unassigned.length === 0} onClick={() => void calculate()}><Sparkles />Concept berekenen</button><button className="btn outline" type="button" disabled={busy || !proposal?.groups.length || Boolean(proposal?.conflicts.length)} onClick={() => void saveProposal()}><Save />Concept opslaan</button><button className="btn outline" type="button" disabled={busy || !scheduleIds.length} onClick={() => void publish()}><Send />{scheduleIds.length ? `${scheduleIds.length} wijziging(en) publiceren` : "Planning publiceren"}</button></div>
      {proposal?.conflicts.map((conflict) => <div className="form-warning" key={`${conflict.code}-${conflict.subjectId}`}><AlertTriangle /><span><strong>{conflict.code}</strong>{conflict.message}</span></div>)}
      {proposal?.groups.map((group: PlannedGroup) => <article className={`proposal-row match-${group.preferenceMatch}`} key={group.key}><span className="proposal-icon">{(() => { const Icon = matchIcons[group.preferenceMatch]; return <Icon />; })()}</span><div><strong>{group.key} · {group.childCount} kinderen</strong><p>{matchLabels[group.preferenceMatch]} · gewone poorten tot {timeLabel(group.effectiveStopAt)} · finale circa {timeLabel(group.expectedFinaleArrivalAt)}</p><small><b>Waarom hier?</b> {group.explanation}</small></div></article>)}
      {scheduleIds.length > 0 && <details className="publication-preview" open><summary><Eye />Voorbeeld van {scheduleIds.length} te publiceren wijziging(en)</summary><p>Alleen nieuwe conceptrevisies worden definitief. De bestaande bevestigingstemplate wordt uitsluitend voor werkelijk gewijzigde groepen klaargezet. In simulatie en staging worden echte deelnemers niet benaderd.</p></details>}
    </section>
  </section>;
}

function SettingsPanel({ snapshot, settingsDraft, setSettingsDraft, busy, saveSettings }: {
  snapshot: Snapshot; settingsDraft: RouteSettings; setSettingsDraft: (settings: RouteSettings) => void; busy: boolean; saveSettings: () => Promise<void>;
}) {
  return <section className="start-regie-tab start-settings-tab" role="tabpanel">
    <div><p className="kicker">Planningskaders</p><h3>Evenement, route en eindpoort</h3><p>Deze grenzen sturen het bord, de voorkeursbeoordeling en de servervalidatie. Technische routegegevens blijven verborgen.</p></div>
    <div className="settings-section-grid">
      <section><h4>Startvenster</h4><div className="settings-grid"><label className="field"><span>Eerste mogelijke start</span><input type="datetime-local" value={datetimeLocal(settingsDraft.firstStartAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, firstStartAt: iso(event.target.value) })} /></label><label className="field"><span>Interval</span><select value={settingsDraft.startIntervalMinutes} onChange={(event) => setSettingsDraft({ ...settingsDraft, startIntervalMinutes: Number(event.target.value) })}>{[5, 10, 15, 20, 30, 60].map((value) => <option key={value} value={value}>{value} minuten</option>)}</select></label><label className="field"><span>Vroeg geldt tot</span><input type="datetime-local" value={datetimeLocal(settingsDraft.earlyPreferenceLatestAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, earlyPreferenceLatestAt: iso(event.target.value) })} /></label><label className="field"><span>Later geldt vanaf</span><input type="datetime-local" value={datetimeLocal(settingsDraft.laterPreferenceEarliestAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, laterPreferenceEarliestAt: iso(event.target.value) })} /></label></div></section>
      <section><h4>Voorkeursbeoordeling</h4><div className="settings-grid"><label className="field"><span>Groen tot en met</span><input type="number" min={0} max={120} value={settingsDraft.preferenceGreenMinutes} onChange={(event) => setSettingsDraft({ ...settingsDraft, preferenceGreenMinutes: Number(event.target.value) })} /><small>minuten afwijking</small></label><label className="field"><span>Amber tot en met</span><input type="number" min={1} max={180} value={settingsDraft.preferenceAmberMinutes} onChange={(event) => setSettingsDraft({ ...settingsDraft, preferenceAmberMinutes: Number(event.target.value) })} /><small>daarboven wordt rood</small></label><label className="field"><span>Geen gewone poorten meer vanaf</span><input type="datetime-local" value={datetimeLocal(settingsDraft.globalOrdinaryStopAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, globalOrdinaryStopAt: iso(event.target.value) })} /></label><label className="field"><span>Plannerstand</span><select value={settingsDraft.plannerMode} onChange={(event) => setSettingsDraft({ ...settingsDraft, plannerMode: event.target.value as RouteSettings["plannerMode"] })}><option value="disabled">Uit</option><option value="shadow">Alleen voorstellen</option><option value="dynamic">Dynamisch plannen</option></select></label></div></section>
      <section><h4>Routebelasting</h4><div className="settings-grid"><label className="field"><span>Gemiddeld poortbezoek</span><input type="number" min={60} value={settingsDraft.ordinaryVisitSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, ordinaryVisitSeconds: Number(event.target.value) })} /><small>seconden</small></label><label className="field"><span>Veiligheidsbuffer</span><input type="number" min={0} value={settingsDraft.bufferSeconds} onChange={(event) => setSettingsDraft({ ...settingsDraft, bufferSeconds: Number(event.target.value) })} /><small>seconden per stap</small></label></div></section>
      <section><h4>Laatste poort</h4><div className="settings-grid"><label className="field"><span>Aangewezen laatste poort</span><select value={settingsDraft.finalPortalId ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finalPortalId: event.target.value || null })}><option value="">Kies een actieve poort</option>{snapshot.portals.filter((portal) => portal.lifecycleStatus === "active").map((portal) => <option key={portal.id} value={portal.id}>{portal.systemCode} · {portal.name}</option>)}</select></label><label className="check-row"><input type="checkbox" checked={settingsDraft.finaleAvailable} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleAvailable: event.target.checked })} /><span>Laatste poort veilig beschikbaar</span></label><label className="field"><span>Opening</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleOpensAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleOpensAt: iso(event.target.value) })} /></label><label className="field"><span>Laatste aankomst</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleLastArrivalAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleLastArrivalAt: iso(event.target.value) })} /></label><label className="field"><span>Sluiting</span><input type="datetime-local" value={datetimeLocal(settingsDraft.finaleClosesAt)} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleClosesAt: iso(event.target.value) })} /></label><label className="field"><span>Groepen tegelijk</span><input type="number" min={1} value={settingsDraft.finaleMaxGroups} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleMaxGroups: Number(event.target.value) })} /></label><label className="field"><span>Kinderen tegelijk</span><input type="number" min={1} value={settingsDraft.finaleMaxChildren} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleMaxChildren: Number(event.target.value) })} /></label></div></section>
      <section className="wide"><h4>Veiligheid en uitwijk</h4><div className="settings-grid"><label className="field"><span>Veilige aanloop</span><textarea value={settingsDraft.finaleSafeApproach ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleSafeApproach: event.target.value })} /></label><label className="field"><span>Wachtruimte</span><textarea value={settingsDraft.finaleWaitingArea ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleWaitingArea: event.target.value })} /></label><label className="field"><span>Afvoerroute</span><textarea value={settingsDraft.finaleExitRoute ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleExitRoute: event.target.value })} /></label><label className="field"><span>Toegankelijke ingang</span><textarea value={settingsDraft.finaleAccessibleEntrance ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, finaleAccessibleEntrance: event.target.value })} /></label><label className="field"><span>Alternatieve verzamelplek</span><input value={settingsDraft.emergencyDestinationName ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, emergencyDestinationName: event.target.value })} /></label><label className="field"><span>Noodinstructie</span><textarea value={settingsDraft.emergencyInstructions ?? ""} onChange={(event) => setSettingsDraft({ ...settingsDraft, emergencyInstructions: event.target.value })} /></label></div></section>
    </div>
    <div className="settings-save-bar"><span>Huidige versie {snapshot.settings.version} · wijzigingen worden op gelijktijdigheid gecontroleerd.</span><button className="btn" type="button" disabled={busy || settingsDraft.preferenceGreenMinutes >= settingsDraft.preferenceAmberMinutes} onClick={() => void saveSettings()}><Save />Kaders opslaan</button></div>
  </section>;
}

function PointEditor({ draft, setDraft, snapshot, busy, savePoint }: {
  draft: PointDraft; setDraft: (draft: PointDraft | null) => void; snapshot: Snapshot; busy: boolean; savePoint: () => Promise<void>;
}) {
  return <div className="start-point-editor-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDraft(null); }}><aside className="start-point-editor" role="dialog" aria-modal="true" aria-labelledby="start-point-editor-title">
    <header><div><p className="kicker">{draft.id ? "Startpunt bijwerken" : "Nieuw startpunt"}</p><h3 id="start-point-editor-title">{draft.name || "Veilige verzamelplek"}</h3></div><button type="button" className="icon-button" aria-label="Sluiten" onClick={() => setDraft(null)}><X /></button></header>
    <div className="start-point-editor-body">
      <section><h4>Herkenning</h4><div className="settings-grid"><label className="field"><span>Interne naam</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label className="field"><span>Publiek label</span><input value={draft.publicLabel} onChange={(event) => setDraft({ ...draft, publicLabel: event.target.value })} placeholder={draft.name || "Bijvoorbeeld Hof Zuid"} /></label><label className="field"><span>Soort startpunt</span><select value={draft.pointType} onChange={(event) => setDraft({ ...draft, pointType: event.target.value as PointDraft["pointType"], linkedPortalId: "" })}><option value="gathering">Zelfstandig verzamelpunt</option><option value="portal">Aan een poort gekoppeld</option></select></label>{draft.pointType === "portal" && <label className="field"><span>Gekoppelde poort</span><select value={draft.linkedPortalId} onChange={(event) => setDraft({ ...draft, linkedPortalId: event.target.value })}><option value="">Kies een goedgekeurde poort</option>{snapshot.portals.filter((portal) => ["approved", "active"].includes(portal.lifecycleStatus)).map((portal) => <option key={portal.id} value={portal.id}>{portal.systemCode} · {portal.name}</option>)}</select></label>}</div></section>
      <section><h4>Aankomst en locatie</h4><div className="settings-grid"><label className="field"><span>Officieel/contactadres <small>(optioneel)</small></span><input value={draft.privateAddress} onChange={(event) => setDraft({ ...draft, privateAddress: event.target.value })} placeholder="Mag leeg blijven voor een hofingang" /></label><label className="field"><span>Publieke aankomstinstructie</span><textarea value={draft.publicArrivalInstructions} onChange={(event) => setDraft({ ...draft, publicArrivalInstructions: event.target.value })} placeholder="Bijvoorbeeld: verzamel bij de zuidelijke ingang" /></label><label className="field"><span>Veilige aanloop</span><textarea value={draft.safeApproach} onChange={(event) => setDraft({ ...draft, safeApproach: event.target.value })} /></label></div>
        <LocationEditor label={draft.publicLabel || draft.name || "Nieuw startpunt"}
          coordinate={coordinate(draft.markerLongitude ? Number(draft.markerLongitude) : draft.geocodedLongitude ? Number(draft.geocodedLongitude) : null, draft.markerLatitude ? Number(draft.markerLatitude) : draft.geocodedLatitude ? Number(draft.geocodedLatitude) : null)}
          addressCoordinate={coordinate(draft.geocodedLongitude ? Number(draft.geocodedLongitude) : null, draft.geocodedLatitude ? Number(draft.geocodedLatitude) : null)}
          reason={draft.markerReason} busy={busy}
          onSave={(change) => { setDraft({ ...draft, markerLatitude: String(change.latitude), markerLongitude: String(change.longitude), markerReason: change.reason }); }} />
      </section>
      <section><h4>Beschikbaarheid en capaciteit</h4><div className="settings-grid"><label className="field"><span>Beschikbaar vanaf</span><input type="datetime-local" value={draft.availableFrom} onChange={(event) => setDraft({ ...draft, availableFrom: event.target.value })} /></label><label className="field"><span>Beschikbaar tot</span><input type="datetime-local" value={draft.availableUntil} onChange={(event) => setDraft({ ...draft, availableUntil: event.target.value })} /></label><label className="field"><span>Maximaal routegroepen</span><input type="number" min={1} value={draft.maxGroups} onChange={(event) => setDraft({ ...draft, maxGroups: event.target.value })} /></label><label className="field"><span>Maximaal kinderen</span><input type="number" min={1} value={draft.maxChildren} onChange={(event) => setDraft({ ...draft, maxChildren: event.target.value })} /></label></div></section>
      <section><h4>Toegankelijkheid en beheer</h4><div className="settings-grid"><label className="field"><span>Bereikbaarheid</span><select value={draft.accessible} onChange={(event) => setDraft({ ...draft, accessible: event.target.value as PointDraft["accessible"] })}><option value="">Nog beoordelen</option><option value="true">Toegankelijk</option><option value="false">Niet volledig toegankelijk</option></select></label><label className="field"><span>Toegankelijkheidsinformatie</span><textarea value={draft.accessibilityNotes} onChange={(event) => setDraft({ ...draft, accessibilityNotes: event.target.value })} /></label><label className="field"><span>Contactpersoon <small>(optioneel)</small></span><input value={draft.contactName} onChange={(event) => setDraft({ ...draft, contactName: event.target.value })} /></label><label className="field"><span>Telefoon <small>(optioneel)</small></span><input value={draft.contactPhone} onChange={(event) => setDraft({ ...draft, contactPhone: event.target.value })} /></label><label className="field wide"><span>Interne beheeropmerking</span><textarea value={draft.internalNotes} onChange={(event) => setDraft({ ...draft, internalNotes: event.target.value })} /></label><label className="check-row"><input type="checkbox" checked={draft.countsAsFirstPortalVisit} onChange={(event) => setDraft({ ...draft, countsAsFirstPortalVisit: event.target.checked })} /><span>Telt als eerste poortbezoek</span></label><label className="check-row"><input type="checkbox" checked={draft.active} onChange={(event) => setDraft({ ...draft, active: event.target.checked })} /><span>Actief beschikbaar voor planning</span></label></div></section>
      <details><summary>Technische locatiegegevens</summary><p>De wandelnode wordt na opslaan automatisch opnieuw gekozen. Deze waarden zijn alleen voor gecontroleerde correcties.</p><div className="settings-grid"><label className="field"><span>Adres-breedtegraad</span><input inputMode="decimal" value={draft.geocodedLatitude} onChange={(event) => setDraft({ ...draft, geocodedLatitude: event.target.value })} /></label><label className="field"><span>Adres-lengtegraad</span><input inputMode="decimal" value={draft.geocodedLongitude} onChange={(event) => setDraft({ ...draft, geocodedLongitude: event.target.value })} /></label></div></details>
    </div>
    <footer><button className="btn outline" type="button" onClick={() => setDraft(null)}>Annuleren</button><button className="btn" type="button" disabled={busy || draft.name.trim().length < 2 || (draft.pointType === "portal" && !draft.linkedPortalId) || (!draft.markerLatitude && !draft.geocodedLatitude)} onClick={() => void savePoint()}><Save />{draft.id ? "Wijzigingen opslaan" : "Startpunt toevoegen"}</button></footer>
  </aside></div>;
}
