"use client";

import { portalInstructionStatusLabel } from "@/lib/domain/portal-instructions";
import { portalEditorSystemNumber, portalNumberIsEditable } from "@/lib/domain/portal-editor-identity";

import { useCallback, useEffect, useRef, useState } from "react";
import { Archive, Edit3, Plus, Save, ShieldAlert, Trash2, UserPlus, X } from "lucide-react";
import { amsterdamDateTimeInput, amsterdamInputToIso } from "@/lib/time/amsterdam";
import { locationCoordinate, locationError } from "@/lib/domain/location-readiness";
import { LocationEditor, type LocationSave } from "@/components/admin/location-editor";
import { useDialogFocus } from "@/lib/ui/use-dialog-focus";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { useSnapshotRefresh } from "@/lib/realtime/use-snapshot-refresh";
import { AdminDialog } from "./admin-dialog";
import { createClient } from "@/lib/supabase/client";

type PortalImpact = {inputHash:string;draftGroups:Array<{code:string;startsAt:string}>;publishedGroups:Array<{code:string;startsAt:string}>;confirmedGroups:Array<{code:string;startsAt:string}>;pendingStops:number;reservations:number;finale:boolean};
type World = { id: string; slug: string; name: string };
type Portal = {
  instructionStatus?: string | null;
  publicEntranceInstructions?: string | null;
  maintenanceDraft?: Partial<Draft> | null;
  locationSource: "address" | "manual"; walkingConnectionVerified?:boolean; id: string; systemCode: string; name: string; world: string; worldSlug: string; color: string | null; description: string;
  lifecycleStatus: "concept" | "registered" | "approved" | "active" | "archived"; approvalStatus: Draft["approvalStatus"]; operationStatus: string;
  recordSource: "resident_registration" | "manual"; contactName: string | null; phone: string | null; email: string | null;
  street: string | null; houseNumber: string | null; addition: string | null; intensity: number; accessibilityNotes: string | null; internalNotes: string | null; visitMinutes: number | null; bufferMinutes: number | null; windowCount: number; address: string | null; postalCode: string | null; city: string | null; geocodedLatitude: number | null; geocodedLongitude: number | null;
  latitude: number | null; longitude: number | null; plannedOpensAt: string | null; plannedClosesAt: string | null;
  maxGroups: number | null; maxChildren: number | null; candidateStartPoint: boolean; isFinal: boolean; version: number;
};
type Draft = {
  routingMarker: LocationSave | null;
  id: string | null; version: number | null; systemNumber: string; name: string; worldSlug: string; color: string;
  description: string; publicEntranceInstructions: string; intensity: string; street: string; houseNumber: string; addition: string; postalCode: string; city: string;
  latitude: string; longitude: string; contactName: string; contactPhone: string; contactEmail: string;
  plannedOpensAt: string; plannedClosesAt: string; maxGroups: string; maxChildren: string; visitMinutes: string; bufferMinutes: string;
  accessibilityNotes: string; internalNotes: string; lifecycleStatus: Portal["lifecycleStatus"];
  approvalStatus: "draft" | "submitted" | "changes_requested" | "approved" | "rejected" | "withdrawn";
  operationStatus: "scheduled" | "open" | "paused" | "closed";
  candidateStartPoint: boolean; isFinal: boolean; confirmFinal: boolean;
};

