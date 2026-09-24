"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Check, Clock, DoorOpen, Download, QrCode, RefreshCw } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { PortalWizard } from "@/components/registration/portal-wizard";
import { PortalForecast } from "@/components/portal/portal-forecast";

type Snapshot = { application: { id: string; status: string; version: number; draft: Record<string, unknown>; reviewFeedback?: string | null }; portal: null | { id: string; systemCode?: string | null; name: string; description: string; intensity: number; approvalStatus: string; operationStatus: "scheduled" | "open" | "paused" | "closed"; version: number; world: string; hasCredential: boolean; nextArrival?: string | null } };
type CredentialMaterial = { credentialVersion: number; shortCode: string; qrDataUrl: string };
const operationLabels = { scheduled: "Ingepland", open: "Open", paused: "Pauze", closed: "Gesloten" } as const;
const warningLabels: Record<string, string> = { smoke: "Rookeffecten", flashes: "Flitsend licht", sound: "Hard geluid", actors: "Acteurs of schrikmomenten", allergens: "Mogelijke allergenen" };
const accessibilityLabels: Record<string, string> = { step_free: "Drempelvrij", steps: "Trappen of hoge drempels", mixed: "Gedeeltelijk toegankelijk", unknown: "Nog te beoordelen" };

export function PortalDashboard({ eventSlug }: { eventSlug: string }) {
  const [loaded, setLoaded] = useState(false);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [credentialMaterial, setCredentialMaterial] = useState<CredentialMaterial | null>(null);
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data, error } = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug }); if (error) { setNotice("Jullie gegevens konden niet worden opgehaald. Vernieuw de pagina om opnieuw te proberen."); return; } setSnapshot(data as Snapshot | null); setLoaded(true); }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function setState(state: "open" | "paused" | "closed") {
    const client = createClient(); if (!client || !snapshot?.portal) return;
    const { error } = await client.schema("api").rpc("portal_set_operational_state", { _portal_id: snapshot.portal.id, _state: state, _expected_version: snapshot.portal.version, _reason: state === "open" ? "Bewoner meldt poort gereed" : "Bewoner wijzigt operationele status" });
    setNotice(error ? "De status is intussen veranderd; de actuele stand is opgehaald." : "De nieuwe status is opgeslagen."); await load();
  }
  async function rotateCredential() {
    const client = createClient(); if (!client || !snapshot?.portal) return;
    const reason = window.prompt("Waarom vervang je de huidige QR-code? De oude code wordt direct ongeldig.", "Nieuw QR-materiaal uitgegeven")?.trim();
    if (!reason || reason.length < 5) return setNotice("Leg voor QR-vervanging minimaal vijf tekens reden vast.");
    const { data, error } = await client.schema("api").rpc("portal_rotate_credential", { _portal_id: snapshot.portal.id, _expected_portal_version: snapshot.portal.version, _reason: reason });
    if (error) { setNotice("De QR-code kon niet worden vervangen. De actuele poortversie is opgehaald."); await load(); return; }
    const material = data as { credentialVersion: number; credential: string; shortCode: string };
    const { default: QRCode } = await import("qrcode");
    const qrDataUrl = await QRCode.toDataURL(material.credential, { errorCorrectionLevel: "H", width: 720, margin: 3, color: { dark: "#06101B", light: "#FFFFFF" } });
    setCredentialMaterial({ credentialVersion: material.credentialVersion, shortCode: material.shortCode, qrDataUrl });
    setNotice("Nieuwe QR-code aangemaakt. Download of print hem nu; het geheime materiaal wordt hierna niet opnieuw getoond.");
    await load();
  }
  if (!loaded) return <div className="panel">{notice || "Poortgegevens ophalen…"}</div>;
  if (!snapshot) return <div className="panel"><h2>Meld jullie plek aan</h2><p>Begin met je contactgegevens en adres.</p><Link className="btn" href="/huis-aanmelden">Plek aanmelden</Link></div>;
  if (["draft", "changes_requested"].includes(snapshot.application.status)) return <PortalWizard eventSlug={eventSlug} />;
  if (!snapshot.portal) return <div className="dashboard-stack"><div className="panel empty-state"><Clock /><h2>Aanmelding in beoordeling</h2><p>De organisatie bekijkt jullie idee. Je kunt de gegevens hieronder ondertussen blijven bijwerken; gewijzigde gegevens worden opnieuw beoordeeld.</p>{snapshot.application.reviewFeedback && <div className="form-warning">Terugkoppeling: {snapshot.application.reviewFeedback}</div>}</div><PortalWizard eventSlug={eventSlug} /></div>;
  const portal = snapshot.portal;
  const warnings = Object.entries(snapshot.application.draft.warnings as Record<string, boolean> | undefined ?? {}).filter(([, enabled]) => enabled).map(([key]) => warningLabels[key] ?? key);
  const accessibility = String(snapshot.application.draft.accessibility ?? "unknown");
  const accessibilityNotes = String(snapshot.application.draft.accessibilityNotes ?? "").trim();
  return <div className="dashboard-stack"><PortalForecast portalId={portal.id} systemCode={portal.systemCode} name={portal.name} operationStatus={portal.operationStatus} /><div className="house-grid"><section className="house-art"><img src="/images/pluvierstraat.webp" alt="Verlichte Duindorpse poort" /><div><p className="kicker">{portal.world}</p><h1>{portal.name}</h1><p>{portal.description}</p></div></section><div className="dashboard-stack"><section className="panel"><p className="kicker">Avondbediening</p><h2>Status: {operationLabels[portal.operationStatus]}</h2><p>Gebruik Pauze zodra ontvangst tijdelijk niet veilig of mogelijk is. De groepsroute verwerkt de gewijzigde status na de eerstvolgende veilige verversing.</p>{portal.nextArrival && <div className="arrival"><Clock /><span>Volgend gepland venster · geen live ETA</span><strong>{new Date(portal.nextArrival).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</strong></div>}<div className="house-actions"><button className="btn" disabled={portal.operationStatus === "open"} onClick={() => void setState("open")}><Check />Open</button><button className="btn outline" disabled={portal.operationStatus === "paused"} onClick={() => void setState("paused")}><AlertTriangle />Pauze</button><button className="btn outline" disabled={portal.operationStatus === "closed"} onClick={() => void setState("closed")}><DoorOpen />Gesloten</button></div></section><section className="panel"><p className="kicker">Aandachtspunten</p><h2>Veilig ontvangen</h2><p><strong>Toegankelijkheid:</strong> {accessibility ? accessibilityLabels[accessibility] ?? accessibility : "Niet ingevuld"}</p>{accessibilityNotes && <p>{accessibilityNotes}</p>}{warnings.length > 0 ? <ul>{warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul> : <p>Geen bijzondere effecten of allergenen opgegeven.</p>}</section><section className="panel portal-credential"><p className="kicker">Bezoekcontrole</p><h2>Bezoekscan en scanmateriaal</h2><p>{portal.hasCredential ? "Deze geheime bezoekcode bevestigt bezoeken via de bestaande scanflow. Vervangen trekt alle eerdere codes direct in; doe dit alleen als materiaal kwijt, beschadigd of mogelijk gedeeld is." : "Maak na goedkeuring een eerste QR-code en korte bezoekcode. Het geheime materiaal wordt maar één keer getoond."}</p><button className="btn outline" onClick={() => void rotateCredential()}><RefreshCw />{portal.hasCredential ? "QR en bezoekcode vervangen" : "Eerste QR en bezoekcode maken"}</button>{credentialMaterial && <div className="credential-sheet"><QrCode /><h3>Bezoekcode versie {credentialMaterial.credentialVersion}</h3><img src={credentialMaterial.qrDataUrl} alt={`Nieuwe QR-code voor ${portal.name}`} /><p>Korte bezoekcode</p><div className="registration-code">{credentialMaterial.shortCode}</div><div className="actions"><a className="btn" href={credentialMaterial.qrDataUrl} download={`duindorp-poort-${credentialMaterial.credentialVersion}.png`}><Download />Download PNG</a><button className="btn outline" onClick={() => setCredentialMaterial(null)}>Verwijder van scherm</button></div></div>}{notice && <p className="form-notice" role="status">{notice}</p>}</section></div></div><PortalWizard eventSlug={eventSlug} /></div>;
}
