"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  CheckCircle2, ChevronDown, Clock3, FileSearch, Home, Mail, MapPinCheck,
  MessageCircle, Phone, Radio, RefreshCw, RotateCcw, ShieldCheck, UserRound, XCircle,
} from "lucide-react";
import {
  countPortalRegistrationProgress,
  formatPortalAddress,
  portalRegistrationStatusLabels,
  type PortalRegistrationProgress,
  type PortalRegistrationStatus,
} from "@/lib/domain/admin-portals";
import { parseLatitudeLongitude } from "@/lib/maps/coordinates";
import { createClient } from "@/lib/supabase/client";

type World = { id: string; slug: string; name: string };
type Address = { street?: string; houseNumber?: string; addition?: string; postalCode?: string; city?: string };
type TimelineEntry = { label: string; at: string };
type PortalRegistration = {
  id: string; intakeId: string | null; applicationId: string | null; portalId: string | null; code: string;
  status: PortalRegistrationStatus;
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

type Snapshot = { realtimeTopic: string | null; worlds: World[]; registrations: PortalRegistration[]; activePortals: ActivePortal[] };

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

export function PortalReviews({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot>({ realtimeTopic: null, worlds: [], registrations: [], activePortals: [] });
  const [activeTab, setActiveTab] = useState<"registrations" | "active">("registrations");
  const [notice, setNotice] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [realtimeConnected, setRealtimeConnected] = useState(false);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const result = await client.schema("api").rpc("admin_portal_management_snapshot", { _event_slug: eventSlug });
    if (result.error) return setNotice("De poortenlijsten konden niet worden opgehaald.");
    setSnapshot(result.data as Snapshot);
  }, [eventSlug]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  useEffect(() => {
    const client = createClient();
    if (!client || !snapshot.realtimeTopic) return;
    let refreshTimer: number | undefined;
    const scheduleRefresh = () => {
      window.clearTimeout(refreshTimer);
      refreshTimer = window.setTimeout(() => void load(), 180);
    };
    const channel = client.channel(snapshot.realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, scheduleRefresh)
      .subscribe((status: string) => setRealtimeConnected(status === "SUBSCRIBED"));
    const poll = window.setInterval(() => void load(), 60_000);
    const onFocus = () => void load();
    window.addEventListener("focus", onFocus);
    return () => {
      window.clearTimeout(refreshTimer); window.clearInterval(poll); window.removeEventListener("focus", onFocus);
      setRealtimeConnected(false); void client.removeChannel(channel);
    };
  }, [load, snapshot.realtimeTopic]);

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
    setBusyId(portal.portalId);
    const client = createClient(); if (!client) return setBusyId(null);
    const { error } = await client.schema("api").rpc("portal_set_operational_state", {
      _portal_id: portal.portalId, _state: state, _expected_version: portal.version,
      _reason: `Poortstatus ingesteld op ${state} via Nachtregie`,
    });
    setBusyId(null);
    setNotice(error ? `Poortstatus kon niet worden gewijzigd: ${error.message}` : `${portal.systemCode} staat nu op ${state === "open" ? "open" : state === "paused" ? "pauze" : "gestopt"}.`);
    if (!error) await load();
  }

  async function openAsset(path: string) {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.storage.from("portal-application-assets").createSignedUrl(path, 60);
    if (error || !data.signedUrl) return setNotice("De privéafbeelding kon niet worden geopend.");
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  return <section className="panel portal-management">
    <header className="portal-management-head">
      <div><p className="kicker">Privé poortregie</p><h2>Van eerste aanmelding tot actieve poort.</h2><p>Intake en aanvraag staan samen op één regel. Contactgegevens zijn alleen beschikbaar binnen deze bevoegde beheeromgeving.</p></div>
      <div className="portal-live-state" data-connected={realtimeConnected}><span><Radio />{realtimeConnected ? "Realtime verbonden" : "Verbinding wordt hersteld"}</span><button className="btn outline" type="button" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>
    </header>

    <div className="portal-management-stats" aria-label="Overzicht poortaanmeldingen">
      <span><strong>{snapshot.registrations.length}</strong> totaal aangemeld</span>
      <span><strong>{registrationCounts.awaiting_otp}</strong> wacht op OTP</span>
      <span><strong>{registrationCounts.ready_for_review}</strong> te beoordelen</span>
      <span><strong>{snapshot.activePortals.length}</strong> actieve poorten</span>
    </div>

    <div className="portal-management-tabs" role="tablist" aria-label="Poortenlijsten">
      <button type="button" role="tab" aria-selected={activeTab === "registrations"} className={activeTab === "registrations" ? "active" : ""} onClick={() => setActiveTab("registrations")}>Aangemelde poorten <span>{snapshot.registrations.length}</span></button>
      <button type="button" role="tab" aria-selected={activeTab === "active"} className={activeTab === "active" ? "active" : ""} onClick={() => setActiveTab("active")}>Actieve poorten <span>{snapshot.activePortals.length}</span></button>
    </div>
    {notice && <div className="form-notice" role="status">{notice}</div>}

    {activeTab === "registrations" && <div role="tabpanel" className="portal-list-panel">
      <div className="portal-list-intro"><div><p className="kicker">Iedere binnengekomen intake</p><h3>Aangemelde poorten</h3></div><p>Concepten blijven zichtbaar vanaf stap 1, ook vóór activatie van de poortomgeving.</p></div>
      {snapshot.registrations.length === 0 ? <div className="portal-empty"><Home /><p>Er zijn nog geen huisaanmeldingen binnengekomen.</p></div> : <div className="portal-premium-list">
        {snapshot.registrations.map((registration) => {
          const progress = countPortalRegistrationProgress(registration.progress);
          const address = formatPortalAddress(registration.address);
          const canReview = registration.applicationStatus === "submitted" && registration.applicationId && registration.applicationVersion !== null;
          return <details className={`portal-list-row portal-status-${registration.status}`} key={registration.id}>
            <summary>
              <span className="portal-code">{registration.code}</span>
              <span className="portal-primary"><strong>{registration.contactName || "Naam nog niet ingevuld"}</strong><small>{address}</small></span>
              <span className="portal-phone">{registration.phone ? <a href={`tel:${registration.phone.replace(/\s/g, "")}`} onClick={(event) => event.stopPropagation()}><Phone />{registration.phone}</a> : "Geen telefoonnummer"}</span>
              <span className="portal-status-badge">{portalRegistrationStatusLabels[registration.status]}</span>
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
                  <div className="portal-progress-steps"><span data-complete={registration.progress.contact}>Contact</span><span data-complete={registration.progress.address}>Adres</span><span data-complete={registration.progress.experience}>Beleving</span><span data-complete={registration.progress.planning}>Planning</span></div>
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
                {registration.phone && <a className="btn outline" href={`tel:${registration.phone.replace(/\s/g, "")}`}><Phone />Bellen</a>}
                {registration.email && <a className="btn outline" href={emailHref(registration)}><Mail />Bericht sturen</a>}
                {registration.email && registration.status !== "approved" && <a className="btn outline" href={emailHref(registration, true)}><FileSearch />Gegevens opvragen</a>}
                {canReview && <><button className="btn" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "approved")}><CheckCircle2 />Goedkeuren</button><button className="btn outline" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "changes_requested")}><RotateCcw />Aanpassing vragen</button><button className="btn outline" type="button" disabled={busyId === registration.id} onClick={() => void review(registration, "rejected")}><XCircle />Afwijzen</button></>}
                {registration.applicationStatus === "approved" && registration.portal && !registration.portal.locationVerified && <button className="btn" type="button" disabled={busyId === registration.id} onClick={() => void verifyLocation(registration)}><MapPinCheck />Locatie verifiëren</button>}
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
            <div className="portal-row-actions">{portal.phone && <a className="btn outline" href={`tel:${portal.phone.replace(/\s/g, "")}`}><Phone />Bellen</a>}<button className="btn outline" type="button" disabled={busyId === portal.portalId} onClick={() => void sendPortalMessage(portal)}><MessageCircle />Bericht sturen</button></div>
            <div className="portal-operation-actions" role="group" aria-label={`Operationele status van ${portal.systemCode}`}><button type="button" className={portal.operationStatus === "open" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "open"} onClick={() => void setPortalState(portal, "open")}>Open</button><button type="button" className={portal.operationStatus === "paused" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "paused"} onClick={() => void setPortalState(portal, "paused")}>Pauze</button><button type="button" className={portal.operationStatus === "closed" ? "active" : ""} disabled={busyId === portal.portalId || portal.operationStatus === "closed"} onClick={() => void setPortalState(portal, "closed")}>Gestopt</button></div>
          </div>
        </details>)}
      </div>}
    </div>}
  </section>;
}
