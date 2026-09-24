"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Check, Clock, DoorOpen, Download, Mail, MapPin, Pause, Phone, QrCode, RefreshCw, ShieldCheck, Sparkles, UserRound } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { PortalWizard } from "@/components/registration/portal-wizard";
import { PortalForecast } from "@/components/portal/portal-forecast";
import { worlds } from "@/features/content/public-content";
import styles from "@/components/portal/portal-premium.module.css";

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
  const [statePending, setStatePending] = useState(false);
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data, error } = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug }); if (error) { setNotice("Jullie gegevens konden niet worden opgehaald. Vernieuw de pagina om opnieuw te proberen."); return; } setSnapshot(data as Snapshot | null); setLoaded(true); }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function setState(state: "open" | "paused" | "closed") {
    const client = createClient(); if (!client || !snapshot?.portal || statePending) return;
    setStatePending(true);
    try {
      const { error } = await client.schema("api").rpc("portal_set_operational_state", { _portal_id: snapshot.portal.id, _state: state, _expected_version: snapshot.portal.version, _reason: state === "open" ? "Bewoner meldt poort gereed" : "Bewoner wijzigt operationele status" });
      setNotice(error ? "De status is intussen veranderd; de actuele stand is opgehaald." : "De nieuwe status is opgeslagen.");
      await load();
    } catch { setNotice("De statuswijziging is niet bevestigd. Vernieuw de gegevens en probeer het opnieuw."); }
    finally { setStatePending(false); }
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
  if (!loaded) return <div className={styles.card}>{notice || "Poortgegevens ophalen…"}</div>;
  if (!snapshot) return <div className={styles.card}><h2>Meld jullie plek aan</h2><p>Begin met je contactgegevens en adres.</p><Link className="btn" href="/huis-aanmelden">Plek aanmelden</Link></div>;
  if (["draft", "changes_requested"].includes(snapshot.application.status)) return <div className={`${styles.profile} owner-profile`}><PortalWizard eventSlug={eventSlug} /></div>;
  if (!snapshot.portal) return <div className={styles.cockpit}><section className={styles.card}><Clock className={styles.cardIcon} aria-hidden="true" /><p className={styles.eyebrow}>Jullie aanmelding</p><h2>Aanmelding in beoordeling</h2><p>De organisatie bekijkt jullie idee. Je kunt de gegevens hieronder ondertussen blijven bijwerken; gewijzigde gegevens worden opnieuw beoordeeld.</p>{snapshot.application.reviewFeedback && <div className="form-warning">Terugkoppeling: {snapshot.application.reviewFeedback}</div>}</section><div className={`${styles.profile} owner-profile`}><PortalWizard eventSlug={eventSlug} /></div></div>;
  const portal = snapshot.portal;
  const warnings = Object.entries(snapshot.application.draft.warnings as Record<string, boolean> | undefined ?? {}).filter(([, enabled]) => enabled).map(([key]) => warningLabels[key] ?? key);
  const accessibility = String(snapshot.application.draft.accessibility ?? "unknown");
  const accessibilityNotes = String(snapshot.application.draft.accessibilityNotes ?? "").trim();
  const draft = snapshot.application.draft;
  const address = draft.address && typeof draft.address === "object" ? draft.address as Record<string, unknown> : {};
  const privateAddress = [address.street, address.houseNumber, address.addition, address.postalCode].filter((value) => typeof value === "string" && value.trim()).join(" ");
  const contactName = typeof draft.contactName === "string" ? draft.contactName : "";
  const phone = typeof draft.phone === "string" ? draft.phone : "";
  const email = typeof draft.email === "string" ? draft.email : "";
  const worldIndex = worlds.findIndex((world) => world.name === portal.world || world.slug === portal.world);
  const stateHeading = portal.operationStatus === "open" ? "Jullie poort is open." : portal.operationStatus === "paused" ? "Even ruimte voor een pauze." : portal.operationStatus === "closed" ? "Jullie poort is gesloten." : "Klaar om de wijk te ontvangen?";
  return <div className={`${styles.cockpit} homeowner-cockpit`}>
    <div className={`${styles.overview} owner-overview`}>
      <section className={`${styles.card} owner-status-card`} aria-labelledby="owner-status-heading">
        <div className={styles.statusHead}><DoorOpen className={styles.statusIcon} aria-hidden="true" /><span className={styles.state} data-state={portal.operationStatus}>{operationLabels[portal.operationStatus]}</span></div>
        <p className={styles.eyebrow}>Vanavond · jullie ontvangst</p><h2 id="owner-status-heading">{stateHeading}</h2>
        <p>Laat weten wanneer jullie gasten kunnen ontvangen. Bij pauze of sluiting krijgt jullie poort geen nieuwe groepen toegewezen.</p>
        <div className={`${styles.actions} owner-state-actions`} aria-label="Ontvangststatus wijzigen">
          <button className="btn outline" data-state="open" aria-pressed={portal.operationStatus === "open"} disabled={statePending || portal.operationStatus === "open"} onClick={() => void setState("open")}><Check aria-hidden="true" />Open</button>
          <button className="btn outline" data-state="paused" aria-pressed={portal.operationStatus === "paused"} disabled={statePending || portal.operationStatus === "paused"} onClick={() => void setState("paused")}><Pause aria-hidden="true" />Pauze</button>
          <button className="btn outline" data-state="closed" aria-pressed={portal.operationStatus === "closed"} disabled={statePending || portal.operationStatus === "closed"} onClick={() => void setState("closed")}><DoorOpen aria-hidden="true" />Gesloten</button>
        </div>
        <p className={styles.statusNote}><ShieldCheck aria-hidden="true" />Begeleid een groep die al binnen is rustig naar de afronding. Bij twijfel kun je direct hulp vragen aan de organisatie.</p>
        {portal.nextArrival && <p className={styles.statusNote}><Clock aria-hidden="true" />Volgend gepland venster · geen live ETA: <strong>{new Date(portal.nextArrival).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</strong></p>}
      </section>
      <section className={`${styles.art} owner-world-card`} aria-label="Jullie poort">
        <img src={worldIndex >= 0 ? `/images/world-${worldIndex}.webp` : "/images/pluvierstraat.webp"} alt="" />
        {portal.systemCode && <span className={styles.code}>{portal.systemCode}</span>}
        <div><p className={styles.eyebrow}><Sparkles aria-hidden="true" />{portal.world}</p><h2>{portal.name}</h2><p>{portal.description || "Een eigen verhaal achter jullie deur. Jullie geven de avond kleur."}</p></div>
      </section>
    </div>
    {notice && <p className={styles.notice} role="status">{notice}</p>}
    <PortalForecast portalId={portal.id} systemCode={portal.systemCode} name={portal.name} operationStatus={portal.operationStatus} />
    <div className={`${styles.details} owner-details-grid`}>
      <section className={`${styles.card} owner-safety-card`}><ShieldCheck className={styles.cardIcon} aria-hidden="true" /><p className={styles.eyebrow}>Goed voorbereid</p><h2>Veilig ontvangen</h2><p><span className={styles.factLabel}>Praktische toegankelijkheid</span>{accessibility ? accessibilityLabels[accessibility] ?? accessibility : "Niet ingevuld"}</p>{accessibilityNotes && <p>{accessibilityNotes}</p>}
        {warnings.length > 0 ? <ul className={styles.facts}>{warnings.map((warning) => <li key={warning}><AlertTriangle aria-hidden="true" />{warning}</li>)}</ul> : <p>Geen bijzondere effecten of allergenen opgegeven.</p>}
        <div className={`${styles.contact} owner-private-contact`}>
          <div><MapPin aria-hidden="true" /><span><small>Jullie adres</small><strong>{privateAddress || "Nog niet ingevuld"}</strong></span></div>
          <div><UserRound aria-hidden="true" /><span><small>Contactpersoon</small><strong>{contactName || "Nog niet ingevuld"}</strong></span></div>
          {phone && <div><Phone aria-hidden="true" /><span><small>Telefoonnummer</small><a href={`tel:${phone.replace(/\s/g, "")}`}>{phone}</a></span></div>}
          {email && <div><Mail aria-hidden="true" /><span><small>E-mailadres</small><a href={`mailto:${email}`}>{email}</a></span></div>}
        </div>
      </section>
      <section className={`${styles.card} owner-scan-card`}><QrCode className={styles.cardIcon} aria-hidden="true" /><p className={styles.eyebrow}>Bij aankomst</p><h2>Bezoekscan en scanmateriaal</h2><p>{portal.hasCredential ? "Laat de groepsleider jullie bezoekcode scannen. Daarmee bevestigt de groep het bezoek aan deze poort." : "Maak na goedkeuring een eerste QR-code en korte bezoekcode voor de groepsleider."}</p>
        <p className={styles.credentialNote}>{portal.hasCredential ? "Vervangen maakt alle eerdere codes direct ongeldig. Doe dit alleen als het materiaal kwijt, beschadigd of mogelijk gedeeld is." : "Het geheime scanmateriaal wordt maar één keer getoond. Download het meteen nadat je het hebt aangemaakt."}</p>
        <button className={`btn outline ${styles.credentialButton}`} onClick={() => void rotateCredential()}><RefreshCw aria-hidden="true" />{portal.hasCredential ? "QR en bezoekcode vervangen" : "Eerste QR en bezoekcode maken"}</button>
        {credentialMaterial && <div className={styles.credentialSheet}><h3>Bezoekcode versie {credentialMaterial.credentialVersion}</h3><img src={credentialMaterial.qrDataUrl} alt={`Nieuwe QR-code voor ${portal.name}`} /><p>Korte bezoekcode</p><div className="registration-code">{credentialMaterial.shortCode}</div><div className="actions"><a className="btn" href={credentialMaterial.qrDataUrl} download={`duindorp-poort-${credentialMaterial.credentialVersion}.png`}><Download aria-hidden="true" />Download PNG</a><button className="btn outline" onClick={() => setCredentialMaterial(null)}>Verwijder van scherm</button></div></div>}
      </section>
    </div>
    <div className={`${styles.profile} owner-profile`}><PortalWizard eventSlug={eventSlug} /></div>
  </div>;
}
