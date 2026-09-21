"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

async function digest(value: unknown) { return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))].map((item) => item.toString(16).padStart(2, "0")).join(""); }

export function PortalWizard({ eventSlug }: { eventSlug: string }) {
  const [payload, setPayload] = useState({ contactName: "", phone: "", address: { street: "", houseNumber: "", addition: "", postalCode: "" }, portalName: "", description: "", intensity: "2", availability: true });
  const [saved, setSaved] = useState<{ id: string; version: number } | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  async function save() {
    const client = createClient(); if (!client) return;
    setBusy(true); setNotice("");
    const { data, error } = await client.schema("api").rpc("portal_application_save", { _event_slug: eventSlug, _payload: payload, _expected_version: saved?.version ?? null });
    setBusy(false);
    if (error) { setNotice(error.message.includes("STALE_VERSION") ? "Dit concept is elders gewijzigd. Vernieuw de pagina." : "Opslaan is niet gelukt."); return null; }
    const result = data as { id: string; version: number };
    setSaved(result); setNotice("Concept opgeslagen."); return result;
  }
  async function submit() {
    const current = await save();
    const client = createClient(); if (!client || !current) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("portal_application_submit", { _application_id: current.id, _expected_version: current.version, _idempotency_key: crypto.randomUUID(), _request_hash: await digest(payload) });
    setBusy(false);
    if (error) return setNotice("Indienen is niet gelukt. Controleer adres en probeer opnieuw.");
    const result = data as { version: number }; setSaved({ ...current, version: result.version }); setNotice("Je huis is ingediend voor beoordeling.");
  }
  return <div className="panel production-form"><h2>Meld je poort aan</h2><p>Je exacte adres blijft privé en wordt alleen gebruikt voor beoordeling en de toegewezen route.</p><label className="field"><span>Naam contactpersoon</span><input value={payload.contactName} onChange={(event) => setPayload({ ...payload, contactName: event.target.value })} /></label><label className="field"><span>Telefoonnummer</span><input value={payload.phone} onChange={(event) => setPayload({ ...payload, phone: event.target.value })} /></label><div className="two-fields"><label className="field"><span>Straat</span><input value={payload.address.street} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, street: event.target.value } })} /></label><label className="field"><span>Huisnummer</span><input value={payload.address.houseNumber} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, houseNumber: event.target.value } })} /></label></div><div className="two-fields"><label className="field"><span>Toevoeging</span><input value={payload.address.addition} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, addition: event.target.value } })} /></label><label className="field"><span>Postcode</span><input value={payload.address.postalCode} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, postalCode: event.target.value.toUpperCase() } })} /></label></div><label className="field"><span>Naam van je poort</span><input value={payload.portalName} onChange={(event) => setPayload({ ...payload, portalName: event.target.value })} /></label><label className="field"><span>Beschrijving</span><textarea rows={5} value={payload.description} onChange={(event) => setPayload({ ...payload, description: event.target.value })} /></label><label className="field"><span>Spanningsniveau (1–4)</span><input type="number" min={1} max={4} value={payload.intensity} onChange={(event) => setPayload({ ...payload, intensity: event.target.value })} /></label><label className="checkfield"><input type="checkbox" checked={payload.availability} onChange={(event) => setPayload({ ...payload, availability: event.target.checked })} />Ik verwacht tussen de definitieve openingstijden beschikbaar te zijn.</label>{notice && <p className="form-notice" role="status">{notice}</p>}<div className="actions"><button className="btn outline" disabled={busy} onClick={() => void save()}>Concept opslaan</button><button className="btn" disabled={busy || !saved} onClick={() => void submit()}>Indienen voor beoordeling</button></div></div>;
}
