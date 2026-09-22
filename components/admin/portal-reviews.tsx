"use client";

import { useCallback, useEffect, useState } from "react";
import { CheckCircle2, MapPinCheck, RefreshCw, RotateCcw, XCircle } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type World = { id: string; slug: string; name: string };
type PortalApplication = {
  id: string;
  status: "submitted" | "changes_requested" | "approved" | "rejected" | "withdrawn";
  version: number;
  submittedAt: string | null;
  applicantEmail: string;
  requestedWorldSlug: string | null;
  draft: {
    contactName?: string;
    phone?: string;
    portalName?: string;
    description?: string;
    intensity?: string;
    assetPaths?: string[];
    address?: { street?: string; houseNumber?: string; addition?: string; postalCode?: string };
  };
  portal: null | {
    id: string;
    version: number;
    name: string;
    locationVerified: boolean;
    latitude: number | null;
    longitude: number | null;
  };
};

type Snapshot = { worlds: World[]; applications: PortalApplication[] };

const statusLabels: Record<PortalApplication["status"], string> = {
  submitted: "In beoordeling",
  changes_requested: "Aanpassing gevraagd",
  approved: "Goedgekeurd",
  rejected: "Afgewezen",
  withdrawn: "Ingetrokken",
};

export function PortalReviews({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot>({ worlds: [], applications: [] });
  const [notice, setNotice] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_portal_applications_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Poortaanvragen konden niet worden opgehaald.");
    setSnapshot(data as Snapshot);
  }, [eventSlug]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function review(application: PortalApplication, decision: "approved" | "changes_requested" | "rejected") {
    const reason = window.prompt(decision === "approved" ? "Auditreden voor goedkeuring (minimaal 10 tekens):" : "Toelichting voor de bewoner (minimaal 10 tekens):")?.trim();
    if (!reason || reason.length < 10) return setNotice("Een reden van minimaal tien tekens is verplicht.");

    let worldSlug: string | null = null;
    let latitude: number | null = null;
    let longitude: number | null = null;
    if (decision === "approved") {
      worldSlug = window.prompt("Wereldslug:", application.requestedWorldSlug ?? snapshot.worlds[0]?.slug ?? "")?.trim().toLowerCase() ?? null;
      if (!snapshot.worlds.some((world) => world.slug === worldSlug)) return setNotice("Kies een bestaande wereldslug.");
      const latitudeInput = window.prompt("Breedtegraad (leeg laten als de locatie later wordt geverifieerd):", "")?.trim() ?? "";
      const longitudeInput = latitudeInput ? window.prompt("Lengtegraad:", "")?.trim() ?? "" : "";
      if (latitudeInput || longitudeInput) {
        latitude = Number(latitudeInput.replace(",", "."));
        longitude = Number(longitudeInput.replace(",", "."));
        if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
          return setNotice("Vul geldige coördinaten in, of laat beide velden leeg.");
        }
      }
    }

    if (!window.confirm(`${statusLabels[decision]} definitief vastleggen?`)) return;
    setBusyId(application.id);
    const client = createClient();
    if (!client) return setBusyId(null);
    const { error } = await client.schema("api").rpc("admin_review_portal_application", {
      _application_id: application.id,
      _expected_version: application.version,
      _decision: decision,
      _world_slug: worldSlug,
      _latitude: latitude,
      _longitude: longitude,
      _reason: reason,
    });
    setBusyId(null);
    setNotice(error ? `Beoordeling geweigerd: ${error.message}` : `${statusLabels[decision]} en geaudit.`);
    if (!error) await load();
  }

  async function verifyLocation(application: PortalApplication) {
    if (!application.portal) return;
    const latitudeInput = window.prompt("Geverifieerde breedtegraad:", application.portal.latitude?.toString() ?? "")?.trim();
    const longitudeInput = window.prompt("Geverifieerde lengtegraad:", application.portal.longitude?.toString() ?? "")?.trim();
    const reason = window.prompt("Auditreden voor locatieverificatie (minimaal 10 tekens):")?.trim();
    if (!latitudeInput || !longitudeInput || !reason || reason.length < 10) return setNotice("Coördinaten en een reden van minimaal tien tekens zijn verplicht.");
    const latitude = Number(latitudeInput.replace(",", "."));
    const longitude = Number(longitudeInput.replace(",", "."));
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return setNotice("De coördinaten zijn ongeldig.");
    if (!window.confirm("Locatie als fysiek gecontroleerd markeren?")) return;

    setBusyId(application.id);
    const client = createClient();
    if (!client) return setBusyId(null);
    const { error } = await client.schema("api").rpc("admin_verify_portal_location", {
      _portal_id: application.portal.id,
      _expected_portal_version: application.portal.version,
      _latitude: latitude,
      _longitude: longitude,
      _reason: reason,
    });
    setBusyId(null);
    setNotice(error ? `Locatieverificatie geweigerd: ${error.message}` : "Locatie geverifieerd en geaudit.");
    if (!error) await load();
  }

  async function openAsset(path: string) {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.storage.from("portal-application-assets").createSignedUrl(path, 60);
    if (error || !data.signedUrl) return setNotice("De privéafbeelding kon niet worden geopend.");
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  return <section className="panel">
    <div className="row-between"><div><p className="kicker">Privé beoordeling</p><h2>Poortaanvragen</h2></div><button className="btn outline" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>
    <p>Exacte adressen zijn alleen hier zichtbaar. Een goedgekeurde maar nog niet fysiek geverifieerde locatie wordt niet aan de routeplanner aangeboden.</p>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    {snapshot.applications.length === 0 ? <p>Er zijn nog geen ingediende aanvragen.</p> : snapshot.applications.map((application) => {
      const address = application.draft.address;
      return <div className="incident-row" key={application.id}>
        <div>
          <strong>{application.draft.portalName || "Naamloze poort"} · {statusLabels[application.status]}</strong>
          <small>{application.applicantEmail} · {address?.street} {address?.houseNumber}{address?.addition ? ` ${address.addition}` : ""}, {address?.postalCode} Den Haag · spanning {application.draft.intensity ?? "?"} · versie {application.version}</small>
          {application.draft.description && <p>{application.draft.description}</p>}
          {(application.draft.assetPaths ?? []).map((path, index) => <button className="text-link" key={path} onClick={() => void openAsset(path)}>Bekijk privéfoto {index + 1}</button>)}
          {application.portal && <small>Wereld: {application.requestedWorldSlug} · locatie {application.portal.locationVerified ? "geverifieerd" : "nog te verifiëren"}</small>}
        </div>
        <div className="actions">
          {application.status === "submitted" && <>
            <button className="btn" disabled={busyId === application.id} onClick={() => void review(application, "approved")}><CheckCircle2 />Goedkeuren</button>
            <button className="btn outline" disabled={busyId === application.id} onClick={() => void review(application, "changes_requested")}><RotateCcw />Aanpassing</button>
            <button className="btn outline" disabled={busyId === application.id} onClick={() => void review(application, "rejected")}><XCircle />Afwijzen</button>
          </>}
          {application.status === "approved" && application.portal && !application.portal.locationVerified && <button className="btn" disabled={busyId === application.id} onClick={() => void verifyLocation(application)}><MapPinCheck />Locatie verifiëren</button>}
        </div>
      </div>;
    })}
  </section>;
}
