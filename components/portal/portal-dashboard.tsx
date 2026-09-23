"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Check, Clock, DoorOpen, Download, QrCode, RefreshCw } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Snapshot = { application: { id: string; status: string; version: number; draft: Record<string, unknown>; reviewFeedback?: string | null }; portal: null | { id: string; name: string; description: string; intensity: number; approvalStatus: string; operationStatus: "scheduled" | "open" | "paused" | "closed"; version: number; world: string; hasCredential: boolean; nextArrival?: string | null } };
type CredentialMaterial = { credentialVersion: number; shortCode: string; qrDataUrl: string };

export function PortalDashboard({ eventSlug }: { eventSlug: string }) {
  const [loaded, setLoaded] = useState(false);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [credentialMaterial, setCredentialMaterial] = useState<CredentialMaterial | null>(null);
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data, error } = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug }); if (error) { setNotice("Je huisgegevens konden niet worden opgehaald. Vernieuw de pagina om opnieuw te proberen."); return; } setSnapshot(data as Snapshot | null); setLoaded(true); }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function setState(state: "open" | "paused" | "closed") {
    const client = createClient(); if (!client || !snapshot?.portal) return;
    const { error } = await client.schema("api").rpc("portal_set_operational_state", { _portal_id: snapshot.portal.id, _state: state, _expected_version: snapshot.portal.version, _reason: state === "open" ? "Bewoner meldt poort gereed" : "Bewoner wijzigt operationele status" });
    setNotice(error ? "De status was verouderd; de actuele stand is opgehaald." : "Status door de server bevestigd."); await load();
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
  if (!snapshot) return <div className="panel"><h2>Meld je huis aan</h2><p>Begin met je contactgegevens en adres.</p><Link className="btn" href="/huis-aanmelden">Huis aanmelden</Link></div>;
  if (["draft", "changes_requested"].includes(snapshot.application.status)) return <div className="panel"><h2>Vul je huisdetails aan</h2><p>Je basisgegevens zijn opgeslagen. Voeg je beleving, beschikbaarheid en overige details toe en dien je huis in voor beoordeling.</p>{snapshot.application.reviewFeedback && <p>{snapshot.application.reviewFeedback}</p>}<Link className="btn" href="/huis-aanmelden">Huisdetails aanvullen</Link></div>;
  if (!snapshot.portal) return <div className="panel empty-state"><Clock /><h2>Aanmelding in beoordeling</h2><p>Status: {snapshot.application.status}. Een huis wordt pas een poort na expliciete goedkeuring.</p>{snapshot.application.reviewFeedback && <div className="form-warning">Terugkoppeling: {snapshot.application.reviewFeedback}</div>}</div>;
  const portal = snapshot.portal;
  return <div className="house-grid"><section className="house-art"><img src="/images/pluvierstraat.webp" alt="Verlichte Duindorpse poort" /><div><p className="kicker">{portal.world}</p><h1>{portal.name}</h1><p>{portal.description}</p></div></section><div className="dashboard-stack"><section className="panel"><p className="kicker">Avondbediening</p><h2>Status: {portal.operationStatus}</h2><p>Gebruik pauze zodra ontvangst niet veilig is. Groepen krijgen na verversen de gewijzigde status.</p>{portal.nextArrival && <div className="arrival"><Clock /><span>Volgende geplande groep</span><strong>{new Date(portal.nextArrival).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" })}</strong></div>}<div className="house-actions"><button className="btn" disabled={portal.operationStatus === "open"} onClick={() => void setState("open")}><Check />Open</button><button className="btn outline" disabled={portal.operationStatus === "paused"} onClick={() => void setState("paused")}><AlertTriangle />Pauze</button><button className="btn outline" disabled={portal.operationStatus === "closed"} onClick={() => void setState("closed")}><DoorOpen />Sluiten</button></div></section><section className="panel portal-credential"><p className="kicker">Scanmateriaal</p><h2>QR-code en noodcode</h2><p>{portal.hasCredential ? "Vervangen trekt alle eerdere codes direct in. Doe dit alleen als materiaal kwijt, beschadigd of mogelijk gedeeld is." : "Maak na goedkeuring een eerste QR-code en noodcode. Het geheime materiaal wordt maar één keer getoond."}</p><button className="btn outline" onClick={() => void rotateCredential()}><RefreshCw />{portal.hasCredential ? "QR en noodcode vervangen" : "Eerste QR en noodcode maken"}</button>{credentialMaterial && <div className="credential-sheet"><QrCode /><h3>Poortcode versie {credentialMaterial.credentialVersion}</h3><img src={credentialMaterial.qrDataUrl} alt={`Nieuwe QR-code voor ${portal.name}`} /><p>Korte noodcode</p><div className="registration-code">{credentialMaterial.shortCode}</div><div className="actions"><a className="btn" href={credentialMaterial.qrDataUrl} download={`duindorp-poort-${credentialMaterial.credentialVersion}.png`}><Download />Download PNG</a><button className="btn outline" onClick={() => setCredentialMaterial(null)}>Verwijder van scherm</button></div></div>}{notice && <p className="form-notice" role="status">{notice}</p>}</section></div></div>;
}
