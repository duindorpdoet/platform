"use client";

import { useCallback, useEffect, useState } from "react";
import { Archive, Edit3, Plus, Save, ShieldAlert, Trash2, UserPlus, X } from "lucide-react";
import { LocationEditor } from "@/components/admin/location-editor";
import { createClient } from "@/lib/supabase/client";

type World = { id: string; slug: string; name: string };
type Portal = {
  id: string; systemCode: string; name: string; world: string; worldSlug: string; color: string | null; description: string;
  lifecycleStatus: "concept" | "registered" | "approved" | "active" | "archived"; approvalStatus: Draft["approvalStatus"]; operationStatus: string;
  recordSource: "resident_registration" | "manual"; contactName: string | null; phone: string | null; email: string | null;
  address: string | null; postalCode: string | null; city: string | null; geocodedLatitude: number | null; geocodedLongitude: number | null;
  latitude: number | null; longitude: number | null; plannedOpensAt: string | null; plannedClosesAt: string | null;
  maxGroups: number | null; maxChildren: number | null; candidateStartPoint: boolean; isFinal: boolean; version: number;
};
type Draft = {
  id: string | null; version: number | null; systemNumber: string; name: string; worldSlug: string; color: string;
  description: string; intensity: string; street: string; houseNumber: string; addition: string; postalCode: string; city: string;
  latitude: string; longitude: string; contactName: string; contactPhone: string; contactEmail: string;
  plannedOpensAt: string; plannedClosesAt: string; maxGroups: string; maxChildren: string; visitMinutes: string; bufferMinutes: string;
  accessibilityNotes: string; internalNotes: string; lifecycleStatus: Portal["lifecycleStatus"];
  approvalStatus: "draft" | "submitted" | "changes_requested" | "approved" | "rejected" | "withdrawn";
  operationStatus: "scheduled" | "open" | "paused" | "closed";
  candidateStartPoint: boolean; isFinal: boolean; confirmFinal: boolean;
};

function localDateTime(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}
function empty(worlds: World[]): Draft {
  return { id: null, version: null, systemNumber: "", name: "", worldSlug: worlds[0]?.slug ?? "", color: "#d59658",
    description: "", intensity: "1", street: "", houseNumber: "", addition: "", postalCode: "", city: "Den Haag",
    latitude: "", longitude: "", contactName: "", contactPhone: "", contactEmail: "", plannedOpensAt: "", plannedClosesAt: "",
    maxGroups: "1", maxChildren: "20", visitMinutes: "5", bufferMinutes: "2", accessibilityNotes: "", internalNotes: "",
    lifecycleStatus: "concept", approvalStatus: "draft", operationStatus: "scheduled", candidateStartPoint: false, isFinal: false, confirmFinal: false };
}
function fromPortal(portal: Portal): Draft {
  const number = portal.systemCode.match(/\d+/)?.[0] ?? "";
  const addressParts = portal.address?.split(" ") ?? [];
  return { ...empty([]), id: portal.id, version: portal.version, systemNumber: number, name: portal.name, worldSlug: portal.worldSlug,
    color: portal.color ?? "#d59658", description: portal.description, street: addressParts.slice(0, -1).join(" "), houseNumber: addressParts.at(-1) ?? "",
    postalCode: portal.postalCode ?? "", city: portal.city ?? "Den Haag", latitude: portal.latitude?.toString() ?? "",
    longitude: portal.longitude?.toString() ?? "", contactName: portal.contactName ?? "", contactPhone: portal.phone ?? "",
    contactEmail: portal.email ?? "", plannedOpensAt: localDateTime(portal.plannedOpensAt), plannedClosesAt: localDateTime(portal.plannedClosesAt),
    maxGroups: String(portal.maxGroups ?? 1), maxChildren: String(portal.maxChildren ?? 20), lifecycleStatus: portal.lifecycleStatus,
    approvalStatus: portal.approvalStatus,
    operationStatus: portal.operationStatus as Draft["operationStatus"],
    candidateStartPoint: portal.candidateStartPoint, isFinal: portal.isFinal };
}

