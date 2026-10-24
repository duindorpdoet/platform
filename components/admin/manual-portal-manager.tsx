"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Archive, Edit3, Plus, Save, ShieldAlert, Trash2, UserPlus, X } from "lucide-react";
import { amsterdamDateTimeInput, amsterdamInputToIso } from "@/lib/time/amsterdam";
import { LocationEditor } from "@/components/admin/location-editor";
import { useDialogFocus } from "@/lib/ui/use-dialog-focus";
import { createClient } from "@/lib/supabase/client";
import {withRequestDeadline} from "@/lib/redesign/request-deadline";
import {VisitInformationFields,visitInformationDraft,type VisitInformationDraft} from "@/components/portal/visit-information";

type World = { id: string; slug: string; name: string };
type Portal = {
  visitInformation?:Partial<VisitInformationDraft>;
  walkingConnectionVerified?:boolean; id: string; systemCode: string; name: string; world: string; worldSlug: string; color: string | null; description: string;
  lifecycleStatus: "concept" | "registered" | "approved" | "active" | "archived"; approvalStatus: Draft["approvalStatus"]; operationStatus: string;
  recordSource: "resident_registration" | "manual"; contactName: string | null; phone: string | null; email: string | null;
  street: string | null; houseNumber: string | null; addition: string | null; intensity: number; accessibilityNotes: string | null; internalNotes: string | null; visitMinutes: number | null; bufferMinutes: number | null; windowCount: number; address: string | null; postalCode: string | null; city: string | null; geocodedLatitude: number | null; geocodedLongitude: number | null;
  latitude: number | null; longitude: number | null; plannedOpensAt: string | null; plannedClosesAt: string | null;
  maxGroups: number | null; maxChildren: number | null; candidateStartPoint: boolean; isFinal: boolean; version: number;
};
type Draft = {
  visitInformation:VisitInformationDraft;
  id: string | null; version: number | null; systemNumber: string; name: string; worldSlug: string; color: string;
  description: string; intensity: string; street: string; houseNumber: string; addition: string; postalCode: string; city: string;
  latitude: string; longitude: string; contactName: string; contactPhone: string; contactEmail: string;
  plannedOpensAt: string; plannedClosesAt: string; maxGroups: string; maxChildren: string; visitMinutes: string; bufferMinutes: string;
  accessibilityNotes: string; internalNotes: string; lifecycleStatus: Portal["lifecycleStatus"];
  approvalStatus: "draft" | "submitted" | "changes_requested" | "approved" | "rejected" | "withdrawn";
  operationStatus: "scheduled" | "open" | "paused" | "closed";
  candidateStartPoint: boolean; isFinal: boolean; confirmFinal: boolean;
};