function commandError(message: string) {
  const location = locationError(message); if (location) return location;
  if (message.includes("STALE_VERSION")) return "Deze poort is intussen gewijzigd. Sluit het formulier en open de poort opnieuw om de nieuwste gegevens te gebruiken.";
  if (message.includes("EXACTLY_ONE_PRIMARY_OWNER")) return "Sla deze poort eerst als concept op. Laat de geadresseerde de persoonlijke instructie-uitnodiging met het juiste e-mailadres bevestigen; daarna kun je de poort goedkeuren en activeren.";
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
  return { routingMarker: null, id: null, version: null, systemNumber: "", name: "", worldSlug: worlds[0]?.slug ?? "", color: "#d59658",
    description: "", publicEntranceInstructions: "", intensity: "1", street: "", houseNumber: "", addition: "", postalCode: "", city: "Den Haag",
    latitude: "", longitude: "", contactName: "", contactPhone: "", contactEmail: "", plannedOpensAt: "", plannedClosesAt: "",
    maxGroups: "1", maxChildren: "20", visitMinutes: "5", bufferMinutes: "2", accessibilityNotes: "", internalNotes: "",
    lifecycleStatus: "concept", approvalStatus: "draft", operationStatus: "scheduled", candidateStartPoint: false, isFinal: false, confirmFinal: false };
}
function fromPortal(portal: Portal): Draft {
  const number = portalEditorSystemNumber(portal);
  const base: Draft = { ...empty([]), id: portal.id, version: portal.version, systemNumber: number, name: portal.name, worldSlug: portal.worldSlug,
    color: portal.color ?? "#d59658", description: portal.description, publicEntranceInstructions: portal.publicEntranceInstructions ?? "", street: portal.street ?? "", houseNumber: portal.houseNumber ?? "", addition: portal.addition ?? "",
    intensity: String(portal.intensity), accessibilityNotes: portal.accessibilityNotes ?? "", internalNotes: portal.internalNotes ?? "",
    visitMinutes: String(portal.visitMinutes ?? 5), bufferMinutes: String(portal.bufferMinutes ?? 2),
    postalCode: portal.postalCode ?? "", city: portal.city ?? "Den Haag", latitude: (portal.geocodedLatitude ?? (portal.locationSource === "address" ? portal.latitude : null))?.toString() ?? "",
    longitude: (portal.geocodedLongitude ?? (portal.locationSource === "address" ? portal.longitude : null))?.toString() ?? "", contactName: portal.contactName ?? "", contactPhone: portal.phone ?? "",
    contactEmail: portal.email ?? "", plannedOpensAt: localDateTime(portal.plannedOpensAt), plannedClosesAt: localDateTime(portal.plannedClosesAt),
    maxGroups: String(portal.maxGroups ?? 1), maxChildren: String(portal.maxChildren ?? 20), lifecycleStatus: portal.lifecycleStatus,
    approvalStatus: portal.approvalStatus,
    operationStatus: portal.operationStatus as Draft["operationStatus"],
    candidateStartPoint: portal.candidateStartPoint, isFinal: portal.isFinal };
  // Hydrate real form fields only; request metadata never survives a fresh preview.
  const saved = portal.maintenanceDraft ? Object.fromEntries(Object.entries(portal.maintenanceDraft).filter(([key]) => Object.hasOwn(base,key))) as Partial<Draft> : null;
  if (!saved || portal.lifecycleStatus === "archived") return base;
  return {...base,...saved,id:portal.id,version:portal.version,
    plannedOpensAt: localDateTime(Object.hasOwn(saved,"plannedOpensAt") ? saved.plannedOpensAt??null : portal.plannedOpensAt),plannedClosesAt:localDateTime(Object.hasOwn(saved,"plannedClosesAt") ? saved.plannedClosesAt??null : portal.plannedClosesAt),
    ...Object.fromEntries(["intensity","latitude","longitude","maxGroups","maxChildren","visitMinutes","bufferMinutes"].map(key => [key, String(Object.hasOwn(saved,key) ? saved[key as keyof Draft]??"" : base[key as keyof Draft]??"")])),
    systemNumber: portalEditorSystemNumber(portal, saved)};
}

