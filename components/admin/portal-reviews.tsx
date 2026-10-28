"use client";

import Link from "next/link";
import { PortalRegistrationActions } from "./portal-registration-actions";
import { AdminDialog } from "./admin-dialog";
import { LivePlanboard } from "./live-planboard";
import { PoortkamerOverview } from "./poortkamer-overview";
import { ManualPortalManager } from "./manual-portal-manager";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  CheckCircle2, ChevronDown, Clock3, FileSearch, Home, Mail, MapPinCheck,
  MessageCircle, Phone, Plus, Radio, RefreshCw, RotateCcw, ShieldCheck, UserRound, XCircle,
} from "lucide-react";
import {
  countPortalRegistrationProgress,
  formatPortalAddress,
  portalRegistrationStatusLabels,
  type PortalRegistrationProgress,
  type PortalRegistrationStatus,
} from "@/lib/domain/admin-portals";
import { parseLatitudeLongitude } from "@/lib/maps/coordinates";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { createClient } from "@/lib/supabase/client";

type World = { id: string; slug: string; name: string };
type Address = { street?: string; houseNumber?: string; addition?: string; postalCode?: string; city?: string };
type TimelineEntry = { label: string; at: string };
type PortalRegistration = {
  id: string; intakeId: string | null; applicationId: string | null; portalId: string | null; code: string;
  status: PortalRegistrationStatus;
  portalArchived?: boolean; intakeWithdrawn?: boolean;
  applicationStatus: "draft" | "submitted" | "changes_requested" | "approved" | "rejected" | "withdrawn" | null;
  applicationVersion: number | null; email: string | null; contactName: string | null; phone: string | null;
  address: Address; requestedWorldSlug: string | null; reviewFeedback: string | null; lastActivityAt: string;
  progress: PortalRegistrationProgress; timeline: TimelineEntry[];
  draft: {
    portalName?: string; description?: string; intensity?: string; entrance?: string; accessibility?: string;
    availableFrom?: string; availableUntil?: string; assetPaths?: string[];
  };
  portal: null | { id: string; version: number; name: string; locationVerified: boolean; latitude: number | null; longitude: number | null };
};

type ActivePortal = {
  portalId: string; applicationId: string; systemCode: string; name: string; world: string; worldSlug: string;
  operationStatus: "scheduled" | "open" | "paused" | "closed"; version: number; isFinal: boolean;
  contactName: string | null; phone: string | null; email: string | null; formattedAddress: string | null;
  locationVerified: boolean; coordinate: [number, number] | null; activeReservations: number; expectedChildren: number;
};

type Snapshot = { canSubmitApplications?: boolean; conceptPortals?: Array<{id:string}>; realtimeTopic: string | null; worlds: World[]; registrations: PortalRegistration[]; activePortals: ActivePortal[] };

const reviewLabels = { approved: "Goedgekeurd", changes_requested: "Aanpassing gevraagd", rejected: "Afgewezen" } as const;
const operationLabels: Record<ActivePortal["operationStatus"], string> = {
  scheduled: "Voorbereiding", open: "Open", paused: "Pauze", closed: "Gestopt",
};