function commandError(message: string) {
  if (message.includes("STALE_VERSION")) return "Deze poort is intussen gewijzigd. Sluit het formulier en open de poort opnieuw om de nieuwste gegevens te gebruiken.";
  if (message.includes("CHOOSE_REPLACEMENT_FINAL_PORTAL_FIRST")) return "Kies eerst een andere eindpoort in Startregie.";
  if (message.includes("RESOLVE_ACTIVE_ASSIGNMENTS_FIRST")) return "Verplaats eerst de groepen die bij deze poort starten via Startregie.";
  if (message.includes("RESOLVE_ACTIVE_VISITS_FIRST")) return "Deze poort heeft nog gereserveerde bezoeken of groepen onderweg. Handel die eerst af in de livecockpit.";
  if (message.includes("MULTIPLE_AVAILABILITY_WINDOWS")) return "Deze poort heeft meerdere tijdvakken. Laat de geplande beschikbaarheid ongewijzigd om de overige gegevens op te slaan.";
  if (message.includes("PORTAL_CODE_IS_STABLE")) return "Het poortnummer kan na goedkeuring niet meer worden gewijzigd.";
  if (message.includes("NOT_AUTHORIZED")) return "Je hebt geen toestemming om deze poort te beheren.";
  return message;
}
const localDateTime = amsterdamDateTimeInput;
function empty(worlds: World[]): Draft {
  return { visitInformation:visitInformationDraft(),id: null, version: null, systemNumber: "", name: "", worldSlug: worlds[0]?.slug ?? "", color: "#d59658",
    description: "", intensity: "1", street: "", houseNumber: "", addition: "", postalCode: "", city: "Den Haag",
    latitude: "", longitude: "", contactName: "", contactPhone: "", contactEmail: "", plannedOpensAt: "", plannedClosesAt: "",
    maxGroups: "1", maxChildren: "20", visitMinutes: "5", bufferMinutes: "2", accessibilityNotes: "", internalNotes: "",
    lifecycleStatus: "concept", approvalStatus: "draft", operationStatus: "scheduled", candidateStartPoint: false, isFinal: false, confirmFinal: false };
}
function fromPortal(portal: Portal): Draft {
  const number = portal.systemCode.match(/\d+/)?.[0] ?? "";
  return { ...empty([]), visitInformation:visitInformationDraft(portal.visitInformation), id: portal.id, version: portal.version, systemNumber: number, name: portal.name, worldSlug: portal.worldSlug,
    color: portal.color ?? "#d59658", description: portal.description, street: portal.street ?? "", houseNumber: portal.houseNumber ?? "", addition: portal.addition ?? "",
    intensity: String(portal.intensity), accessibilityNotes: visitInformationDraft(portal.visitInformation).accessibilityNotes, internalNotes: portal.internalNotes ?? "",
    visitMinutes: String(portal.visitMinutes ?? 5), bufferMinutes: String(portal.bufferMinutes ?? 2),
    postalCode: portal.postalCode ?? "", city: portal.city ?? "Den Haag", latitude: portal.latitude?.toString() ?? "",
    longitude: portal.longitude?.toString() ?? "", contactName: portal.contactName ?? "", contactPhone: portal.phone ?? "",
    contactEmail: portal.email ?? "", plannedOpensAt: localDateTime(portal.plannedOpensAt), plannedClosesAt: localDateTime(portal.plannedClosesAt),
    maxGroups: String(portal.maxGroups ?? 1), maxChildren: String(portal.maxChildren ?? 20), lifecycleStatus: portal.lifecycleStatus,
    approvalStatus: portal.approvalStatus,
    operationStatus: portal.operationStatus as Draft["operationStatus"],
    candidateStartPoint: portal.candidateStartPoint, isFinal: portal.isFinal };
}