export function ManualPortalManager({ eventSlug, worlds, onChanged, initialPortalId, initialFilter = "current" }: { eventSlug: string; worlds: World[]; onChanged: () => void; initialPortalId?: string; initialFilter?: string }) {
  const openedInitial = useRef(false);
  const [topic,setTopic] = useState<string|null>(null);
  const responseSequence = useRef(0);
  const saveCommand = useRef<{body:string;key:string}|null>(null);
  const [change,setChange] = useState<{kind:"save"|"remove";mode?:"draft"|"activate";portal:Portal;impact:PortalImpact;key:string}|null>(null);
  const [portals, setPortals] = useState<Portal[]>([]);
  const [recordFilter,setRecordFilter] = useState(initialFilter);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [notice, setNotice] = useState("");
  const [timeError,setTimeError] = useState("");
  const [stalePortal,setStalePortal] = useState<Portal|null>(null);
  const [busy, setBusy] = useState(false);
  useDialogFocus(Boolean(draft),".manual-portal-editor",()=>setDraft(null),busy);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const ticket=++responseSequence.current;
    const { data, error } = await client.schema("api").rpc("admin_portal_records_snapshot", { _event_slug: eventSlug });
    if(ticket!==responseSequence.current)return;
    if (error) return setNotice("De poorten konden niet worden opgehaald.");
    const source=data as {portals:Portal[];eventId?:string;realtimeTopic?:string};
    setTopic(source.realtimeTopic??(source.eventId?`admin-event:${source.eventId}`:null));
    const rows = source.portals;
    setPortals(rows);
    if (initialPortalId && !openedInitial.current) {
      openedInitial.current = true;
      const portal = rows.find((row) => row.id === initialPortalId);
      if (portal) { if(portal.lifecycleStatus === "archived")setRecordFilter("all"); setDraft(fromPortal(portal)); }
    }
    return rows;
  }, [eventSlug, initialPortalId]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  usePrivateBroadcast(topic,()=>void load());
  useSnapshotRefresh(async()=>{await load();});

  async function save(mode: "draft" | "activate" = "activate", reviewedHash?: string) {
    if (!draft || busy) return;
    if(draft.lifecycleStatus === "archived") { await saveArchive(); return; }
    setTimeError("");
    if(stalePortal && stalePortal.id===draft.id){setTimeError("Laad eerst de actuele poortversie en beoordeel je wijziging opnieuw. Je huidige invoer staat hieronder nog klaar.");return;}
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
    if (mode === "activate" && plannedOpensAt && plannedClosesAt && Date.parse(plannedClosesAt) <= Date.parse(plannedOpensAt)) {
      setTimeError("De sluitingstijd moet na de openingstijd liggen. Alle tijden worden verwerkt als Nederlandse tijd (Europe/Amsterdam).");
      return;
    }
    const client = createClient(); if (!client) return;
    if(original && mode === "activate" && !reviewedHash) {
      const changed = ["lifecycleStatus","approvalStatus","operationStatus","maxGroups","maxChildren","visitMinutes","bufferMinutes"].some(key => String(draft[key as keyof Draft]) !== String(fromPortal(original)[key as keyof Draft])) || draft.plannedOpensAt !== localDateTime(original.plannedOpensAt) || draft.plannedClosesAt !== localDateTime(original.plannedClosesAt);
      if(changed) {
        const result = await client.schema("api").rpc("admin_portal_change_impact",{_portal_id:original.id});
        if(result.error){setTimeError(result.error.message);return;}
        const impact = result.data as PortalImpact;
        if(impact.publishedGroups.length || impact.confirmedGroups.length || impact.pendingStops || impact.reservations) {setChange({kind:"save",mode,portal:original,impact,key:crypto.randomUUID()});return;}
        reviewedHash = impact.inputHash;
      }
    }
    setBusy(true); setNotice("");
    try {
    const payload = {
      ...(reviewedHash ? {impactHash:reviewedHash,impactConfirmed:true} : {}),
      ...draft,
      saveMode: mode,
      lifecycleStatus: mode === "draft" ? original?.lifecycleStatus === "active" ? "active" : "concept" : draft.lifecycleStatus,
      systemNumber: original && !portalNumberIsEditable(original) ? Number(portalEditorSystemNumber(original)) : draft.systemNumber ? Number(draft.systemNumber) : null,
      intensity: Number(draft.intensity), latitude: draft.latitude ? Number(draft.latitude) : null,
      longitude: draft.longitude ? Number(draft.longitude) : null,
      plannedOpensAt,
      plannedClosesAt,
      maxGroups: Number(draft.maxGroups), maxChildren: Number(draft.maxChildren),
      visitMinutes: Number(draft.visitMinutes), bufferMinutes: Number(draft.bufferMinutes),
    };
    const body = JSON.stringify(payload);
    if (saveCommand.current?.body !== body) saveCommand.current = {body,key:crypto.randomUUID()};
    const { data, error } = await client.schema("api").rpc("admin_manual_portal_save", {
      _event_slug: eventSlug, _portal_id: draft.id, _payload: {...payload,commandKey:saveCommand.current.key}, _expected_version: draft.version,
      _reason: draft.id ? "Poortgegevens bijgewerkt door de organisatie" : "Poort handmatig door de organisatie toegevoegd",
    }).abortSignal(AbortSignal.timeout(20_000));
    if (error?.message.includes("STALE_VERSION")) {
      setChange(null);saveCommand.current=null;
      const rows=await load();
      const current=rows?.find(portal=>portal.id===draft.id);
      if(current){
        setStalePortal(current);
        // Invalidate the earlier confirmation and fetch fresh impact. The old
        // draft stays visible until the administrator deliberately reloads it.
        await client.schema("api").rpc("admin_portal_change_impact",{_portal_id:current.id});
      }
    }
    if (error) setTimeError(`Opslaan geweigerd: ${commandError(error.message)}`);
    else if (!data?.id || !Number.isInteger(data.version)) setTimeError("De server heeft de opslag niet bevestigd. Vernieuw en controleer de poort; je invoer is bewaard.");
    else {
      setChange(null);
      const created = !draft.id;
      const concept = data.lifecycleStatus === "concept" || mode === "draft";
      if (created) setRecordFilter(concept ? "concept" : "current");
      const savedMessage = data.draftSaved ? "Onderhoudsconcept bewaard. De live poortstatus is behouden; rond de gegevens af voordat je activeert."
        : concept ? "Conceptpoort opgeslagen." : created ? "Poort aangemaakt." : "Poort bijgewerkt.";
      const mailMessage = created ? data.instructions?.status === "no_email" ? " Geen instructiemail mogelijk zonder e-mailadres."
        : " De instructiemail is aangevraagd. De actuele verzendstatus staat hieronder bij de poort." : "";
      setNotice(savedMessage + mailMessage); setDraft(null); await load(); onChanged(); }
    } catch { setTimeError("Opslag niet bevestigd. Controleer de verbinding en probeer opnieuw; je invoer is bewaard."); }
    finally { setBusy(false); }
  }

  async function saveArchive() {
    if(!draft?.id || busy)return;const client=createClient();if(!client)return;
    const payload={name:draft.name,description:draft.description,contactName:draft.contactName,contactPhone:draft.contactPhone,contactEmail:draft.contactEmail,accessibilityNotes:draft.accessibilityNotes,internalNotes:draft.internalNotes};
    const body=JSON.stringify(payload);if(saveCommand.current?.body!==body)saveCommand.current={body,key:crypto.randomUUID()};
    setBusy(true);setTimeError("");
    try {
      const r=await client.schema("api").rpc("admin_archived_portal_save",{_event_slug:eventSlug,_portal_id:draft.id,_payload:payload,_expected_version:draft.version,_reason:"Archiefgegevens door de organisatie gecorrigeerd",_key:saveCommand.current.key}).abortSignal(AbortSignal.timeout(20_000));
      if(r.error){setTimeError(commandError(r.error.message));return;}
      if(!r.data?.id || !r.data.archived){setTimeError("De server heeft de archiefcorrectie niet bevestigd. Controleer de verbinding en probeer opnieuw.");return;}
      setDraft(null);setNotice("Archiefgegevens bijgewerkt.");await load();onChanged();
    }catch{setTimeError("Opslag niet bevestigd. Probeer dezelfde opdracht opnieuw; je invoer is bewaard.");}finally{setBusy(false);}
  }

  async function remove(portal: Portal) {
    if (busy) return;
    const client = createClient(); if (!client) return;
    const impact = await client.schema("api").rpc("admin_portal_change_impact", {_portal_id:portal.id});
    if(impact.error){setNotice(commandError(impact.error.message));return;}
    setChange({kind:"remove",portal,impact:impact.data as PortalImpact,key:crypto.randomUUID()});
  }
  async function confirmRemoval() {
    const client=createClient();if(!client||!change||busy)return;setBusy(true);
    try {
      const r=await client.schema("api").rpc("admin_portal_remove_reviewed",{_portal_id:change.portal.id,_expected_version:change.portal.version,_input_hash:change.impact.inputHash,_reason:"Poort na actuele impactcontrole uit beheer verwijderen",_key:change.key});
      if(r.error){setTimeError(commandError(r.error.message));setNotice(commandError(r.error.message));return;}
      setNotice(r.data.deleted?"Ongebruikt concept permanent verwijderd.":"Poort gearchiveerd; historie behouden.");setChange(null);setDraft(null);await load();onChanged();
    }catch{setNotice("Verwijderen niet bevestigd. Probeer dezelfde opdracht opnieuw.");}finally{setBusy(false);}
  }

  async function setStartPoint(portal: Portal, enabled: boolean) {
    const client = createClient(); if (!client || busy) return;
    if(!enabled){
      const impact=await client.schema("api").rpc("admin_portal_change_impact",{_portal_id:portal.id});
      if(impact.error){setNotice(commandError(impact.error.message));return;}
      if(!window.confirm(`Niet meer als startpunt gebruiken? ${impact.data.draftGroups.length} conceptafspraken en ${impact.data.publishedGroups.length} gepubliceerde afspraken zijn gekoppeld. De gewone poort, QR en historie blijven behouden. Gepubliceerde afspraken blijven geldig tot je ze expliciet vervangt via Startregie.`))return;
    }
    setBusy(true);
    const { error } = await client.schema("api").rpc("admin_portal_start_point_set", {
      _portal_id: portal.id, _enabled: enabled, _expected_version: portal.version,
    });
    setBusy(false);
    setNotice(error ? commandError(error.message) : `Startpunt voor ${portal.systemCode}: ${enabled ? "ja" : "nee"}.`);
    await load(); onChanged();
  }

  const instructionCommand = useRef<{id:string;key:string}|null>(null);
  async function inviteOwner(portal: Portal) {
    const client = createClient(); if (!client || busy) return;
    if (instructionCommand.current?.id !== portal.id) instructionCommand.current = {id:portal.id,key:crypto.randomUUID()};
    setBusy(true);
    try {
      const r = await client.schema("api").rpc("admin_manual_portal_instructions", {_portal_id:portal.id,_expected_version:portal.version,_key:instructionCommand.current.key});
      if(r.error) {setNotice(r.error.message);return;}
      setNotice(r.data.status === "no_email" ? "Geen instructiemail mogelijk zonder e-mailadres. Bewerk de poort." : "Instructiemail aangevraagd. Controleer de actuele verzendstatus bij de poort. De geadresseerde moet de persoonlijke uitnodiging met het juiste e-mailadres bevestigen.");
      instructionCommand.current=null;await load();
    } catch {setNotice("Verzending is niet bevestigd. Probeer dezelfde opdracht opnieuw.");} finally {setBusy(false);}
  }

  const originalDraft = portals.find(portal => portal.id === draft?.id);
  const draftPosition = draft?.routingMarker ? locationCoordinate(draft.routingMarker.longitude, draft.routingMarker.latitude)
    : originalDraft ? locationCoordinate(originalDraft.longitude, originalDraft.latitude)
    : locationCoordinate(draft?.longitude ? Number(draft.longitude) : null, draft?.latitude ? Number(draft.latitude) : null);
  const changesFinalPortal = Boolean(draft?.isFinal && !originalDraft?.isFinal);
  const activationMissing = draft?.lifecycleStatus === "active" ? [
    draft.approvalStatus !== "approved" ? "Kies ‘Goedgekeurd’ bij de goedkeuring." : "",
    !draftPosition ? "Plaats een routingmarker en kies ‘Positie overnemen’." : "",
    !draft.plannedOpensAt || !draft.plannedClosesAt ? "Vul de geplande openings- en sluitingstijd in." : "",
  ].filter(Boolean) : [];

  const visiblePortals = portals.filter(p=>recordFilter==="all" || (recordFilter==="concept" ? p.recordSource==="manual" && ["concept","registered"].includes(p.lifecycleStatus) && !["rejected","withdrawn"].includes(p.approvalStatus) : recordFilter==="archived" ? p.lifecycleStatus==="archived" : p.lifecycleStatus!=="archived"));

  return <div className="manual-portal-manager">
    <header><div><p className="kicker">Organisatiebeheer</p><h3>Poorten beheren</h3><p>Bewerk gegevens van aangemelde en handmatig toegevoegde poorten of verwijder een poort uit het actieve beheer. De oorspronkelijke aanmelding en bezoekhistorie blijven bewaard.</p></div><button className="btn" type="button" onClick={() => { setTimeError(""); setDraft(empty(worlds)); }}><Plus />Poort toevoegen</button></header>
    {change && <AdminDialog labelledBy="manual-portal-impact" close={()=>{if(!busy)setChange(null);}}><h2 id="manual-portal-impact">{change.kind === "remove" ? "Poort verwijderen" : "Bevestigde poortafspraken wijzigen"} · {change.portal.systemCode}</h2><p>{change.impact.draftGroups.length} conceptafspraken · {change.impact.confirmedGroups.length} actuele startbevestigingen · {change.impact.publishedGroups.length} gepubliceerde afspraken · {change.impact.pendingStops} huidige bezoeken · {change.impact.reservations} reserveringen.</p>{[...change.impact.publishedGroups,...change.impact.confirmedGroups].map((g,i)=><p key={i}>{g.code} · {new Date(g.startsAt).toLocaleTimeString("nl-NL",{timeZone:"Europe/Amsterdam",hour:"2-digit",minute:"2-digit"})}</p>)}<p>{change.kind === "remove" ? "Een ongebruikt concept kan worden verwijderd. Andere poorten worden gearchiveerd met behoud van historie. Handel bestaande groepsafspraken, reserveringen en de finale eerst af via Startregie en de livecockpit." : "De server controleert deze actuele impact opnieuw. Ongeldige gepubliceerde afspraken en lopende bezoeken blokkeren de wijziging; vervang die eerst veilig via de regie."}</p>{timeError&&<p role="alert">{timeError}</p>}<div className="actions"><button className="btn outline" type="button" disabled={busy} onClick={()=>setChange(null)}>Annuleren</button><button className="btn" type="button" disabled={busy || (change.kind === "remove" && Boolean(change.impact.finale || change.impact.publishedGroups.length || change.impact.draftGroups.length || change.impact.pendingStops || change.impact.reservations))} onClick={()=>change.kind === "remove" ? void confirmRemoval() : void save(change.mode,change.impact.inputHash)}>{change.kind === "remove" ? "Poort verwijderen bevestigen" : "Poortwijziging bevestigen"}</button></div></AdminDialog>}
    {notice && <div className="form-notice" role="status">{notice}</div>}
    <label className="field"><span>Poortrecords tonen</span><select value={recordFilter} onChange={e=>setRecordFilter(e.target.value)}><option value="current">Niet gearchiveerd</option><option value="concept">Conceptpoorten</option><option value="archived">Gearchiveerd</option><option value="all">Alle statussen</option></select></label>
    <div className="manual-portal-list">{visiblePortals.map((portal) => <article key={portal.id}>
      <header><span className="portal-code">{portal.systemCode}</span><div><strong>{portal.name}</strong><small>{portal.world} · {portal.recordSource === "manual" ? "Handmatig toegevoegd" : "Bewonersaanmelding"} · {portal.lifecycleStatus} · live: {portal.operationStatus}</small></div>{portal.isFinal && <span className="portal-status-badge">Eindpoort</span>}</header>
      <dl><div><dt>Beschikbaar</dt><dd>{portal.plannedOpensAt ? `${localDateTime(portal.plannedOpensAt).slice(11)}–${localDateTime(portal.plannedClosesAt).slice(11)}` : "Nog niet gepland"}</dd></div><div><dt>Locatie</dt><dd>{portal.latitude!==null?"Locatie ingevuld":"Locatie ontbreekt"}</dd></div><div><dt>Contact</dt><dd>{portal.contactName || "Niet ingevuld"}</dd></div></dl>
      <p>Instructiemail: {portalInstructionStatusLabel(portal.instructionStatus, Boolean(portal.email))}</p><div className="actions"><label className="field"><span>Startpunt</span><select aria-label={`Startpunt voor ${portal.systemCode}`} value={portal.candidateStartPoint ? "yes" : "no"} disabled={busy || portal.lifecycleStatus === "archived"} onChange={(event) => void setStartPoint(portal,event.target.value === "yes")}><option value="no">Nee</option><option value="yes">Ja</option></select></label><button className="btn outline" type="button" disabled={busy} onClick={() => { setTimeError(""); setStalePortal(null); setDraft(fromPortal(portal)); }}><Edit3 />Bewerken</button>{portal.recordSource === "manual" && portal.lifecycleStatus !== "archived" && <button className="btn outline" type="button" disabled={busy} onClick={() => void inviteOwner(portal)}><UserPlus />Instructies opnieuw versturen</button>}<button className="text-link danger" type="button" disabled={busy || portal.lifecycleStatus === "archived"} onClick={() => void remove(portal)}>{portal.lifecycleStatus === "concept" ? <Trash2 /> : <Archive />}Verwijderen</button></div>
    </article>)}{visiblePortals.length === 0 && <div className="portal-empty"><ShieldAlert /><p>Er zijn geen poorten met deze status.</p></div>}</div>

    {draft && <div className="manual-portal-backdrop" role="presentation" onMouseDown={(event) => { if (!busy && event.target === event.currentTarget) setDraft(null); }}><aside className="manual-portal-editor" role="dialog" aria-modal="true" aria-labelledby="manual-portal-title">
      <header><div><p className="kicker">{draft.id ? "Poort bewerken" : "Nieuwe poort"}</p><h3 id="manual-portal-title">{draft.name || "Handmatig registreren"}</h3></div><button type="button" className="icon-button" aria-label="Sluiten" disabled={busy} onClick={() => setDraft(null)}><X /></button></header>
      <div className="manual-portal-editor-body">
        {draft.lifecycleStatus === "archived" ? <section><h4>Archiefgegevens bewerken</h4><p>Deze poort blijft gearchiveerd. Routing, beschikbaarheid, teamtoegang en bezoekhistorie worden niet heropend.</p><div className="settings-grid">{([['name','Poortnaam'],['contactName','Contactpersoon'],['contactPhone','Telefoonnummer'],['contactEmail','E-mailadres']] as const).map(([key,label])=><label className="field" key={key}><span>{label}</span><input type={key==='contactEmail'?'email':'text'} value={draft[key]} onChange={e=>setDraft({...draft,[key]:e.target.value})}/></label>)}{([['description','Omschrijving'],['accessibilityNotes','Toegankelijkheid'],['internalNotes','Interne notities']] as const).map(([key,label])=><label className="field wide" key={key}><span>{label}</span><textarea value={draft[key]} onChange={e=>setDraft({...draft,[key]:e.target.value})}/></label>)}</div></section> : <><section><h4>Identiteit</h4><div className="settings-grid"><label className="field"><span>Voorgesteld poortnummer</span><input type="number" min={1} value={draft.systemNumber} disabled={Boolean(draft.id && !portalNumberIsEditable(originalDraft ?? draft))} onChange={(event) => setDraft({ ...draft, systemNumber: event.target.value })} placeholder="Automatisch" /><small>Alleen vóór goedkeuring aanpasbaar.</small></label><label className="field"><span>Poortnaam</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label className="field"><span>Wereld</span><select value={draft.worldSlug} onChange={(event) => setDraft({ ...draft, worldSlug: event.target.value })}>{worlds.map((world) => <option key={world.id} value={world.slug}>{world.name}</option>)}</select></label><label className="field"><span>Kleur</span><input type="color" value={draft.color} onChange={(event) => setDraft({ ...draft, color: event.target.value })} /></label><label className="field"><span>Spanningsniveau</span><input type="number" min={1} max={4} value={draft.intensity} onChange={(event) => setDraft({ ...draft, intensity: event.target.value })} /></label><label className="field"><span>Lifecycle-status</span><select value={draft.lifecycleStatus} onChange={(event) => setDraft({ ...draft, lifecycleStatus: event.target.value as Draft["lifecycleStatus"] })}><option value="concept">Concept</option><option value="registered">Aangemeld</option><option value="approved">Goedgekeurd</option><option value="active">Actief</option></select></label><label className="field"><span>Goedkeuringsstatus</span><select value={draft.approvalStatus} onChange={(event) => setDraft({ ...draft, approvalStatus: event.target.value as Draft["approvalStatus"] })}><option value="draft">Conceptcontrole</option><option value="submitted">In beoordeling</option><option value="changes_requested">Aanpassing gevraagd</option><option value="approved">Goedgekeurd</option><option value="rejected">Afgewezen</option><option value="withdrawn">Teruggetrokken</option></select></label><label className="field wide"><span>Omschrijving</span><textarea value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label></div></section>
        <section><h4>Adres en routingmarker</h4><div className="settings-grid"><label className="field"><span>Straat</span><input value={draft.street} onChange={(event) => setDraft({ ...draft, street: event.target.value })} /></label><label className="field"><span>Huisnummer</span><input value={draft.houseNumber} onChange={(event) => setDraft({ ...draft, houseNumber: event.target.value })} /></label><label className="field"><span>Toevoeging</span><input value={draft.addition} onChange={(event) => setDraft({ ...draft, addition: event.target.value })} /></label><label className="field"><span>Postcode</span><input value={draft.postalCode} onChange={(event) => setDraft({ ...draft, postalCode: event.target.value })} /></label><label className="field"><span>Plaats</span><input value={draft.city} onChange={(event) => setDraft({ ...draft, city: event.target.value })} /></label></div><label className="field"><span>Ingangsinstructie voor ouders</span><textarea maxLength={500} value={draft.publicEntranceInstructions} onChange={event => setDraft({ ...draft, publicEntranceInstructions: event.target.value })} placeholder="Bijvoorbeeld: ingang via het hof achter het huis; volg het steegje links."/><small>Alleen zichtbaar bij deze vrijgegeven bestemming. Gebruik geen contactgegevens of interne notities.</small></label><LocationEditor staged label={draft.name || "Nieuwe poort"} markerKind={draft.isFinal ? "final" : "portal"} color={draft.color} coordinate={draft.routingMarker ? [draft.routingMarker.longitude, draft.routingMarker.latitude] : draft.id ? locationCoordinate(portals.find(portal => portal.id === draft.id)?.longitude ?? null, portals.find(portal => portal.id === draft.id)?.latitude ?? null) : locationCoordinate(draft.longitude ? Number(draft.longitude) : null, draft.latitude ? Number(draft.latitude) : null)} addressCoordinate={locationCoordinate(draft.longitude ? Number(draft.longitude) : null, draft.latitude ? Number(draft.latitude) : null)} reason={draft.routingMarker?.reason} onSave={(change) => setDraft({ ...draft, routingMarker: change })} /></section>
        <section><h4>Contact en toegankelijkheid</h4><div className="settings-grid"><label className="field"><span>Contactpersoon</span><input value={draft.contactName} onChange={(event) => setDraft({ ...draft, contactName: event.target.value })} /></label><label className="field"><span>Telefoonnummer</span><input value={draft.contactPhone} onChange={(event) => setDraft({ ...draft, contactPhone: event.target.value })} /></label><label className="field"><span>E-mailadres</span><input type="email" value={draft.contactEmail} onChange={(event) => setDraft({ ...draft, contactEmail: event.target.value })} /></label><label className="field"><span>Toegankelijkheid</span><textarea value={draft.accessibilityNotes} onChange={(event) => setDraft({ ...draft, accessibilityNotes: event.target.value })} /></label></div></section>
        <section><h4>Geplande beschikbaarheid</h4>{draft.id && (portals.find((portal) => portal.id === draft.id)?.windowCount ?? 0) > 1 && <p>Deze poort heeft meerdere tijdvakken. Bestaande tijdvakken blijven behouden; pas hier alleen de overige poortgegevens aan.</p>}<div className="settings-grid"><label className="field"><span>Live avondstatus</span><select value={draft.operationStatus} onChange={(event) => setDraft({ ...draft, operationStatus: event.target.value as Draft["operationStatus"] })}><option value="scheduled">Onbekend / nog niet gestart</option><option value="open">Open</option><option value="paused">Pauze</option><option value="closed">Gestopt</option></select></label><label className="field"><span>Opent</span><input type="datetime-local" value={draft.plannedOpensAt} onChange={(event) => setDraft({ ...draft, plannedOpensAt: event.target.value })} /></label><label className="field"><span>Sluit</span><input type="datetime-local" value={draft.plannedClosesAt} onChange={(event) => setDraft({ ...draft, plannedClosesAt: event.target.value })} /></label><label className="field"><span>Groepen tegelijk</span><input type="number" min={1} value={draft.maxGroups} onChange={(event) => setDraft({ ...draft, maxGroups: event.target.value })} /></label><label className="field"><span>Kinderen per bezoek</span><input type="number" min={1} value={draft.maxChildren} onChange={(event) => setDraft({ ...draft, maxChildren: event.target.value })} /></label><label className="field"><span>Bezoekduur</span><input type="number" min={1} value={draft.visitMinutes} onChange={(event) => setDraft({ ...draft, visitMinutes: event.target.value })} /></label><label className="field"><span>Buffer</span><input type="number" min={0} value={draft.bufferMinutes} onChange={(event) => setDraft({ ...draft, bufferMinutes: event.target.value })} /></label></div></section>
        <section><h4>Beheer</h4><label className="field"><span>Interne notities</span><textarea value={draft.internalNotes} onChange={(event) => setDraft({ ...draft, internalNotes: event.target.value })} /></label><label className="field"><span>Startpunt</span><select value={draft.candidateStartPoint ? "yes" : "no"} onChange={(event) => setDraft({ ...draft, candidateStartPoint: event.target.value === "yes" })}><option value="no">Nee</option><option value="yes">Ja</option></select></label><label className="check-row"><input type="checkbox" checked={draft.isFinal} onChange={(event) => setDraft({ ...draft, isFinal: event.target.checked, confirmFinal: false })} /><span>Instellen als eindpoort</span></label>{changesFinalPortal && <label className="check-row critical"><input type="checkbox" checked={draft.confirmFinal} onChange={(event) => setDraft({ ...draft, confirmFinal: event.target.checked })} /><span>Ik begrijp dat dit de eindpoortconfiguratie wijzigt.</span></label>}</section></>}
      </div>
      {activationMissing.length > 0 && <p className="form-warning" role="alert">Voor een actieve poort: {activationMissing.join(" ")}</p>}{timeError && <p className="form-warning" role="alert">{timeError}</p>}{stalePortal && stalePortal.id===draft.id && <div className="form-warning" role="status"><p>Deze poort is intussen gewijzigd. Je huidige invoer blijft staan totdat je hieronder kiest. Laden vervangt de invoer door de actuele opgeslagen gegevens; controleer je wijziging daarna opnieuw. Een eerdere impactbevestiging is vervallen.</p><button className="btn outline" type="button" disabled={busy} onClick={()=>{setDraft(fromPortal(stalePortal));setStalePortal(null);setChange(null);saveCommand.current=null;setTimeError("Actuele versie geladen. Controleer je wijziging opnieuw; eventuele impact vraagt opnieuw bevestiging.");}}>Actuele versie laden en opnieuw beoordelen</button></div>}<footer>{draft.id && draft.lifecycleStatus !== "archived" && <button className="text-link danger" type="button" disabled={busy} onClick={() => { const portal = portals.find((item) => item.id === draft.id); if (portal) void remove(portal); }}><Trash2 />Poort verwijderen</button>}<button className="btn outline" disabled={busy} type="button" onClick={() => setDraft(null)}>Annuleren</button>{draft.lifecycleStatus !== "archived" && <button className="btn outline" type="button" disabled={busy || draft.name.trim().length < 2 || !draft.worldSlug} onClick={() => void save("draft")}>Concept opslaan</button>}<button className="btn" type="button" disabled={busy || draft.name.trim().length < 2 || !draft.worldSlug || activationMissing.length > 0 || (changesFinalPortal && !draft.confirmFinal)} onClick={() => void save()}><Save />{draft.lifecycleStatus === "archived" ? "Archiefgegevens opslaan" : "Activeren / gegevens afronden"}</button></footer>
    </aside></div>}
  </div>;
}