function formatDate(value: string | null | undefined) {
  if (!value) return "Nog geen activiteit";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Onbekend";
  return new Intl.DateTimeFormat("nl-NL", { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function displayValue(value: unknown) {
  return value === null || value === undefined || value === "" ? "Niet ingevuld" : String(value);
}

function emailHref(registration: PortalRegistration, requestData = false) {
  if (!registration.email) return undefined;
  const subject = requestData ? `Aanvulling gevraagd voor poortaanmelding ${registration.code}` : `Bericht over poortaanmelding ${registration.code}`;
  const body = requestData
    ? `Beste ${registration.contactName || "bewoner"},\n\nVoor jullie poortaanmelding missen we nog enkele gegevens. Willen jullie de poortomgeving openen en de aanvraag aanvullen?\n\nMet vriendelijke groet,\nDe Duindorpse Poorten`
    : `Beste ${registration.contactName || "bewoner"},\n\n`;
  return `mailto:${registration.email}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

export function PortalReviews({ eventSlug, canPlan = false }: { eventSlug: string; canPlan?: boolean }) {
  const [snapshot, setSnapshot] = useState<Snapshot>({ realtimeTopic: null, worlds: [], registrations: [], activePortals: [] });
  const [activeTab, setActiveTab] = useState<"registrations" | "active" | "rooms" | "manual" | "concepts" | "planboard">("registrations");
  const [operationReview,setOperationReview] = useState<{portal:ActivePortal;state:"open"|"paused"|"closed";hash:string;key:string;groups:Array<{code:string;startsAt:string}>;pending:number;reservations:number}|null>(null);
  const [editingPortalId, setEditingPortalId] = useState<string | undefined>();
  const [registrationFilter, setRegistrationFilter] = useState("all");
  const [notice, setNotice] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);


  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const result = await client.schema("api").rpc("admin_portal_management_snapshot", { _event_slug: eventSlug });
    if (result.error) return setNotice("De poortenlijsten konden niet worden opgehaald.");
    setSnapshot(result.data as Snapshot);
  }, [eventSlug]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  const realtimeConnected = usePrivateBroadcast(snapshot.realtimeTopic, () => void load());
  useEffect(() => {
    const poll = setInterval(() => { if (!document.hidden) void load(); }, 30_000);
    const refresh = () => void load();
    window.addEventListener("focus", refresh);
    return () => { clearInterval(poll); window.removeEventListener("focus", refresh); };
  }, [load]);

  const registrationCounts = useMemo(() => snapshot.registrations.reduce<Record<PortalRegistrationStatus, number>>((counts, item) => {
    counts[item.status] += 1; return counts;
  }, { awaiting_otp: 0, activated_incomplete: 0, ready_for_review: 0, changes_requested: 0, approved: 0, closed: 0 }), [snapshot.registrations]);

  async function review(registration: PortalRegistration, decision: keyof typeof reviewLabels) {
    if (!registration.applicationId || registration.applicationVersion === null) return;
    const feedback = decision === "approved" ? "Aanmelding goedgekeurd door de organisatie" : window.prompt("Toelichting voor de bewoner (minimaal 10 tekens):")?.trim();
    if (!feedback || feedback.length < 10) return setNotice("Een toelichting van minimaal tien tekens is verplicht.");
    let worldSlug: string | null = null; let latitude: number | null = null; let longitude: number | null = null;
    if (decision === "approved") {
      worldSlug = window.prompt("Wereldslug:", registration.requestedWorldSlug ?? snapshot.worlds[0]?.slug ?? "")?.trim().toLowerCase() ?? null;
      if (!snapshot.worlds.some((world) => world.slug === worldSlug)) return setNotice("Kies een bestaande wereldslug.");
      const coordinateInput = window.prompt("Coördinaten als breedtegraad, lengtegraad (optioneel):", registration.portal?.latitude != null && registration.portal.longitude != null ? `${registration.portal.latitude}, ${registration.portal.longitude}` : "")?.trim() ?? "";
      if (coordinateInput) {
        const coordinate = parseLatitudeLongitude(coordinateInput);
        if (!coordinate) return setNotice("Gebruik het formaat 52.090522, 4.262384 (breedtegraad, lengtegraad).");
        latitude = coordinate.latitude; longitude = coordinate.longitude;
      }
    }
    if (!window.confirm(`${reviewLabels[decision]} definitief vastleggen?`)) return;
    setBusyId(registration.id);
    const client = createClient(); if (!client) return setBusyId(null);
    const { error } = await client.schema("api").rpc("admin_review_portal_application", {
      _application_id: registration.applicationId, _expected_version: registration.applicationVersion,
      _decision: decision, _world_slug: worldSlug, _latitude: latitude, _longitude: longitude, _reason: feedback,
    });
    setBusyId(null);
    setNotice(error ? error.message.includes("CONTACT_ADDRESS_REQUIRED")
      ? "Goedkeuren kan zodra naam, bevestigd e-mailadres, telefoonnummer en het volledige adres zijn ingevuld."
      : `Beoordeling geweigerd: ${error.message}` : `${reviewLabels[decision]} opgeslagen.`);
    if (!error) await load();
  }

  async function verifyLocation(registration: PortalRegistration) {
    if (!registration.portal) return;
    const input = window.prompt("Coördinaten als breedtegraad, lengtegraad:", registration.portal.latitude !== null && registration.portal.longitude !== null ? `${registration.portal.latitude}, ${registration.portal.longitude}` : "")?.trim() ?? "";
    const coordinate = parseLatitudeLongitude(input);
    if (!coordinate) return setNotice("Gebruik het formaat 52.090522, 4.262384 (breedtegraad, lengtegraad).");
    if (!window.confirm("Locatie als fysiek gecontroleerd markeren?")) return;
    setBusyId(registration.id);
    const client = createClient(); if (!client) return setBusyId(null);
    const { error } = await client.schema("api").rpc("admin_verify_portal_location", {
      _portal_id: registration.portal.id, _expected_portal_version: registration.portal.version,
      _latitude: coordinate.latitude, _longitude: coordinate.longitude, _reason: "Locatie geverifieerd door de organisatie",
    });
    setBusyId(null); setNotice(error ? `Locatieverificatie geweigerd: ${error.message}` : "Locatie geverifieerd.");
    if (!error) await load();
  }

  async function sendPortalMessage(portal: ActivePortal) {
    const body = window.prompt(`Bericht aan ${portal.systemCode} · ${portal.name}:`)?.trim();
    if (!body) return;
    const client = createClient(); if (!client) return;
    const idempotencyKey = crypto.randomUUID();
    const requestHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify({ eventSlug, subjectKind: "portal", subjectId: portal.portalId, body }))))]
      .map((byte) => byte.toString(16).padStart(2, "0")).join("");
    setBusyId(portal.portalId);
    const { error } = await client.schema("api").rpc("admin_messenger_create", {
      _event_slug: eventSlug, _subject_kind: "portal", _subject_id: portal.portalId, _body: body,
      _idempotency_key: idempotencyKey, _request_hash: requestHash,
    });
    setBusyId(null); setNotice(error ? `Bericht kon niet worden verstuurd: ${error.message}` : "Bericht staat in het gesprek met deze poort.");
  }

  async function setPortalState(portal: ActivePortal, state: "open" | "paused" | "closed") {
    const client=createClient();if(!client||busyId)return;
    setBusyId(portal.portalId);
    try {
      const r=await client.schema("api").rpc("admin_portal_change_impact",{_portal_id:portal.portalId});
      if(r.error){setNotice(r.error.message);return;}
      setOperationReview({portal,state,hash:r.data.inputHash,key:crypto.randomUUID(),groups:[...r.data.publishedGroups,...r.data.confirmedGroups],pending:r.data.pendingStops,reservations:r.data.reservations});
    }catch{setNotice("De actuele poortimpact kon niet worden opgehaald.");}finally{setBusyId(null);}
  }
  async function applyPortalState() {
    const client=createClient();if(!client||!operationReview||busyId)return;setBusyId(operationReview.portal.portalId);
    try {
      const r=await client.schema("api").rpc("admin_portal_operation_reviewed",{_portal_id:operationReview.portal.portalId,_state:operationReview.state,_expected_version:operationReview.portal.version,_input_hash:operationReview.hash,_key:operationReview.key});
      if(r.error){setNotice(/STALE_/.test(r.error.message)?"De poortplanning is gewijzigd. Sluit de preview en beoordeel de actuele impact opnieuw.":r.error.message);return;}
      setOperationReview(null);setNotice("Operationele poortstatus opgeslagen via de bestaande avondregie.");await load();
    }catch{setNotice("Statuswijziging is niet bevestigd. Probeer dezelfde opdracht opnieuw.");}finally{setBusyId(null);}
  }

  async function openAsset(path: string) {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.storage.from("portal-application-assets").createSignedUrl(path, 60);
    if (error || !data.signedUrl) return setNotice("De privéafbeelding kon niet worden geopend.");
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  return <section className="panel portal-management">
    <header className="portal-management-head">
      <div><p className="kicker">Poorten & teams</p><h2>Jullie poorten</h2><p>Beoordeel aanmeldingen, help poortteams en houd de avond in de gaten.</p></div>
      <div className="portal-management-actions"><div className="portal-live-state" data-connected={realtimeConnected}><span><Radio />{realtimeConnected ? "Live" : "Verbinding wordt hersteld"}</span><button className="btn outline" type="button" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div><button className="btn" type="button" onClick={() => setActiveTab("manual")}><Plus />Poort toevoegen</button></div>
    </header>

    <div className="portal-management-stats" aria-label="Overzicht poortaanmeldingen">
      <span><strong>{snapshot.registrations.length}</strong> totaal aangemeld</span>
      <span><strong>{registrationCounts.awaiting_otp}</strong> wacht op e-mailbevestiging</span>
      <span><strong>{registrationCounts.ready_for_review}</strong> te beoordelen</span>
      <span><strong>{snapshot.activePortals.length}</strong> actieve poorten</span>
    </div>

    <div className="portal-management-tabs" role="tablist" aria-label="Poortenlijsten">
      {canPlan && <button type="button" role="tab" aria-selected={activeTab === "planboard"} className={activeTab === "planboard" ? "active" : ""} onClick={() => setActiveTab("planboard")}>Live planbord</button>}
      <button type="button" role="tab" aria-selected={activeTab === "registrations"} className={activeTab === "registrations" ? "active" : ""} onClick={() => setActiveTab("registrations")}>Aangemelde poorten <span>{snapshot.registrations.length}</span></button>
      <button type="button" role="tab" aria-selected={activeTab === "rooms"} className={activeTab === "rooms" ? "active" : ""} onClick={() => setActiveTab("rooms")}>Poortkamers en moderatie</button>
      <button type="button" role="tab" aria-selected={activeTab === "active"} className={activeTab === "active" ? "active" : ""} onClick={() => setActiveTab("active")}>Actieve poorten <span>{snapshot.activePortals.length}</span></button>
      <button type="button" role="tab" aria-selected={activeTab === "concepts"} className={activeTab === "concepts" ? "active" : ""} onClick={() => setActiveTab("concepts")}>Conceptpoorten <span>{snapshot.conceptPortals?.length ?? 0}</span></button>
      <button type="button" role="tab" aria-selected={activeTab === "manual"} className={activeTab === "manual" ? "active" : ""} onClick={() => setActiveTab("manual")}>Poorten beheren</button>
    </div>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    {operationReview&&<AdminDialog labelledBy="portal-operation-review" close={()=>{if(!busyId)setOperationReview(null);}}><h2 id="portal-operation-review">Poortstatus wijzigen · {operationReview.portal.systemCode}</h2><p>{operationLabels[operationReview.portal.operationStatus]} → {operationReview.state === "open" ? "Open" : operationReview.state === "paused" ? "Pauze" : "Gestopt"}</p><p>{operationReview.groups.length} bevestigde/gepubliceerde afspraken · {operationReview.pending} huidige bezoeken · {operationReview.reservations} reserveringen.</p>{operationReview.groups.map((g,i)=><p key={i}>{g.code} · {new Date(g.startsAt).toLocaleTimeString("nl-NL",{timeZone:"Europe/Amsterdam",hour:"2-digit",minute:"2-digit"})}</p>)}<p>De bestaande avondregie controleert de gevolgen opnieuw. Een echte aankomst wordt niet door deze statuswijziging herschreven.</p>{notice&&<p role="status">{notice}</p>}<div className="actions"><button className="btn outline" type="button" disabled={Boolean(busyId)} onClick={()=>setOperationReview(null)}>Annuleren</button><button className="btn" type="button" disabled={Boolean(busyId)} onClick={()=>void applyPortalState()}>Poortstatus bevestigen</button></div></AdminDialog>}

    {activeTab === "planboard" && <LivePlanboard eventSlug={eventSlug} />}
    {activeTab === "rooms" && <PoortkamerOverview eventSlug={eventSlug} />}
    {activeTab === "concepts" && <ManualPortalManager key="concepts" initialFilter="concept" eventSlug={eventSlug} worlds={snapshot.worlds} onChanged={() => void load()} />}
    {activeTab === "manual" && <ManualPortalManager key={editingPortalId ?? "all"} initialPortalId={editingPortalId} eventSlug={eventSlug} worlds={snapshot.worlds} onChanged={() => void load()} />}
    {activeTab === "registrations" && <div role="tabpanel" className="portal-list-panel">
      <div className="portal-list-intro"><div><p className="kicker">Aanmeldingen</p><h3>Aangemelde poorten</h3></div><label>Status<select value={registrationFilter} onChange={e=>setRegistrationFilter(e.target.value)}><option value="all">Alle aanmeldingen</option>{Object.entries(portalRegistrationStatusLabels).map(([key,label])=><option key={key} value={key}>{label}</option>)}</select></label><p>Bekijk hoe ver een aanmelding is en open deze voor de gegevens en beoordeling.</p></div>
      {snapshot.registrations.length === 0 ? <div className="portal-empty"><Home /><p>Er zijn nog geen huisaanmeldingen binnengekomen.</p></div> : <div className="portal-premium-list">
        {snapshot.registrations.filter(r => registrationFilter === "all" || r.status === registrationFilter).map((registration) => {
          const progress = countPortalRegistrationProgress(registration.progress);
          const address = formatPortalAddress(registration.address);
          const canReview = registration.applicationStatus === "submitted" && registration.applicationId && registration.applicationVersion !== null;
          return <details className={`portal-list-row portal-status-${registration.status}`} key={registration.id}>
            <summary>
              <span className="portal-code">{registration.code}</span>
              <span className="portal-primary"><strong>{registration.contactName || "Naam nog niet ingevuld"}</strong><small>{address}</small></span>
              <span className="portal-phone">{registration.phone ? <a href={`tel:${registration.phone.replace(/\s/g, "")}`} onClick={(event) => event.stopPropagation()}><Phone />{registration.phone}</a> : "Geen telefoonnummer"}</span>
              <span className="portal-status-badge">{registration.applicationStatus === "draft" && progress.completed === 4 ? "Nog niet ingediend" : portalRegistrationStatusLabels[registration.status]}</span>
              <time dateTime={registration.lastActivityAt}><Clock3 />{formatDate(registration.lastActivityAt)}</time>
              <ChevronDown className="portal-expand-icon" />
            </summary>
            <div className="portal-row-details">
              <div className="portal-detail-main">
                <div className="portal-detail-grid">
                  <div><span><UserRound />Contactpersoon</span><strong>{registration.contactName || "Niet ingevuld"}</strong></div>
                  <div><span><Mail />E-mail</span><strong>{registration.email ? <a href={`mailto:${registration.email}`}>{registration.email}</a> : "Niet ingevuld"}</strong></div>
                  <div><span><Phone />Telefoon</span><strong>{registration.phone ? <a href={`tel:${registration.phone.replace(/\s/g, "")}`}>{registration.phone}</a> : "Niet ingevuld"}</strong></div>
                  <div><span><Home />Adres</span><strong>{address}</strong></div>
                </div>
                <section className="portal-progress-card" aria-label={`${progress.completed} van ${progress.total} onderdelen ingevuld`}>
                  <div><span>Voortgang aanvraag</span><strong>{progress.completed} van {progress.total} onderdelen</strong></div>
                  <div className="portal-progress-track"><span style={{ width: `${progress.percentage}%` }} /></div>
                  {progress.completed === 4 && ["draft","changes_requested"].includes(registration.applicationStatus ?? "") && <p><strong>Gegevens ingevuld · nog niet ingediend</strong><br/>Vier categorieën ingevuld. Indienen is een aparte stap; de server controleert de vereiste gegevens.</p>}<div className="portal-progress-steps"><span data-complete={registration.progress.contact}>Contact</span><span data-complete={registration.progress.address}>Adres</span><span data-complete={registration.progress.experience}>Beleving</span><span data-complete={registration.progress.planning}>Planning</span></div>
                </section>
                <section className="portal-filled-data">
                  <h4>Ingevulde gegevens</h4>
                  <dl>
                    <div><dt>Poortnaam</dt><dd>{displayValue(registration.draft.portalName)}</dd></div><div><dt>Wereldvoorkeur</dt><dd>{displayValue(registration.requestedWorldSlug)}</dd></div>
                    <div><dt>Spanning</dt><dd>{displayValue(registration.draft.intensity)}</dd></div><div><dt>Ingang</dt><dd>{displayValue(registration.draft.entrance)}</dd></div>
                    <div><dt>Beschikbaar</dt><dd>{registration.draft.availableFrom && registration.draft.availableUntil ? `${registration.draft.availableFrom}–${registration.draft.availableUntil}` : "Niet ingevuld"}</dd></div>
                    <div><dt>Toegankelijkheid</dt><dd>{displayValue(registration.draft.accessibility)}</dd></div><div className="wide"><dt>Beschrijving</dt><dd>{displayValue(registration.draft.description)}</dd></div>
                  </dl>
                  {registration.reviewFeedback && <p className="portal-review-feedback"><strong>Laatste terugkoppeling:</strong> {registration.reviewFeedback}</p>}
                  {(registration.draft.assetPaths ?? []).map((path, index) => <button className="text-link" type="button" key={path} onClick={() => void openAsset(path)}>Bekijk privéfoto {index + 1}</button>)}
                </section>
              </div>
              <aside className="portal-timeline"><h4>Tijdlijn</h4>{registration.timeline.length === 0 ? <p>Nog geen tijdlijn beschikbaar.</p> : registration.timeline.map((entry, index) => <div key={`${entry.label}-${entry.at}-${index}`}><span /><p><strong>{entry.label}</strong><time dateTime={entry.at}>{formatDate(entry.at)}</time></p></div>)}</aside>
              <div className="portal-row-actions">
                {(registration.intakeId || registration.applicationId) && <PortalRegistrationActions applicationId={registration.applicationId} worlds={snapshot.worlds} canSubmit={Boolean(snapshot.canSubmitApplications && registration.applicationId && registration.applicationVersion && ["draft","changes_requested"].includes(registration.applicationStatus ?? "") && !registration.intakeWithdrawn && !registration.portalArchived && registration.status !== "closed")} onSubmitted={()=>setNotice("Aanvraag namens bewoner ingediend. Goedkeuren en activeren blijven aparte stappen.")} onEditPortal={()=>{setEditingPortalId(registration.portalId!);setActiveTab("manual");}} operational={Boolean(registration.portalId)} eventSlug={eventSlug} kind={registration.intakeId ? "intake" : "application"} id={(registration.intakeId ?? registration.applicationId)!} reload={load} />}
                {registration.portalId && <button className="btn outline" type="button" onClick={() => { setEditingPortalId(registration.portalId!); setActiveTab("manual"); }}>Gegevens bewerken</button>}
                {registration.phone && <a className="btn outline" href={`tel:${registration.phone.replace(/\s/g, "")}`}><Phone />Bellen</a>}
                {registration.email && <a className="btn outline" href={emailHref(registration)}><Mail />Bericht sturen</a>}
                {registration.email && registration.status !== "approved" && <a className="btn outline" href={emailHref(registration, true)}><FileSearch />Gegevens opvragen</a>}
                {canReview && <><button className="btn" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "approved")}><CheckCircle2 />Goedkeuren</button><button className="btn outline" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "changes_requested")}><RotateCcw />Aanpassing vragen</button><button className="btn outline" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "rejected")}><XCircle />Afwijzen</button></>}
                {!registration.portalArchived && registration.applicationStatus === "approved" && registration.portal && !registration.portal.locationVerified && <button className="btn" type="button" disabled={busyId === registration.id} onClick={() => void verifyLocation(registration)}><MapPinCheck />Locatie verifiëren</button>}
              </div>
            </div>
          </details>;
        })}
      </div>}
    </div>}

    {activeTab === "active" && <div role="tabpanel" className="portal-list-panel">
      <div className="portal-list-intro"><div><p className="kicker">Goedgekeurd en operationeel beschikbaar</p><h3>Actieve poorten</h3></div><p>Deze lijst bevat uitsluitend goedgekeurde poorten waarvoor een actief poortrecord bestaat.</p></div>
      {snapshot.activePortals.length === 0 ? <div className="portal-empty"><ShieldCheck /><p>Er zijn nog geen actieve poorten.</p></div> : <div className="portal-premium-list active-portals-list">
        {snapshot.activePortals.map((portal) => <details className={`portal-list-row operation-${portal.operationStatus}${portal.isFinal ? " is-final" : ""}`} id={`portal-${portal.portalId}`} key={portal.portalId}>
          <summary><span className="portal-code">{portal.systemCode}</span><span className="portal-primary"><strong>{portal.name}</strong><small>{portal.world} · {portal.contactName || "Contactpersoon niet ingevuld"}</small></span><span className="portal-phone">{portal.phone ? <a href={`tel:${portal.phone.replace(/\s/g, "")}`} onClick={(event) => event.stopPropagation()}><Phone />{portal.phone}</a> : "Geen telefoonnummer"}</span><span className={`portal-status-badge operation-${portal.operationStatus}`}>{operationLabels[portal.operationStatus]}</span><span className="portal-arrivals"><strong>{portal.activeReservations}</strong> groepen · <strong>{portal.expectedChildren}</strong> kinderen</span><ChevronDown className="portal-expand-icon" /></summary>
          <div className="portal-row-details active-portal-details">
            <div className="portal-detail-grid"><div><span><UserRound />Contactpersoon</span><strong>{portal.contactName || "Niet ingevuld"}</strong></div><div><span><Mail />E-mail</span><strong>{portal.email ? <a href={`mailto:${portal.email}`}>{portal.email}</a> : "Niet ingevuld"}</strong></div><div><span><Phone />Telefoon</span><strong>{portal.phone ? <a href={`tel:${portal.phone.replace(/\s/g, "")}`}>{portal.phone}</a> : "Niet ingevuld"}</strong></div><div><span><Home />Adres</span><strong>{portal.formattedAddress || "Niet ingevuld"}</strong></div><div><span><MapPinCheck />Locatiecontrole</span><strong>{portal.locationVerified ? "Geverifieerd" : "Nog te verifiëren"}</strong></div><div><span><Radio />Verwachte instroom</span><strong>{portal.activeReservations} groepen · {portal.expectedChildren} kinderen</strong></div></div>
            <div className="portal-row-actions"><button className="btn outline" type="button" onClick={() => { setEditingPortalId(portal.portalId); setActiveTab("manual"); }}>Gegevens bewerken</button><Link className="btn outline" href={`/admin/poortkamer/${portal.portalId}`}>Team en Poortkamer</Link>{portal.phone && <a className="btn outline" href={`tel:${portal.phone.replace(/\s/g, "")}`}><Phone />Bellen</a>}<button className="btn outline" type="button" disabled={busyId === portal.portalId} onClick={() => void sendPortalMessage(portal)}><MessageCircle />Bericht sturen</button></div>
            <div className="portal-operation-actions" role="group" aria-label={`Operationele status van ${portal.systemCode}`}><button type="button" className={portal.operationStatus === "open" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "open"} onClick={() => void setPortalState(portal, "open")}>Open</button><button type="button" className={portal.operationStatus === "paused" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "paused"} onClick={() => void setPortalState(portal, "paused")}>Pauze</button><button type="button" className={portal.operationStatus === "closed" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "closed"} onClick={() => void setPortalState(portal, "closed")}>Gestopt</button></div>
          </div>
        </details>)}
      </div>}
    </div>}
  </section>;
}