export function ManualPortalManager({ eventSlug, worlds, onChanged }: { eventSlug: string; worlds: World[]; onChanged: () => void }) {
  const [portals, setPortals] = useState<Portal[]>([]);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_startregie_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("De handmatig beheerde poorten konden niet worden opgehaald.");
    setPortals((data as { portals: Portal[] }).portals);
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function save() {
    if (!draft) return;
    const client = createClient(); if (!client) return;
    setBusy(true);
    const payload = {
      ...draft,
      systemNumber: draft.systemNumber ? Number(draft.systemNumber) : null,
      intensity: Number(draft.intensity), latitude: draft.latitude ? Number(draft.latitude) : null,
      longitude: draft.longitude ? Number(draft.longitude) : null,
      plannedOpensAt: draft.plannedOpensAt ? new Date(draft.plannedOpensAt).toISOString() : null,
      plannedClosesAt: draft.plannedClosesAt ? new Date(draft.plannedClosesAt).toISOString() : null,
      maxGroups: Number(draft.maxGroups), maxChildren: Number(draft.maxChildren),
      visitMinutes: Number(draft.visitMinutes), bufferMinutes: Number(draft.bufferMinutes),
    };
    const { error } = await client.schema("api").rpc("admin_manual_portal_save", {
      _event_slug: eventSlug, _portal_id: draft.id, _payload: payload, _expected_version: draft.version,
      _reason: draft.id ? "Handmatig beheerde poort bijgewerkt" : "Poort handmatig door de organisatie toegevoegd",
    });
    setBusy(false);
    setNotice(error ? `Opslaan geweigerd: ${error.message}` : draft.id ? "Poort bijgewerkt." : "Poort aangemaakt met een stabiele poortcode.");
    if (!error) { setDraft(null); await load(); onChanged(); }
  }

  async function remove(portal: Portal) {
    const verb = portal.recordSource === "manual" && portal.lifecycleStatus === "concept" ? "verwijderen" : "veilig archiveren";
    if (!window.confirm(`${portal.systemCode} ${verb}? Actieve toewijzingen of een eindpoortkoppeling blokkeren dit.`)) return;
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_manual_portal_remove", {
      _portal_id: portal.id, _expected_version: portal.version, _reason: `Poort ${verb} vanuit handmatig beheer`,
    });
    const result = data as { deleted?: boolean } | null;
    setNotice(error ? `Actie geblokkeerd: ${error.message}` : result?.deleted ? "Ongebruikte conceptpoort permanent verwijderd." : "Poort gearchiveerd; historische relaties zijn bewaard.");
    if (!error) { await load(); onChanged(); }
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
    <header><div><p className="kicker">Organisatiebeheer</p><h3>Handmatig geregistreerde poorten</h3><p>Maak een poort aan voordat er een huiseigenarenaccount bestaat. Alleen een goedgekeurde, actieve en routeklare poort kan door de planner worden gebruikt.</p></div><button className="btn" type="button" onClick={() => setDraft(empty(worlds))}><Plus />Poort toevoegen</button></header>
    {notice && <div className="form-notice" role="status">{notice}</div>}
    <div className="manual-portal-list">{portals.filter((portal) => portal.recordSource === "manual").map((portal) => <article key={portal.id}>
      <header><span className="portal-code">{portal.systemCode}</span><div><strong>{portal.name}</strong><small>{portal.world} · {portal.lifecycleStatus} · live: {portal.operationStatus}</small></div>{portal.isFinal && <span className="portal-status-badge">Eindpoort</span>}</header>
      <dl><div><dt>Beschikbaar</dt><dd>{portal.plannedOpensAt ? `${localDateTime(portal.plannedOpensAt).slice(11)}–${localDateTime(portal.plannedClosesAt).slice(11)}` : "Nog niet gepland"}</dd></div><div><dt>Locatie</dt><dd>{portal.latitude !== null ? "Routeklaar" : "Marker ontbreekt"}</dd></div><div><dt>Contact</dt><dd>{portal.contactName || "Niet ingevuld"}</dd></div></dl>
      <div className="actions"><button className="btn outline" type="button" onClick={() => setDraft(fromPortal(portal))}><Edit3 />Bewerken</button>{["approved", "active"].includes(portal.lifecycleStatus) && <button className="btn outline" type="button" disabled={busy} onClick={() => void inviteOwner(portal)}><UserPlus />Eigenaar uitnodigen</button>}<button className="text-link danger" type="button" onClick={() => void remove(portal)}>{portal.lifecycleStatus === "concept" ? <Trash2 /> : <Archive />}{portal.lifecycleStatus === "concept" ? "Verwijderen" : "Archiveren"}</button></div>
    </article>)}{portals.every((portal) => portal.recordSource !== "manual") && <div className="portal-empty"><ShieldAlert /><p>Er zijn nog geen handmatig aangemaakte poorten.</p></div>}</div>

    {draft && <div className="manual-portal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDraft(null); }}><aside className="manual-portal-editor" role="dialog" aria-modal="true" aria-labelledby="manual-portal-title">
      <header><div><p className="kicker">{draft.id ? "Poort bewerken" : "Nieuwe poort"}</p><h3 id="manual-portal-title">{draft.name || "Handmatig registreren"}</h3></div><button type="button" className="icon-button" aria-label="Sluiten" onClick={() => setDraft(null)}><X /></button></header>
      <div className="manual-portal-editor-body">
        <section><h4>Identiteit</h4><div className="settings-grid"><label className="field"><span>Voorgesteld poortnummer</span><input type="number" min={1} value={draft.systemNumber} disabled={Boolean(draft.id && !["concept", "registered"].includes(draft.lifecycleStatus))} onChange={(event) => setDraft({ ...draft, systemNumber: event.target.value })} placeholder="Automatisch" /><small>Alleen vóór goedkeuring aanpasbaar.</small></label><label className="field"><span>Poortnaam</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label className="field"><span>Wereld</span><select value={draft.worldSlug} onChange={(event) => setDraft({ ...draft, worldSlug: event.target.value })}>{worlds.map((world) => <option key={world.id} value={world.slug}>{world.name}</option>)}</select></label><label className="field"><span>Kleur</span><input type="color" value={draft.color} onChange={(event) => setDraft({ ...draft, color: event.target.value })} /></label><label className="field"><span>Spanningsniveau</span><input type="number" min={1} max={4} value={draft.intensity} onChange={(event) => setDraft({ ...draft, intensity: event.target.value })} /></label><label className="field"><span>Lifecycle-status</span><select value={draft.lifecycleStatus} onChange={(event) => setDraft({ ...draft, lifecycleStatus: event.target.value as Draft["lifecycleStatus"] })}><option value="concept">Concept</option><option value="registered">Aangemeld</option><option value="approved">Goedgekeurd</option><option value="active">Actief</option></select></label><label className="field"><span>Goedkeuringsstatus</span><select value={draft.approvalStatus} onChange={(event) => setDraft({ ...draft, approvalStatus: event.target.value as Draft["approvalStatus"] })}><option value="draft">Conceptcontrole</option><option value="submitted">In beoordeling</option><option value="changes_requested">Aanpassing gevraagd</option><option value="approved">Goedgekeurd</option><option value="rejected">Afgewezen</option><option value="withdrawn">Teruggetrokken</option></select></label><label className="field wide"><span>Omschrijving</span><textarea value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label></div></section>
        <section><h4>Adres en routingmarker</h4><div className="settings-grid"><label className="field"><span>Straat</span><input value={draft.street} onChange={(event) => setDraft({ ...draft, street: event.target.value })} /></label><label className="field"><span>Huisnummer</span><input value={draft.houseNumber} onChange={(event) => setDraft({ ...draft, houseNumber: event.target.value })} /></label><label className="field"><span>Toevoeging</span><input value={draft.addition} onChange={(event) => setDraft({ ...draft, addition: event.target.value })} /></label><label className="field"><span>Postcode</span><input value={draft.postalCode} onChange={(event) => setDraft({ ...draft, postalCode: event.target.value })} /></label><label className="field"><span>Plaats</span><input value={draft.city} onChange={(event) => setDraft({ ...draft, city: event.target.value })} /></label></div><LocationEditor label={draft.name || "Nieuwe poort"} markerKind={draft.isFinal ? "final" : "portal"} color={draft.color} coordinate={draft.longitude && draft.latitude ? [Number(draft.longitude), Number(draft.latitude)] : null} addressCoordinate={draft.longitude && draft.latitude ? [Number(draft.longitude), Number(draft.latitude)] : null} onSave={(change) => setDraft({ ...draft, latitude: String(change.latitude), longitude: String(change.longitude) })} /></section>
        <section><h4>Contact en toegankelijkheid</h4><div className="settings-grid"><label className="field"><span>Contactpersoon</span><input value={draft.contactName} onChange={(event) => setDraft({ ...draft, contactName: event.target.value })} /></label><label className="field"><span>Telefoonnummer</span><input value={draft.contactPhone} onChange={(event) => setDraft({ ...draft, contactPhone: event.target.value })} /></label><label className="field"><span>E-mailadres</span><input type="email" value={draft.contactEmail} onChange={(event) => setDraft({ ...draft, contactEmail: event.target.value })} /></label><label className="field"><span>Toegankelijkheid</span><textarea value={draft.accessibilityNotes} onChange={(event) => setDraft({ ...draft, accessibilityNotes: event.target.value })} /></label></div></section>
        <section><h4>Geplande beschikbaarheid</h4><div className="settings-grid"><label className="field"><span>Live avondstatus</span><select value={draft.operationStatus} onChange={(event) => setDraft({ ...draft, operationStatus: event.target.value as Draft["operationStatus"] })}><option value="scheduled">Onbekend / nog niet gestart</option><option value="open">Open</option><option value="paused">Pauze</option><option value="closed">Gestopt</option></select></label><label className="field"><span>Opent</span><input type="datetime-local" value={draft.plannedOpensAt} onChange={(event) => setDraft({ ...draft, plannedOpensAt: event.target.value })} /></label><label className="field"><span>Sluit</span><input type="datetime-local" value={draft.plannedClosesAt} onChange={(event) => setDraft({ ...draft, plannedClosesAt: event.target.value })} /></label><label className="field"><span>Groepen tegelijk</span><input type="number" min={1} value={draft.maxGroups} onChange={(event) => setDraft({ ...draft, maxGroups: event.target.value })} /></label><label className="field"><span>Kinderen per bezoek</span><input type="number" min={1} value={draft.maxChildren} onChange={(event) => setDraft({ ...draft, maxChildren: event.target.value })} /></label><label className="field"><span>Bezoekduur</span><input type="number" min={1} value={draft.visitMinutes} onChange={(event) => setDraft({ ...draft, visitMinutes: event.target.value })} /></label><label className="field"><span>Buffer</span><input type="number" min={0} value={draft.bufferMinutes} onChange={(event) => setDraft({ ...draft, bufferMinutes: event.target.value })} /></label></div></section>
        <section><h4>Beheer</h4><label className="field"><span>Interne notities</span><textarea value={draft.internalNotes} onChange={(event) => setDraft({ ...draft, internalNotes: event.target.value })} /></label><label className="check-row"><input type="checkbox" checked={draft.candidateStartPoint} onChange={(event) => setDraft({ ...draft, candidateStartPoint: event.target.checked })} /><span>Kandidaat-startpunt</span></label><label className="check-row"><input type="checkbox" checked={draft.isFinal} onChange={(event) => setDraft({ ...draft, isFinal: event.target.checked, confirmFinal: false })} /><span>Instellen als eindpoort</span></label>{draft.isFinal && <label className="check-row critical"><input type="checkbox" checked={draft.confirmFinal} onChange={(event) => setDraft({ ...draft, confirmFinal: event.target.checked })} /><span>Ik begrijp dat dit de eindpoortconfiguratie wijzigt.</span></label>}</section>
      </div>
      <footer><button className="btn outline" type="button" onClick={() => setDraft(null)}>Annuleren</button><button className="btn" type="button" disabled={busy || draft.name.trim().length < 2 || !draft.worldSlug || (draft.lifecycleStatus === "active" && (draft.approvalStatus !== "approved" || !draft.latitude || !draft.plannedOpensAt || !draft.plannedClosesAt)) || (draft.isFinal && !draft.confirmFinal)} onClick={() => void save()}><Save />Poort opslaan</button></footer>
    </aside></div>}
  </div>;
}
