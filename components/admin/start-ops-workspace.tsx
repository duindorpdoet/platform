"use client";

import { useEffect, useImperativeHandle, useRef, useState, type Ref } from "react";
import { Check, CheckCircle2, ChevronRight, Clock3, DoorOpen, Eye, LockKeyhole, MapPin, MapPinned, Plus, RefreshCw, Route, Send, Sparkles, UsersRound, X } from "lucide-react";
import { locationError, type StartPointReadiness } from "@/lib/domain/location-readiness";
import { createClient } from "@/lib/supabase/client";
import { NightMap } from "@/components/maps/night-map";
import { dominantEndPreference, dominantStartPreference } from "@/lib/domain/start-preference";
import { planningStartTimes } from "@/lib/domain/start-slots";
import type { ExistingPlanningSchedule } from "@/lib/domain/route-planner";
import { assignmentDraft, canonicalTimestamp, checkedRouteVisitLabel, reconcileAssignment, sameTimestamp, timestampChoices } from "@/lib/domain/start-assignment";
import { mergeReadiness, readinessFromError, type PublicationReadiness, type PublicationReason } from "@/lib/domain/start-publication-readiness";

type OpsGroup = { groupId: string; scheduleId: string | null; revision: number; state: string; startPointId: string | null; startPointName: string | null; startsAt: string | null; timePublishedAt: string | null; confirmedAt: string | null; appointmentProtected?: boolean; addressReleaseAt: string | null; publishedStartsAt?: string | null; publishedRevision?: number | null; publishedAddressReleaseAt?: string | null; addressReleased: boolean; routeRevision: number };
type RouteStop = { portalId: string; code: string; name: string; address: string; coordinate: [number, number] | null; world: string; kind: string; sequence: number; walkMeters: number; walkMinutes: number; plannedArrivalAt: string; visitSeconds?: number; bufferSeconds?: number; expectedCompletionAt?: string | null; physicalEndsAt?: string | null; status: string };
export type RoutePreview = { groupId: string; revision: number; generatedAt: string; start: { pointId: string; name: string; address: string; coordinate: [number, number] | null; startsAt: string }; stops: RouteStop[]; totalMeters: number; totalMinutes: number; eligiblePortalCount: number; warnings: string[]; provisional: boolean; hasConfirmedStart: boolean };
export type StartOpsSnapshot = { inputHash?:string; now: string; clockMode: string; routeRevision: number; groups: OpsGroup[]; routes: Record<string, RoutePreview>; walkingNodes: unknown[]; existingSchedules?: ExistingPlanningSchedule[] };
type Point = { confirmed: boolean; readiness: StartPointReadiness; id: string; publicLabel: string; name: string; active: boolean; verified: boolean; version: number; pointType: string; linkedPortalId: string | null; privateAddress: string | null; safeApproach: string | null; walkingDistanceMeters?: number; nearestNodeDistanceMeters?: number; walkingConnectionVerifiedAt?: string | null; maxGroups: number; maxChildren: number; slots: Array<{ id: string; startsAt: string; active: boolean }> };
type Group = { id: string; code: string; systemCode?: string; displayName?: string | null; version: number; childCount: number; status: string; registrations: Array<{ id: string; reference: string; preferredStartAt: string | null; desiredEndAt: string | null; paymentEligible: boolean }>; schedule: null | { id: string; revision: number; state: string; startSlotId: string } };
type Snapshot = { publicationReadiness?: PublicationReadiness; ops?: StartOpsSnapshot; groups: Group[]; startPoints: Point[]; settings: { firstStartAt?: string | null; globalOrdinaryStopAt?: string | null; allowedStartTimes: string[]; preferenceGreenMinutes: number; preferenceAmberMinutes: number; eventSettingsVersion?: number }; portals: Array<{ id: string; systemCode: string; name: string; approvalStatus: string; lifecycleStatus: string; version: number; isFinal: boolean }>; };
const time = (value?: string | null) => value ? new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "—";
const visitEnd = (stop?: RouteStop) => stop?.expectedCompletionAt ?? (stop?.plannedArrivalAt && typeof stop.visitSeconds === "number" ? new Date(new Date(stop.plannedArrivalAt).getTime() + stop.visitSeconds * 1000).toISOString() : null);
const distance = (meters: number) => meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1).replace(".", ",")} km`;
const errorCopy = (value: string) => {
  const location = locationError(value); if (location) return location;
  const errors: Record<string, string> = { DYNAMIC_PLANNER_NOT_READY: "De opgeslagen planningskaders zijn nog niet gereed. Vernieuw om de concrete oorzaak te controleren.", START_POINT_CAPACITY_EXCEEDED: "Dit startmoment is vol. Kies een andere tijd of plek.", FINALE_CAPACITY_EXCEEDED: "De finale heeft op dit moment onvoldoende ruimte. Pas de indeling aan.", START_POINT_NOT_VERIFIED: "Bevestig eerst de opgeslagen startlocatie. Controleer zo nodig de gekoppelde eerste poort.", START_POINT_MARKER_INVALID: "Dit startpunt heeft geen geldige opgeslagen positie. Controleer de marker.", STALE_VERSION: "De planning is intussen gewijzigd. De actuele versie is opnieuw opgehaald.", STALE_REVISION: "Deze conceptrevisie is intussen gewijzigd. Controleer de nieuwste indeling.", START_NOT_CONFIRMED: "Bevestig eerst het startpunt en de tijd van deze groep.", CONNECTION_TOO_FAR: "Controleer de opgeslagen marker van deze locatie.", SAFE_CONNECTION_REQUIRED: "Controleer en bevestig de opgeslagen locatie.", SAFE_WALKING_CONNECTION_REQUIRED: "De locatiegegevens van dit startpunt zijn nog niet compleet.", GROUP_ALREADY_STARTED: "Deze groep is al onderweg. Pas de actieve route alleen aan via de avondregie." };
  return Object.entries(errors).find(([code]) => value.includes(code))?.[1] ?? value;
};

export type PublicationReviewControl = { reviewSelected: () => void };
export function StartOpsWorkspace({ snapshot, eventSlug, busy, setBusy, onReload, onNotice, onMove, onOpenPoints, onReadinessAction, settingsDirty, selectedIds, onSelectedIds, publicationReviewRef }: {
  snapshot: Snapshot; eventSlug: string; busy: boolean; setBusy: (value: boolean) => void; onReload: () => Promise<void>; onNotice: (value: string) => void;
  onMove: (group: Group, target: { pointId: string; startsAt: string }) => Promise<void>; onOpenPoints: () => void;
  onReadinessAction: (reason: PublicationReason) => void; settingsDirty: boolean;
  selectedIds: string[]; onSelectedIds: (value: string[]) => void;
  publicationReviewRef?: Ref<PublicationReviewControl>;
}) {
  const [houseId, setHouseId] = useState("");
  const [routeId, setRouteId] = useState<string | null>(null);
  const [publication, setPublication] = useState<OpsGroup[] | null>(null);
  const [publicationKey, setPublicationKey] = useState("");
  const [dialogError,setDialogError]=useState("");
  const [publicationReadiness, setPublicationReadiness] = useState<PublicationReadiness | null>(null);
  const [checkingReadiness, setCheckingReadiness] = useState(false);
  const preflightSerial = useRef(0);
  const busyRef = useRef(busy);
  useEffect(() => { busyRef.current = busy; }, [busy]);
  const [mapMode, setMapMode] = useState(false);
  const ops = snapshot.ops;
  const groups = ops?.groups ?? [];
  const eligibleHouses = snapshot.portals.filter(portal => portal.approvalStatus === "approved" && portal.lifecycleStatus === "active" && !portal.isFinal && !snapshot.startPoints.some(point => point.active && point.linkedPortalId === portal.id));
  const selected = groups.filter(group => group.scheduleId && selectedIds.includes(group.scheduleId));
  const readyToPublish = selected.filter(group => group.scheduleId && (!group.timePublishedAt || group.state !== "published"));
  const route = routeId ? ops?.routes[routeId] : undefined;
  const routeGroup = snapshot.groups.find(group => group.id === routeId);
  const routeOps = groups.find(group => group.groupId === routeId);
  const routeFinale = route?.stops.find(stop => stop.kind === "finale");
  const routeOrdinaryEnd = visitEnd(route?.stops.filter(stop => stop.kind === "ordinary").at(-1));
  const routeDesiredEnd = routeGroup ? dominantEndPreference(routeGroup.registrations) : null;
  const routeCompletion = visitEnd(routeFinale);
  const routeEndDeviation = routeDesiredEnd && routeCompletion ? Math.round((new Date(routeCompletion).getTime() - new Date(routeDesiredEnd).getTime()) / 60000) : null;
  const dialogOpen=Boolean(publication||route);
  const publicationReasons = mergeReadiness(publicationReadiness ?? snapshot.publicationReadiness);
  useEffect(() => {
    if (!dialogOpen) return;
    const oldOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const previousFocus = document.activeElement as HTMLElement | null;
    const modal = document.querySelector<HTMLElement>(".start-ops-modal-backdrop");
    const focusables = () => Array.from(modal?.querySelectorAll<HTMLElement>('button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), [tabindex="0"]') ?? []);
    focusables()[0]?.focus();
    function key(event: KeyboardEvent) {
      if (event.key === "Escape" && !busyRef.current) { setPublication(null); setRouteId(null); }
      if (event.key !== "Tab") return;
      const items = focusables(), first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }
    document.addEventListener("keydown", key);
    return () => { document.body.style.overflow = oldOverflow; document.removeEventListener("keydown", key); previousFocus?.focus(); };
  }, [dialogOpen]);

  async function command(name: string, args: Record<string, unknown>, success: string) {
    const client = createClient(); if (!client) return;
    setBusy(true);
    try {
      const { error } = await client.schema("api").rpc(name, { _event_slug: eventSlug, ...args });
      if (error) { const readiness = readinessFromError(error.details); if (readiness) setPublicationReadiness(readiness); const message = readiness?.reasons.map(reason => reason.message).join(" ") || errorCopy(error.message); if(publication)setDialogError(message); onNotice(message); if (/STALE_/.test(error.message) || readiness) await onReload(); return false; }
      onNotice(success); await onReload(); return true;
    } catch (error) { if(publication)setDialogError("De publicatie kon niet worden uitgevoerd. Controleer de verbinding en probeer opnieuw; dezelfde opdracht wordt veilig herhaald."); onNotice(error instanceof Error ? errorCopy(error.message) : "Deze wijziging is niet opgeslagen. Probeer opnieuw."); return false; }
    finally { setBusy(false); }
  }
  async function checkPublication(selection: OpsGroup[]) {
    const serial = ++preflightSerial.current;
    const client = createClient();
    if (!client) { setDialogError("De opgeslagen kaders konden niet worden gecontroleerd. Vernieuw en probeer opnieuw."); return false; }
    setCheckingReadiness(true);
    try {
      const { data, error } = await client.schema("api").rpc("admin_startregie_publication_readiness", {
        _event_slug: eventSlug, _expected_revisions: selection.map(group => ({ id: group.scheduleId, revision: group.revision })),
        _expected_settings_version: snapshot.settings.eventSettingsVersion,
      }).abortSignal(AbortSignal.timeout(20_000));
      if (serial !== preflightSerial.current) return false;
      if (error || !data) { setDialogError("De opgeslagen kaders en revisies konden niet worden gecontroleerd. Vernieuw en probeer opnieuw."); return false; }
      const readiness = data as PublicationReadiness;
      setPublicationReadiness(readiness);
      return readiness.ready;
    } catch { if (serial === preflightSerial.current) setDialogError("De controle is niet bevestigd. Controleer de verbinding en probeer opnieuw."); return false; }
    finally { if (serial === preflightSerial.current) setCheckingReadiness(false); }
  }
  function openPublication(selection: OpsGroup[]) {
    setDialogError(""); setPublicationReadiness(null); setPublicationKey(crypto.randomUUID()); setPublication(selection);
    void checkPublication(selection);
  }
  useImperativeHandle(publicationReviewRef, () => ({ reviewSelected: () => { if (readyToPublish.length) openPublication(readyToPublish); } }));
  async function publishTimes() {
    if (!publication?.length) return;
    const current = publication.map(group => groups.find(item => item.scheduleId === group.scheduleId && item.revision === group.revision));
    if (current.some(group => !group)) { setPublication(null); onNotice("De indeling is gewijzigd. Controleer en selecteer de nieuwe revisie."); return; }
    if (settingsDirty || !await checkPublication(publication)) return;
    const saved = await command("admin_startregie_confirm_and_send", { _expected_revisions: publication.map(group => ({ id: group.scheduleId, revision: group.revision })), _expected_settings_version: snapshot.settings.eventSettingsVersion, _idempotency_key: publicationKey }, `${publication.length} starttijd(en) gepubliceerd. Het eerste adres blijft verborgen tot één uur voor de eigen start.`);
    if (saved) { setPublication(null); onSelectedIds([]); }
  }

  return <div className="start-ops-workspace">
    <section className="start-ops-intro">
      <div><div className="start-ops-hero-bar"><p className="kicker">Startregie</p><button type="button" disabled={busy} onClick={() => void onReload()}><RefreshCw size={13} />Vernieuwen</button></div><h1>Iedere groep een goede start.</h1><p>Kies de plek, bevestig de indeling en geef de starttijd alvast door. Het eerste adres verschijnt vanzelf één uur voor vertrek.</p><span className="start-ops-zone"><Clock3 size={13} /> Alle tijden in Nederland · Europe/Amsterdam</span></div>
      <div className="start-ops-release-rule"><LockKeyhole /><strong>Tijd vooraf.{" "}<br />Adres één uur voor vertrek.</strong><small>Alleen de organisatie ziet de route vooraf.</small></div>
    </section>
    <div className="start-ops-steps" aria-label="Zo werkt startregie">
      <button type="button" onClick={onOpenPoints}><b>1</b><span>Startpunten kiezen<small>{snapshot.startPoints.filter(point => point.active && point.verified).length} beschikbaar</small></span><ChevronRight /></button>
      <div><b>2</b><span>Groepen indelen<small>Een plek en tijd per groep</small></span></div>
      <div><b>3</b><span>Poortvolgorde controleren<small>Vooraf zichtbaar voor beheer</small></span></div>
      <div><b>4</b><span>Starttijd publiceren<small>Adres volgt automatisch</small></span></div>
    </div>

    <details className="start-ops-point-shortcuts">
      <summary><MapPinned /> Startpunten snel regelen <span>{snapshot.startPoints.filter(point => point.active).length} actief</span></summary>
      <div className="start-ops-point-tools">
        <div><h4>Begin bij een bestaand huis</h4><p>Neem de locatie en gegevens van een goedgekeurde poort over.</p><label><span>Goedgekeurd huis</span><select value={houseId} onChange={event => setHouseId(event.target.value)}><option value="">Kies een poort</option>{eligibleHouses.map(portal => <option key={portal.id} value={portal.id}>{portal.systemCode} · {portal.name}</option>)}</select></label><button type="button" className="btn outline" disabled={busy || !houseId} onClick={async () => { if (await command("admin_portal_start_point_set", { _portal_id: houseId, _enabled: true, _expected_version: snapshot.portals.find(portal => portal.id === houseId)?.version }, "Startpunt: ja. De poort is beschikbaar in Startregie.")) setHouseId(""); }}><Plus />Gebruik als startpunt</button></div>
        <div><h4>Liever een plein of hof?</h4><p>Voeg een herkenbare verzamelplek toe en bevestig het startpunt.</p><button type="button" className="btn outline" onClick={onOpenPoints}><MapPin />Startpunten beheren</button></div>
      </div>
      <div className="start-ops-point-checks">{snapshot.startPoints.filter(point=>point.active).map(point=><article key={point.id}><div><strong>{point.publicLabel||point.name}</strong><p><CheckCircle2/>{point.confirmed ? "Startpunt: ja · Startpunt bevestigd" : "Startpunt: ja"}</p><small>{point.readiness.location.valid ? "Positie opgeslagen" : "Geen geldige positie"} · {point.confirmed ? "Locatie bevestigd" : "Locatie nog bevestigen"}</small></div><button className="btn outline" type="button" disabled={busy} onClick={()=>void command("admin_startregie_confirm_point",{_point_id:point.id,_expected_version:point.version},"Startpunt bevestigd.")}><Check/>Startpunt bevestigen</button></article>)}</div>
    </details>

    <section className="start-ops-groups" aria-label="Eenvoudig groepen indelen">
      <header><div><p className="kicker">Jullie vertrekafspraken</p><h3>Groepen, startpunten en tijden</h3><p>Een wijziging wordt eerst een concept. Je controleert en bevestigt iedere indeling voordat de starttijd zichtbaar wordt.</p></div><span className="start-ops-count"><UsersRound />{snapshot.groups.length} groepen</span></header>
      <div className="start-ops-bulk"><label><input type="checkbox" aria-label="Selecteer alle conceptstartafspraken" checked={groups.filter(group => group.scheduleId && group.state !== "published").length > 0 && groups.filter(group => group.scheduleId && group.state !== "published").every(group => selectedIds.includes(group.scheduleId!))} onChange={event => onSelectedIds(event.target.checked ? groups.filter(group => group.scheduleId && group.state !== "published").map(group => group.scheduleId!) : [])} /><span>{selected.length ? `${selected.length} geselecteerd` : "Selecteer conceptstartafspraken"}</span></label><button type="button" className="btn" disabled={busy || !readyToPublish.length} onClick={() => openPublication(readyToPublish)}><Send />{readyToPublish.length ? "Startafspraken bevestigen en versturen" : "Startafspraken bevestigen en versturen"}</button></div>
      <div className="start-ops-group-list">{snapshot.groups.map(group => {
        const operation = groups.find(item => item.groupId === group.id);
        return <AssignmentCard key={group.id} group={group} operation={operation} points={snapshot.startPoints} times={planningStartTimes(snapshot.settings)} busy={busy} selected={!!group.schedule && selectedIds.includes(group.schedule.id)} onSelect={checked => { if (group.schedule) onSelectedIds(checked ? [...new Set([...selectedIds, group.schedule.id])] : selectedIds.filter(id => id !== group.schedule!.id)); }} onMove={onMove} onConfirm={() => { if (operation) openPublication([operation]); }} onRoute={() => { setRouteId(group.id); setMapMode(false); }} greenMinutes={snapshot.settings.preferenceGreenMinutes} amberMinutes={snapshot.settings.preferenceAmberMinutes} />;
      })}</div>
    </section>
    <div className="start-ops-auto"><Sparkles /><div><strong>Nieuwe huizen schuiven vanzelf aan.</strong><p>Goedgekeurde, gecontroleerde en beschikbare poorten worden automatisch in de nog te lopen route opgenomen. De actuele bestemming en eerder bezochte poorten blijven behouden. De routecontrole is een verwachte route, geen garantie op exact dezelfde volgorde tijdens de avond.</p></div></div>


    {publication && <div className="start-ops-modal-backdrop"><section className="start-ops-publish-dialog" role="dialog" aria-modal="true" aria-labelledby="publish-times-title"><header><Send /><button className="icon-button" aria-label="Publicatievenster sluiten" type="button" disabled={busy} onClick={() => { if (!busy) setPublication(null); }}><X /></button></header><p className="kicker">Nog één keer controleren</p><h3 id="publish-times-title">Deze starttijden doorgeven?</h3><p>Deelnemers krijgen hun eigen definitieve starttijd te zien. Het startadres en de eerste bestemming blijven tot één uur voor die start verborgen.</p><ul>{publication.map(operation => <li key={operation.groupId}><strong>{snapshot.groups.find(group => group.id === operation.groupId)?.systemCode}</strong><span>{operation.startPointName} · {time(operation.startsAt)} uur</span><small>Adres vanaf {time(operation.addressReleaseAt)}</small></li>)}</ul><div className="start-ops-publish-note"><LockKeyhole /><span>Nu zichtbaar: starttijd.<br />Later zichtbaar: alleen het eerste adres, vanaf het juiste moment.</span></div>{checkingReadiness && <p role="status">Opgeslagen kaders, capaciteit en conceptrevisies controleren…</p>}{settingsDirty && <p className="form-warning" role="alert">Er zijn niet-opgeslagen Kaders. Sla deze eerst op en controleer daarna de serverwaarden.<button className="text-link" type="button" onClick={() => { setPublication(null); onReadinessAction({ code: "UNSAVED_SETTINGS", message: "", action: "settings" }); }}>Open Kaders</button></p>}{publicationReasons.length > 0 && <div className="form-warning" role="alert"><strong>Nog nodig voor deze opgeslagen startafspraken</strong>{publicationReasons.map(reason => <p key={reason.code}>{reason.message} <button type="button" className="text-link" onClick={() => { setPublication(null); onReadinessAction(reason); }}>{reason.action === "settings" ? "Open Kaders" : reason.action === "portals" ? "Controleer laatste poort" : reason.action === "points" ? "Open startpunten" : "Controleer indeling"}</button></p>)}</div>}{dialogError&&<p className="form-warning" role="alert">{dialogError} <button type="button" className="text-link" disabled={checkingReadiness} onClick={() => { setDialogError(""); void checkPublication(publication); }}>Opnieuw controleren</button></p>}<footer><button type="button" className="btn outline" disabled={busy} onClick={() => { if (!busy) setPublication(null); }}>Terug</button><button type="button" className="btn" disabled={busy || checkingReadiness || settingsDirty || !publicationReadiness?.ready || publicationReasons.length > 0} onClick={() => void publishTimes()}><Check />Startafspraken bevestigen en versturen</button></footer></section></div>}
    {route && routeGroup && <div className="start-ops-modal-backdrop"><section className="start-ops-route-dialog" role="dialog" aria-modal="true" aria-labelledby="route-preview-title"><header><div><p className="kicker">Privé poortvolgorde · {routeGroup.systemCode || routeGroup.code}</p><h3 id="route-preview-title">{routeGroup.displayName || "Route van de groep"}</h3><p>Opgeslagen poortvolgorde vanaf de vaste verzamelplek. Deelnemers zien deze route niet. Een nieuw gezamenlijk voorstel bereken en beoordeel je in Avondregie.</p></div><button type="button" className="icon-button" aria-label="Routecontrole sluiten" onClick={() => setRouteId(null)}><X /></button></header><div className="start-ops-route-facts"><span><MapPin />{route.start.name}</span><span><Clock3 />{time(route.start.startsAt)}</span><span><DoorOpen />{checkedRouteVisitLabel(route, ops?.routeRevision, { groupId: routeGroup.id, pointId: route.start.pointId, startsAt: route.start.startsAt })}</span><span><Route />{distance(route.totalMeters)} hemelsbreed</span><span>circa {Math.ceil(route.totalMinutes)} min bezoeken en lopen</span><span>Gewenst klaar {time(routeDesiredEnd)}</span><span>Verwacht klaar {time(routeCompletion)}{routeEndDeviation !== null ? routeEndDeviation === 0 ? " · op streeftijd" : routeEndDeviation > 0 ? ` · ${routeEndDeviation} minuten uitloop` : ` · ${Math.abs(routeEndDeviation)} minuten eerder` : ""}</span><span>Gewone bezoeken klaar {time(routeOrdinaryEnd)}</span><span>Finale-aankomst {time(routeFinale?.plannedArrivalAt)}</span></div><div className="start-ops-route-layout"><div className="start-ops-route-map"><div className="start-ops-map-switch"><button type="button" className={!mapMode ? "active" : ""} onClick={() => setMapMode(false)}>Routeoverzicht</button><button type="button" className={mapMode ? "active" : ""} onClick={() => setMapMode(true)}>Wijkkaart</button></div>{mapMode ? <NightMap variant="admin" routeAnimated={false} route={[route.start.coordinate, ...route.stops.map(stop => stop.coordinate)].filter((item): item is [number, number] => !!item)} portals={route.stops.map(stop => ({ id: stop.portalId, code: String(stop.sequence), name: stop.name, world: stop.world, address: stop.address, coordinate: stop.coordinate, status: "scheduled" as const, isFinal: stop.kind === "finale" }))} ariaLabel={`Verwachte route voor ${routeGroup.systemCode}`} /> : <RouteSketch route={route} />}<p>De lijnen verbinden de locaties in verwachte volgorde. Afstanden zijn hemelsbreed en reistijden zijn schattingen, geen wandelinstructies. Gewijzigde beschikbaarheid vraagt om een nieuw beoordeeld voorstel. Opnieuw laden berekent geen andere poortvolgorde.</p></div><ol className="start-ops-route-stops"><li className="is-start"><b>S</b><div><strong>{route.start.name}</strong><span>{route.start.address}</span><small>Vertrek {time(route.start.startsAt)}</small></div></li>{route.stops.map(stop => <li key={`${stop.portalId}-${stop.sequence}`} className={stop.kind === "finale" ? "is-finale" : ""}><b>{stop.sequence}</b><div><strong>{stop.name}</strong><span>{stop.code} · {stop.address}</span><small>{stop.world} · circa {stop.walkMinutes} min geschat / {distance(stop.walkMeters)} hemelsbreed vanaf vorige plek{stop.status === "visited" ? " · al bezocht" : stop.status === "current" ? " · huidige bestemming" : ""}</small><small>Aankomst {time(stop.plannedArrivalAt)}{visitEnd(stop) ? ` · ${stop.kind === "finale" ? "show" : "bezoek"} klaar ${time(visitEnd(stop))}` : ""}{stop.physicalEndsAt ? ` · poort bezet tot ${time(stop.physicalEndsAt)}` : ""}</small></div>{stop.kind === "finale" && <Sparkles size={16} />}</li>)}</ol></div>{route.warnings.length > 0 && <div className="form-warning">{route.warnings.map(warning => <p key={warning}>{warning.replaceAll("_", " ")}</p>)}</div>}<footer><small>Revisie {route.revision} · {route.eligiblePortalCount} beschikbare poorten · {routeOps?.addressReleased ? "Eerste adres vrijgegeven" : `Eerste adres van actuele afspraak vanaf ${time(routeOps?.publishedAddressReleaseAt ?? routeOps?.addressReleaseAt)}`}</small><button className="btn outline" type="button" onClick={() => void onReload()}><RefreshCw />Opnieuw laden</button></footer></section></div>}
  </div>;
}

function AssignmentCard({ group, operation, points, times, busy, selected, onSelect, onMove, onConfirm, onRoute, greenMinutes, amberMinutes }: {
  group: Group; operation?: OpsGroup; points: Point[]; times: string[]; busy: boolean; selected: boolean; onSelect: (checked: boolean) => void; onMove: (group: Group, target: { pointId: string; startsAt: string }) => Promise<void>; onConfirm: () => void; onRoute: () => void; greenMinutes: number; amberMinutes: number;
}) {
  const saved = { pointId: operation?.startPointId ?? "", startsAt: operation?.startsAt ?? "", revision: operation?.revision ?? 0 };
  const [draft, setDraft] = useState(() => assignmentDraft(saved));
  const reconciled = reconcileAssignment(draft, saved);
  if (reconciled !== draft) setDraft(reconciled);
  const { pointId, startsAt } = reconciled;
  const choices = timestampChoices([startsAt, operation?.startsAt, ...times]);
  const outsideChoices = !!startsAt && !times.some(value => sameTimestamp(value, startsAt));
  const changed = !group.schedule || pointId !== operation?.startPointId || !sameTimestamp(startsAt, operation?.startsAt);
  const deviations = group.registrations.filter(registration => registration.preferredStartAt).map(registration => ({ ...registration, minutes: startsAt ? Math.round(Math.abs(Date.parse(startsAt) - Date.parse(registration.preferredStartAt!)) / 60_000) : null }));
  const worst = deviations.length && startsAt ? Math.max(...deviations.map(item => item.minutes ?? 0)) : null;
  const match = worst === null ? "neutral" : worst <= greenMinutes ? "good" : worst <= amberMinutes ? "small_deviation" : "large_deviation";
  const confirmed = !!operation?.confirmedAt;
  const paid = group.registrations.every(registration => registration.paymentEligible);
  const started = ["live", "active", "paused", "stopped", "completed"].includes(group.status);
  const pendingChange = !!operation?.timePublishedAt && operation.state !== "published";
  const actualReleaseAt = operation?.timePublishedAt ? operation.publishedAddressReleaseAt ?? operation.addressReleaseAt : operation?.addressReleaseAt;
  return <article className="start-ops-assignment">
    <div className="start-ops-group-identity"><label className="start-ops-select"><input type="checkbox" aria-label={`Selecteer starttijd van ${group.systemCode || group.code}`} disabled={!group.schedule} checked={selected} onChange={event => onSelect(event.target.checked)} /><strong>{group.systemCode || group.code}</strong></label><h4>{group.displayName || "Naam wordt nog gekozen"}</h4><span><UsersRound size={13} />{group.childCount} kinderen · {group.registrations.length} gezin(nen)</span><span className={`start-ops-status ${pendingChange ? "draft" : operation?.timePublishedAt ? "published" : confirmed ? "confirmed" : "draft"}`}>{pendingChange ? <><Clock3 size={12} />{confirmed ? "Nieuwe indeling bevestigd" : "Nieuw concept"}</> : operation?.timePublishedAt ? <><Send size={12} />Starttijd gepubliceerd</> : confirmed ? <><CheckCircle2 size={12} />Start bevestigd</> : <><Clock3 size={12} />Conceptindeling</>}</span></div>
    <div className="start-ops-assignment-controls"><label><span>Startpunt</span><select aria-label={`Startpunt voor ${group.systemCode || group.code}`} value={pointId} disabled={busy || ["live", "active", "paused", "stopped", "completed"].includes(group.status)} onChange={event => setDraft({ ...reconciled, pointId: event.target.value })}><option value="">Kies een veilige startplek</option>{points.filter(point => point.active || point.id === pointId).map(point => <option key={point.id} value={point.id} disabled={!point.verified || !point.active}>{point.publicLabel || point.name}{!point.active ? " · niet actief" : !point.verified ? " · locatie nog niet compleet" : ""}</option>)}</select></label><label><span>Starttijd</span><select aria-label={`Starttijd voor ${group.systemCode || group.code}`} value={startsAt} disabled={busy || ["live", "active", "paused", "stopped", "completed"].includes(group.status)} onChange={event => setDraft({ ...reconciled, startsAt: canonicalTimestamp(event.target.value) })}><option value="">Kies een tijd</option>{choices.map(value => <option value={value} key={value}>{time(value)} uur</option>)}</select></label><button type="button" className="btn outline" disabled={busy || started || reconciled.sourceChanged || !pointId || !startsAt || !changed} onClick={() => void onMove(group, { pointId, startsAt })}>Concept opslaan</button></div>
    {outsideChoices && <p className="start-ops-pending-change">Deze opgeslagen of gekozen tijd staat buiten de huidige standaardopties. De werkelijk opgeslagen afspraak blijft leidend.</p>}
    {reconciled.sourceChanged && <p className="form-warning">De opgeslagen afspraak is tijdens je invoer gewijzigd. Je niet-opgeslagen keuze is behouden. Opgeslagen: {points.find(point => point.id === reconciled.saved.pointId)?.publicLabel || "startpunt ontbreekt"} om {time(reconciled.saved.startsAt)}. <button className="text-link" type="button" onClick={() => setDraft({ ...reconciled, sourceChanged: false })}>Mijn keuze opnieuw beoordelen</button> <button className="text-link" type="button" onClick={() => setDraft(assignmentDraft(saved))}>Opgeslagen afspraak tonen</button></p>}
    {started && <p className="start-ops-started">Deze groep is al onderweg of afgerond. De vertrekafspraak is hier vergrendeld.</p>}{pendingChange && <p className="start-ops-pending-change">De eerder gepubliceerde start{operation?.publishedStartsAt ? ` om ${time(operation.publishedStartsAt)}` : ""} blijft geldig tot je deze nieuwe indeling bevestigt en verstuurt.</p>}
    <div className={`start-ops-preference match-${match}`}><p>Dominante startvoorkeur {time(dominantStartPreference(group.registrations))} · gewenst einde {time(dominantEndPreference(group.registrations))}</p><span>{worst === null ? "Geen vaste tijdvoorkeur" : worst === 0 ? "Alle gezinnen starten op hun voorkeur" : `Grootste afwijking: ${worst} minuten`}</span>{deviations.length > 0 && <details><summary>Voorkeur per gezin</summary>{deviations.map(item => <p key={item.id}><strong>{item.reference}</strong><span>{time(item.preferredStartAt)} gewenst · {item.minutes ?? "—"} min verschil</span></p>)}</details>}</div>
    <div className="start-ops-card-foot"><div>{operation?.timePublishedAt ? <><LockKeyhole size={14} /><span>{operation.addressReleased ? "Eerste adres is zichtbaar" : `Eerste adres vanaf ${time(actualReleaseAt)}`}</span></> : <><LockKeyhole size={14} /><span>Starttijd en adres nog niet gedeeld</span></>}</div><div>{!confirmed && <button type="button" className="btn" disabled={busy || started || !group.schedule || changed || group.childCount < 1} onClick={onConfirm}><Check />Startafspraken bevestigen en versturen</button>}<button type="button" className="btn outline" disabled={!confirmed} onClick={onRoute}><Eye />Poortvolgorde controleren</button></div></div>{!paid && <p className="start-ops-blocker">Betaling open of in controle. Deelname en startbevestiging blijven mogelijk.</p>}
  </article>;
}

function RouteSketch({ route }: { route: RoutePreview }) {
  const nodes = [{ name: route.start.name, coordinate: route.start.coordinate, label: "S" }, ...route.stops.map(stop => ({ name: stop.name, coordinate: stop.coordinate, label: String(stop.sequence) }))].filter((item): item is { name: string; coordinate: [number, number]; label: string } => !!item.coordinate);
  const xs = nodes.map(node => node.coordinate[0]), ys = nodes.map(node => node.coordinate[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const projected = nodes.map(node => ({ ...node, x: 70 + (node.coordinate[0] - minX) / Math.max(.0004, maxX - minX) * 490, y: 310 - (node.coordinate[1] - minY) / Math.max(.0004, maxY - minY) * 245 }));
  return <div className="start-ops-sketch"><span><MapPinned size={13} />Schematisch routeoverzicht</span>{nodes.length > 0 ? <svg viewBox="0 0 640 380" role="img" aria-label="Locaties van de verwachte route in volgorde"><defs><pattern id="ops-grid" width="36" height="36" patternUnits="userSpaceOnUse"><path d="M 36 0 L 0 0 0 36" fill="none" stroke="#344258" strokeWidth=".5" /></pattern><marker id="ops-arrow" markerWidth="7" markerHeight="7" refX="5" refY="3.5" orient="auto"><path d="M0,0 L7,3.5 L0,7" fill="#dca66e" /></marker></defs><rect width="640" height="380" fill="url(#ops-grid)" />{projected.slice(1).map((node, index) => <line key={`line-${index}`} x1={projected[index].x} y1={projected[index].y} x2={node.x} y2={node.y} stroke="#dca66e" strokeWidth="2.4" strokeDasharray="7 7" opacity=".7" markerEnd="url(#ops-arrow)" />)}{projected.map((node, index) => <g key={`${node.label}-${index}`}><circle cx={node.x} cy={node.y} r="19" fill={index === 0 ? "#d7ac79" : "#142238"} stroke="#efbc7c" strokeWidth="1.5" /><text x={node.x} y={node.y + 5} textAnchor="middle" fill={index === 0 ? "#172031" : "#f1c58f"} fontSize="14" fontWeight="700">{node.label}</text><title>{node.label}: {node.name}</title></g>)}<text x="598" y="28" fill="#8e9db2" fontSize="12">N ↑</text></svg> : <div className="planning-empty"><MapPin /><p>Voor deze route ontbreken nog gecontroleerde coördinaten.</p></div>}</div>;
}