export function ManualPortalManager({ eventSlug, worlds, onChanged, initialPortalId }: { eventSlug: string; worlds: World[]; onChanged: () => void; initialPortalId?: string }) {
  const openedInitial = useRef(false);
  const [portals, setPortals] = useState<Portal[]>([]);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [notice, setNotice] = useState("");
  const [timeError,setTimeError] = useState("");
  const [busy, setBusy] = useState(false);
  useDialogFocus(Boolean(draft),".manual-portal-editor",()=>setDraft(null),busy);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_portal_editor_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("De poorten konden niet worden opgehaald.");
    const rows = (data as { portals: Portal[] }).portals;
    setPortals(rows);
    if (initialPortalId && !openedInitial.current) {
      openedInitial.current = true;
      const portal = rows.find((row) => row.id === initialPortalId);
      if (portal) setDraft(fromPortal(portal));
    }
  }, [eventSlug, initialPortalId]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function save() {
    if (!draft || busy) return;
    setTimeError("");
    const original = portals.find((portal) => portal.id === draft.id);
    const plannedOpensAt = original && draft.plannedOpensAt === localDateTime(original.plannedOpensAt)
      ? original.plannedOpensAt : draft.plannedOpensAt ? amsterdamInputToIso(draft.plannedOpensAt) : null;
    const plannedClosesAt = original && draft.plannedClosesAt === localDateTime(original.plannedClosesAt)
      ? original.plannedClosesAt : draft.plannedClosesAt ? amsterdamInputToIso(draft.plannedClosesAt) : null;
    if (draft.plannedOpensAt && !plannedOpensAt) {
      setTimeError("De openingstijd is geen eenduidig Nederlands tijdstip. Kies een geldige datum en tijd; een overgeslagen of dubbel uur bij de zomer-/wintertijdwisseling kan niet worden opgeslagen.");
      return;
    }
    if (draft.plannedClosesAt && !plannedClosesAt) {
      setTimeError("De sluitingstijd is geen eenduidig Nederlands tijdstip. Kies een geldige datum en tijd; een overgeslagen of dubbel uur bij de zomer-/wintertijdwisseling kan niet worden opgeslagen.");
      return;
    }
    if (plannedOpensAt && plannedClosesAt && Date.parse(plannedClosesAt) <= Date.parse(plannedOpensAt)) {
      setTimeError("De sluitingstijd moet na de openingstijd liggen. Alle tijden worden verwerkt als Nederlandse tijd (Europe/Amsterdam).");
      return;
    }
    const client = createClient(); if (!client) return;
    setBusy(true);
    const payload = {
      ...draft,
      systemNumber: draft.systemNumber ? Number(draft.systemNumber) : null,
      intensity: Number(draft.intensity), latitude: draft.latitude ? Number(draft.latitude) : null,
      longitude: draft.longitude ? Number(draft.longitude) : null,
      plannedOpensAt,
      plannedClosesAt,
      maxGroups: Number(draft.maxGroups), maxChildren: Number(draft.maxChildren),
      visitMinutes: Number(draft.visitMinutes), bufferMinutes: Number(draft.bufferMinutes),
    };
    try {
    const { error } = await withRequestDeadline(client.schema("api").rpc("admin_manual_portal_save", {
      _event_slug: eventSlug, _portal_id: draft.id, _payload: payload, _expected_version: draft.version,
      _reason: draft.id ? "Poortgegevens bijgewerkt door de organisatie" : "Poort handmatig door de organisatie toegevoegd",
    }));
    if (error?.message.includes("STALE_VERSION")) await load();
    if (error) setTimeError(`Opslaan geweigerd: ${commandError(error.message)}`);
    else setNotice(draft.id ? "Poort bijgewerkt." : "Poort aangemaakt met een stabiele poortcode.");
    if (!error) { setDraft(null); await load(); onChanged(); }
    }catch{setTimeError("Er kwam geen bevestiging terug. Je ingevulde gegevens blijven staan. Open de actuele poort opnieuw voordat je nogmaals opslaat.");}finally{setBusy(false); }
  }

  async function remove(portal: Portal) {
    if (busy) return;
    if (!window.confirm(`${portal.systemCode} · ${portal.name} verwijderen? De poort verdwijnt uit het actieve beheer. Bestaande aanmeldingen, teams en bezoekhistorie blijven bewaard door archivering. Een ongebruikte handmatige conceptpoort wordt permanent verwijderd. Verwijderen wordt geblokkeerd zolang groepen of de eindpoortconfiguratie deze poort gebruiken.`)) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("admin_manual_portal_remove", {
      _portal_id: portal.id, _expected_version: portal.version, _reason: "Poort verwijderd uit actief beheer door de organisatie",
    });
    setBusy(false);
    if (error?.message.includes("STALE_VERSION")) await load();
    const result = data as { deleted?: boolean } | null;
    setNotice(error ? `Actie geblokkeerd: ${commandError(error.message)}` : result?.deleted ? "Ongebruikte conceptpoort permanent verwijderd." : "Poort gearchiveerd; historische relaties zijn bewaard.");
    if (error && draft) setTimeError(`Verwijderen geblokkeerd: ${commandError(error.message)}`);
    if (!error) { setDraft(null); await load(); onChanged(); }
  }

  async function setStartPoint(portal: Portal, enabled: boolean) {
    const client = createClient(); if (!client || busy) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_portal_start_point_set", {
      _portal_id: portal.id, _enabled: enabled, _expected_version: portal.version,
    });
    setBusy(false);
    setNotice(error ? commandError(error.message) : `Startpunt voor ${portal.systemCode}: ${enabled ? "ja" : "nee"}.`);
    await load(); onChanged();
  }

  async function inviteOwner(portal: Portal) {
    const email = window.prompt(`E-mailadres van de toekomstige eigenaar van ${portal.systemCode}:`)?.trim().toLowerCase();
    if (!email) return;
    const firstName = window.prompt("Voornaam (optioneel):")?.trim() ?? "";
    const client = createClient(); if (!client) return;
    setBusy(true);
    const { error } = await client.schema("api").rpc("portal_team_command", {
      _portal_id: portal.id, _operation: "invite", _payload: { email, firstName, lastName: "", role: "coadmin" }, _key: crypto.randomUUID(),
    });
    setBusy(false);
    setNotice(error ? `Uitnodiging geweigerd: ${error.message}` : "Uitnodiging verstuurd via de bestaande poortteamflow. Het poortrecord blijft ongewijzigd.");
  }

  return <div className="manual-portal-manager">
    <header><div><p className="kicker">Organisatiebeheer</p><h3>Poorten beheren</h3><p>Bewerk gegevens van aangemelde en handmatig toegevoegde poorten of verwijder een poort uit het actieve beheer. De oorspronkelijke aanmelding en bezoekhistorie blijven bewaard.</p></div><button className="btn" type="button" onClick={() => { setTimeError(""); setDraft(empty(worlds)); }}><Plus />Poort toevoegen</button></header>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    <div className="manual-portal-list">{portals.map((portal) => <article key={portal.id}>
      <header><span className="portal-code">{portal.systemCode}</span><div><strong>{portal.name}</strong><small>{portal.world} · {portal.recordSource === "manual" ? "Handmatig toegevoegd" : "Bewonersaanmelding"} · {portal.lifecycleStatus} · live: {portal.operationStatus}</small></div>{portal.isFinal && <span className="portal-status-badge">Eindpoort</span>}</header>
      <dl><div><dt>Beschikbaar</dt><dd>{portal.plannedOpensAt ? `${localDateTime(portal.plannedOpensAt).slice(11)}–${localDateTime(portal.plannedClosesAt).slice(11)}` : "Nog niet gepland"}</dd></div><div><dt>Locatie</dt><dd>{portal.latitude!==null?"Locatie ingevuld":"Locatie ontbreekt"}</dd></div><div><dt>Contact</dt><dd>{portal.contactName || "Niet ingevuld"}</dd></div></dl>
      <div className="actions"><label className="field"><span>Startpunt</span><select aria-label={`Startpunt voor ${portal.systemCode}`} value={portal.candidateStartPoint ? "yes" : "no"} disabled={busy} onChange={(event) => void setStartPoint(portal,event.target.value === "yes")}><option value="no">Nee</option><option value="yes">Ja</option></select></label><button className="btn outline" type="button" disabled={busy} onClick={() => { setTimeError(""); setDraft(fromPortal(portal)); }}><Edit3 />Bewerken</button>{portal.recordSource === "manual" && ["approved", "active"].includes(portal.lifecycleStatus) && <button className="btn outline" type="button" disabled={busy} onClick={() => void inviteOwner(portal)}><UserPlus />Eigenaar uitnodigen</button>}<button className="text-link danger" type="button" disabled={busy} onClick={() => void remove(portal)}>{portal.lifecycleStatus === "concept" ? <Trash2 /> : <Archive />}Verwijderen</button></div>
    </article>)}{portals.length === 0 && <div className="portal-empty"><ShieldAlert /><p>Er zijn nog geen poorten om te beheren.</p></div>}</div>

    {draft && <div className="manual-portal-backdrop" role="presentation" onMouseDown={(event) => { if (!busy && event.target === event.currentTarget) setDraft(null); }}><aside className="manual-portal-editor" role="dialog" aria-modal="true" aria-labelledby="manual-portal-title">
      <header><div><p className="kicker">{draft.id ? "Poort bewerken" : "Nieuwe poort"}</p><h3 id="manual-portal-title">{draft.name || "Handmatig registreren"}</h3></div><button type="button" className="icon-button" aria-label="Sluiten" disabled={busy} onClick={() => setDraft(null)}><X /></button></header>
      <div className="manual-portal-editor-body">
        <section><h4>Identiteit</h4><div className="settings-grid"><label className="field"><span>Voorgesteld poortnummer</span><input type="number" min={1} value={draft.systemNumber} disabled={Boolean(draft.id && !["concept", "registered"].includes(draft.lifecycleStatus))} onChange={(event) => setDraft({ ...draft, systemNumber: event.target.value })} placeholder="Automatisch" /><small>Alleen vóór goedkeuring aanpasbaar.</small></label><label className="field"><span>Poortnaam</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label className="field"><span>Wereld</span><select value={draft.worldSlug} onChange={(event) => setDraft({ ...draft, worldSlug: event.target.value })}>{worlds.map((world) => <option key={world.id} value={world.slug}>{world.name}</option>)}</select></label><label className="field"><span>Kleur</span><input type="color" value={draft.color} onChange={(event) => setDraft({ ...draft, color: event.target.value })} /></label><label className="field"><span>Spanningsniveau</span><input type="number" min={1} max={4} value={draft.intensity} onChange={(event) => setDraft({ ...draft, intensity: event.target.value })} /></label><label className="field"><span>Lifecycle-status</span><select value={draft.lifecycleStatus} onChange={(event) => setDraft({ ...draft, lifecycleStatus: event.target.value as Draft["lifecycleStatus"] })}><option value="concept">Concept</option><option value="registered">Aangemeld</option><option value="approved">Goedgekeurd</option><option value="active">Actief</option></select></label><label className="field"><span>Goedkeuringsstatus</span><select value={draft.approvalStatus} onChange={(event) => setDraft({ ...draft, approvalStatus: event.target.value as Draft["approvalStatus"] })}><option value="draft">Conceptcontrole</option><option value="submitted">In beoordeling</option><option value="changes_requested">Aanpassing gevraagd</option><option value="approved">Goedgekeurd</option><option value="rejected">Afgewezen</option><option value="withdrawn">Teruggetrokken</option></select></label><label className="field wide"><span>Omschrijving</span><textarea value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label></div></section>
        <section><h4>Adres en routingmarker</h4><div className="settings-grid"><label className="field"><span>Straat</span><input value={draft.street} onChange={(event) => setDraft({ ...draft, street: event.target.value })} /></label><label className="field"><span>Huisnummer</span><input value={draft.houseNumber} onChange={(event) => setDraft({ ...draft, houseNumber: event.target.value })} /></label><label className="field"><span>Toevoeging</span><input value={draft.addition} onChange={(event) => setDraft({ ...draft, addition: event.target.value })} /></label><label className="field"><span>Postcode</span><input value={draft.postalCode} onChange={(event) => setDraft({ ...draft, postalCode: event.target.value })} /></label><label className="field"><span>Plaats</span><input value={draft.city} onChange={(event) => setDraft({ ...draft, city: event.target.value })} /></label></div><LocationEditor label={draft.name || "Nieuwe poort"} markerKind={draft.isFinal ? "final" : "portal"} color={draft.color} coordinate={draft.longitude && draft.latitude ? [Number(draft.longitude), Number(draft.latitude)] : null} addressCoordinate={draft.longitude && draft.latitude ? [Number(draft.longitude), Number(draft.latitude)] : null} onSave={(change) => setDraft({ ...draft, latitude: String(change.latitude), longitude: String(change.longitude) })} /></section>
        <section><h4>Contact en toegankelijkheid</h4><div className="settings-grid"><label className="field"><span>Contactpersoon</span><input value={draft.contactName} onChange={(event) => setDraft({ ...draft, contactName: event.target.value })} /></label><label className="field"><span>Telefoonnummer</span><input value={draft.contactPhone} onChange={(event) => setDraft({ ...draft, contactPhone: event.target.value })} /></label><label className="field"><span>E-mailadres</span><input type="email" value={draft.contactEmail} onChange={(event) => setDraft({ ...draft, contactEmail: event.target.value })} /></label></div></section>
        <section><VisitInformationFields value={draft.visitInformation} onChange={visitInformation=>setDraft({...draft,accessibilityNotes:visitInformation.accessibilityNotes,visitInformation})}/></section>
        <section><h4>Geplande beschikbaarheid</h4>{draft.id && (portals.find((portal) => portal.id === draft.id)?.windowCount ?? 0) > 1 && <p>Deze poort heeft meerdere tijdvakken. Bestaande tijdvakken blijven behouden; pas hier alleen de overige poortgegevens aan.</p>}<div className="settings-grid"><label className="field"><span>Live avondstatus</span><select value={draft.operationStatus} onChange={(event) => setDraft({ ...draft, operationStatus: event.target.value as Draft["operationStatus"] })}><option value="scheduled">Onbekend / nog niet gestart</option><option value="open">Open</option><option value="paused">Pauze</option><option value="closed">Gestopt</option></select></label><label className="field"><span>Opent</span><input type="datetime-local" value={draft.plannedOpensAt} onChange={(event) => setDraft({ ...draft, plannedOpensAt: event.target.value })} /></label><label className="field"><span>Sluit</span><input type="datetime-local" value={draft.plannedClosesAt} onChange={(event) => setDraft({ ...draft, plannedClosesAt: event.target.value })} /></label><label className="field"><span>Groepen tegelijk</span><input type="number" min={1} value={draft.maxGroups} onChange={(event) => setDraft({ ...draft, maxGroups: event.target.value })} /></label><label className="field"><span>Kinderen per bezoek</span><input type="number" min={1} value={draft.maxChildren} onChange={(event) => setDraft({ ...draft, maxChildren: event.target.value })} /></label><label className="field"><span>Bezoekduur</span><input type="number" min={1} value={draft.visitMinutes} onChange={(event) => setDraft({ ...draft, visitMinutes: event.target.value })} /></label><label className="field"><span>Buffer</span><input type="number" min={0} value={draft.bufferMinutes} onChange={(event) => setDraft({ ...draft, bufferMinutes: event.target.value })} /></label></div></section>
        <section><h4>Beheer</h4><label className="field"><span>Interne notities</span><textarea value={draft.internalNotes} onChange={(event) => setDraft({ ...draft, internalNotes: event.target.value })} /></label><label className="field"><span>Startpunt</span><select value={draft.candidateStartPoint ? "yes" : "no"} onChange={(event) => setDraft({ ...draft, candidateStartPoint: event.target.value === "yes" })}><option value="no">Nee</option><option value="yes">Ja</option></select></label><label className="check-row"><input type="checkbox" checked={draft.isFinal} onChange={(event) => setDraft({ ...draft, isFinal: event.target.checked, confirmFinal: false })} /><span>Instellen als eindpoort</span></label>{draft.isFinal && <label className="check-row critical"><input type="checkbox" checked={draft.confirmFinal} onChange={(event) => setDraft({ ...draft, confirmFinal: event.target.checked })} /><span>Ik begrijp dat dit de eindpoortconfiguratie wijzigt.</span></label>}</section>
      </div>
      {timeError && <p className="form-warning" role="alert">{timeError}</p>}<footer>{draft.id && <button className="text-link danger" type="button" disabled={busy} onClick={() => { const portal = portals.find((item) => item.id === draft.id); if (portal) void remove(portal); }}><Trash2 />Poort verwijderen</button>}<button className="btn outline" disabled={busy} type="button" onClick={() => setDraft(null)}>Annuleren</button><button className="btn" type="button" disabled={busy || draft.name.trim().length < 2 || !draft.worldSlug || (draft.lifecycleStatus === "active" && (draft.approvalStatus !== "approved" || !draft.latitude || !draft.plannedOpensAt || !draft.plannedClosesAt)) || (draft.isFinal && !draft.confirmFinal)} onClick={() => void save()}><Save />Poort opslaan</button></footer>
    </aside></div>}
  </div>;
}
