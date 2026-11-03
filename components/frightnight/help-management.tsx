"use client";
import type { FestivalController } from "./client";

export function HelpManagement({ controller: c, incident, onSaved }: { controller: FestivalController; incident: { id: string; version: number; status: string; assignedTo: string | null; response: string | null }; onSaved: () => Promise<void> }) {
  const staff = c.snapshot?.incidentStaffChoices ?? [];
  const unavailable = !!incident.assignedTo && !staff.some(person => person.id === incident.assignedTo);
  const disabled = c.busy || !c.online;
  return <details><summary>Hulpvraag behandelen</summary>
    <p className="fn-caption">Versie {incident.version}. Toewijzing en antwoorden worden pas na serverbevestiging bewaard.</p>
    <form aria-label="Hulpvraag toewijzen" onSubmit={async event => {
      event.preventDefault(); const data = new FormData(event.currentTarget);
      if (await c.command("help.assign", { incidentId: incident.id, expectedVersion: incident.version, assignedTo: data.get("assignedTo") || null }, incident.version)) await onSaved();
    }}><label className="ui-field">Behandelaar<select name="assignedTo" defaultValue={incident.assignedTo ?? ""} disabled={disabled}>
      <option value="">In wachtrij · nog niet toegewezen</option>
      {unavailable && <option value={incident.assignedTo!} disabled>Eerder toegewezen medewerker · niet meer beschikbaar</option>}
      {staff.map(person => <option key={person.id} value={person.id}>{person.label}</option>)}
    </select></label><button className="ui-button small" disabled={disabled}>Toewijzing bewaren</button></form>
    <form aria-label="Hulpvraag beantwoorden" onSubmit={async event => {
      event.preventDefault(); const data = new FormData(event.currentTarget);
      if (await c.command("help.reply", { incidentId: incident.id, expectedVersion: incident.version, text: data.get("text") }, incident.version)) await onSaved();
    }}><label className="ui-field">Antwoord<textarea name="text" required minLength={3} maxLength={2000} rows={3} defaultValue={incident.response ?? ""} /></label><button className="ui-button small" disabled={disabled}>Antwoord bewaren en melden</button></form>
    {incident.status !== "resolved" && <button className="ui-button small" disabled={disabled} onClick={async () => {
      if (await c.command("admin.incident.resolve", { incidentId: incident.id, expectedVersion: incident.version }, incident.version)) await onSaved();
    }}>Hulpvraag afhandelen</button>}
  </details>;
}
