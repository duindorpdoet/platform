"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

async function digest(value: unknown) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))]
    .map((item) => item.toString(16).padStart(2, "0")).join("");
}

type ReviewStatus = "draft" | "changes_requested" | "submitted" | "approved" | "rejected" | "withdrawn";
type WarningKey = "smoke" | "flashes" | "sound" | "actors" | "allergens";
type PortalPayload = {
  email: string;
  contactName: string;
  phone: string;
  address: { street: string; houseNumber: string; addition: string; postalCode: string };
  entrance: string;
  requestedWorldSlug: string;
  portalName: string;
  description: string;
  intensity: string;
  warnings: Record<WarningKey, boolean>;
  warningNotes: string;
  availableFrom: string;
  availableUntil: string;
  visitMinutes: string;
  maxConcurrentGroups: string;
  maxChildrenPerVisit: string;
  maxChildrenTotal: string;
  accessibility: "step_free" | "steps" | "mixed" | "unknown";
  accessibilityNotes: string;
  assetPaths: string[];
  availability: boolean;
  locationConsent: boolean;
};

const emptyPayload: PortalPayload = {
  email: "",
  contactName: "",
  phone: "",
  address: { street: "", houseNumber: "", addition: "", postalCode: "" },
  entrance: "Zelfde ingang als het opgegeven adres",
  requestedWorldSlug: "",
  portalName: "",
  description: "",
  intensity: "2",
  warnings: { smoke: false, flashes: false, sound: false, actors: false, allergens: false },
  warningNotes: "",
  availableFrom: "18:00",
  availableUntil: "22:00",
  visitMinutes: "5",
  maxConcurrentGroups: "1",
  maxChildrenPerVisit: "12",
  maxChildrenTotal: "120",
  accessibility: "unknown",
  accessibilityNotes: "",
  assetPaths: [],
  availability: true,
  locationConsent: false,
};

const warningLabels: Record<WarningKey, string> = {
  smoke: "Rook of mist",
  flashes: "Flitsend licht",
  sound: "Hard geluid",
  actors: "Acteurs of onverwachte beweging",
  allergens: "Allergenen bij traktaties",
};

function restoredPayload(draft: Partial<PortalPayload>, fallbackWorld: string): PortalPayload {
  return {
    ...emptyPayload,
    ...draft,
    requestedWorldSlug: draft.requestedWorldSlug || fallbackWorld,
    address: { ...emptyPayload.address, ...draft.address },
    warnings: { ...emptyPayload.warnings, ...draft.warnings },
    assetPaths: Array.isArray(draft.assetPaths) ? draft.assetPaths.filter((path): path is string => typeof path === "string") : [],
  };
}

export function PortalWizard({ eventSlug }: { eventSlug: string }) {
  const [payload, setPayload] = useState<PortalPayload>(emptyPayload);
  const [worlds, setWorlds] = useState<Array<{ slug: string; name: string }>>([]);
  const [saved, setSaved] = useState<{ id: string; version: number } | null>(null);
  const [status, setStatus] = useState<ReviewStatus | null>(null);
  const [reviewFeedback, setReviewFeedback] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    let active = true;
    async function restore() {
      const client = createClient(); if (!client) return;
      const [portalResult, eventResult] = await Promise.all([
        client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug }),
        client.schema("api").rpc("event_public_snapshot", { _event_slug: eventSlug }),
      ]);
      if (!active) return;
      if (portalResult.error || eventResult.error) { setNotice("Je huisgegevens konden niet worden opgehaald. Vernieuw de pagina om opnieuw te proberen."); return; }
      setLoaded(true);
      const availableWorlds = ((eventResult.data as { worlds?: Array<{ slug: string; name: string }> } | null)?.worlds ?? []);
      setWorlds(availableWorlds);
      const application = (portalResult.data as { application?: { id: string; status: ReviewStatus; version: number; draft: Partial<PortalPayload>; reviewFeedback?: string | null } } | null)?.application;
      if (!application) {
        setPayload((current) => ({ ...current, requestedWorldSlug: current.requestedWorldSlug || availableWorlds[0]?.slug || "" }));
        return;
      }
      setSaved({ id: application.id, version: application.version });
      setStatus(application.status);
      setReviewFeedback(application.reviewFeedback ?? null);
      setPayload(restoredPayload(application.draft ?? {}, availableWorlds[0]?.slug ?? ""));
      if (application.status === "changes_requested") setNotice("De organisatie vraagt om een aanpassing. Pas je concept aan en dien het opnieuw in.");
      if (application.status === "submitted") setNotice("Je huis is ingediend en wacht op beoordeling.");
      if (application.status === "approved") setNotice("Je poort is goedgekeurd. Operationele informatie staat in je poortdashboard.");
      if (application.status === "rejected") setNotice("Deze aanvraag is afgewezen.");
    }
    void restore();
    return () => { active = false; };
  }, [eventSlug]);

  const editable = loaded && (status === null || status === "draft" || status === "changes_requested");

  function validateForSubmission() {
    const requiredText = [payload.contactName, payload.phone, payload.address.street, payload.address.houseNumber, payload.address.postalCode, payload.entrance, payload.requestedWorldSlug, payload.portalName, payload.description];
    if (requiredText.some((value) => !value.trim()) || payload.description.trim().length < 10) return "Vul alle verplichte aanvraaggegevens volledig in.";
    if (!/^\d{4}\s?[A-Z]{2}$/.test(payload.address.postalCode.trim().toUpperCase())) return "Vul een geldige Nederlandse postcode in.";
    if (payload.availableUntil <= payload.availableFrom) return "De eindtijd moet na de begintijd liggen.";
    const visitMinutes = Number(payload.visitMinutes);
    const concurrent = Number(payload.maxConcurrentGroups);
    const perVisit = Number(payload.maxChildrenPerVisit);
    const total = Number(payload.maxChildrenTotal);
    if (!Number.isInteger(visitMinutes) || visitMinutes < 1 || visitMinutes > 30 || !Number.isInteger(concurrent) || concurrent < 1 || concurrent > 20 || !Number.isInteger(perVisit) || perVisit < 1 || perVisit > 100 || !Number.isInteger(total) || total < perVisit || total > 5000) return "Controleer bezoekduur en capaciteitsgrenzen.";
    if (!payload.availability || !payload.locationConsent) return "Bevestig beschikbaarheid en toestemming voor besloten locatieverwerking.";
    return null;
  }

  async function save() {
    if (!editable) { setNotice("Deze aanvraag is al in behandeling en kan nu niet worden gewijzigd."); return null; }
    const client = createClient(); if (!client) return null;
    setBusy(true); setNotice("");
    const { data, error } = await client.schema("api").rpc("portal_application_save", { _event_slug: eventSlug, _payload: payload, _expected_version: saved?.version ?? null });
    setBusy(false);
    if (error) { setNotice(error.message.includes("STALE_VERSION") ? "Dit concept is elders gewijzigd. Vernieuw de pagina." : "Opslaan is niet gelukt."); return null; }
    const result = data as { id: string; version: number };
    setSaved(result); setStatus("draft"); setNotice("Concept opgeslagen."); return result;
  }

  async function submit() {
    const validationError = validateForSubmission();
    if (validationError) return setNotice(validationError);
    const current = await save();
    const client = createClient(); if (!client || !current) return;
    setBusy(true);
    const { data, error } = await client.schema("api").rpc("portal_application_submit", { _application_id: current.id, _expected_version: current.version, _idempotency_key: crypto.randomUUID(), _request_hash: await digest(payload) });
    setBusy(false);
    if (error) return setNotice("Indienen is niet gelukt. Controleer de gegevens en probeer opnieuw.");
    const result = data as { version: number };
    setSaved({ ...current, version: result.version }); setStatus("submitted"); setReviewFeedback(null); setNotice("Je huis is ingediend voor beoordeling.");
  }

  async function uploadAsset(file: File) {
    if (!editable) return setNotice("Deze aanvraag kan nu geen nieuwe afbeelding ontvangen.");
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size < 1 || file.size > 8 * 1024 * 1024) {
      return setNotice("Kies een JPG-, PNG- of WebP-afbeelding van maximaal 8 MB.");
    }
    const application = saved ?? await save();
    if (!application) return;
    setBusy(true); setNotice("");
    const form = new FormData();
    form.set("applicationId", application.id);
    form.set("file", file);
    const response = await fetch("/api/portal-assets", { method: "POST", body: form });
    const body = await response.json() as { data?: { path: string }; error?: { message?: string } };
    if (!response.ok || !body.data?.path) {
      setBusy(false); setNotice(body.error?.message ?? "De afbeelding kon niet veilig worden opgeslagen."); return;
    }
    const nextPayload = { ...payload, assetPaths: [...new Set([...payload.assetPaths, body.data.path])] };
    const client = createClient();
    const linked = client ? await client.schema("api").rpc("portal_application_save", { _event_slug: eventSlug, _payload: nextPayload, _expected_version: application.version }) : null;
    setBusy(false);
    if (!linked || linked.error) return setNotice("De afbeelding is privé opgeslagen maar kon niet aan het concept worden gekoppeld. Vernieuw en probeer opnieuw.");
    const result = linked.data as { id: string; version: number };
    setPayload(nextPayload); setSaved(result); setStatus("draft"); setNotice("Afbeelding privé opgeslagen en aan je concept gekoppeld.");
  }

  function setWarning(key: WarningKey, value: boolean) {
    setPayload({ ...payload, warnings: { ...payload.warnings, [key]: value } });
  }

  return <div className="panel production-form">
    <h2>Vul je huisdetails aan</h2>
    <p>Je exacte adres blijft privé en wordt alleen gebruikt voor beoordeling en toegewezen routes.</p>
    {reviewFeedback && <div className="form-warning"><strong>Terugkoppeling van de organisatie:</strong> {reviewFeedback}</div>}
    <fieldset className="form-fieldset" disabled={busy || !editable}>
      <h3>Contact en locatie</h3>
      {payload.email && <p>E-mailadres: {payload.email} (bevestigd)</p>}
      <label className="field"><span>Naam contactpersoon *</span><input required autoComplete="name" value={payload.contactName} onChange={(event) => setPayload({ ...payload, contactName: event.target.value })} /></label>
      <label className="field"><span>Telefoonnummer *</span><input required autoComplete="tel" value={payload.phone} onChange={(event) => setPayload({ ...payload, phone: event.target.value })} /></label>
      <div className="two-fields"><label className="field"><span>Straat *</span><input required autoComplete="address-line1" value={payload.address.street} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, street: event.target.value } })} /></label><label className="field"><span>Huisnummer *</span><input required value={payload.address.houseNumber} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, houseNumber: event.target.value } })} /></label></div>
      <div className="two-fields"><label className="field"><span>Toevoeging</span><input value={payload.address.addition} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, addition: event.target.value } })} /></label><label className="field"><span>Postcode *</span><input required autoComplete="postal-code" value={payload.address.postalCode} onChange={(event) => setPayload({ ...payload, address: { ...payload.address, postalCode: event.target.value.toUpperCase() } })} /></label></div>
      <label className="field"><span>Ingang of route naar de deur *</span><input required value={payload.entrance} onChange={(event) => setPayload({ ...payload, entrance: event.target.value })} /></label>

      <h3>Beleving en veiligheid</h3>
      <label className="field"><span>Gewenste wereld *</span><select className="choice" value={payload.requestedWorldSlug} onChange={(event) => setPayload({ ...payload, requestedWorldSlug: event.target.value })}>{worlds.map((world) => <option key={world.slug} value={world.slug}>{world.name}</option>)}</select></label>
      <label className="field"><span>Naam van je poort *</span><input required value={payload.portalName} onChange={(event) => setPayload({ ...payload, portalName: event.target.value })} /></label>
      <label className="field"><span>Beschrijving *</span><textarea required minLength={10} maxLength={1000} rows={5} value={payload.description} onChange={(event) => setPayload({ ...payload, description: event.target.value })} /></label>
      <label className="field"><span>Spanningsniveau (1–4) *</span><input type="number" min={1} max={4} value={payload.intensity} onChange={(event) => setPayload({ ...payload, intensity: event.target.value })} /></label>
      <div className="check-grid">{(Object.keys(warningLabels) as WarningKey[]).map((key) => <label className="checkfield" key={key}><input type="checkbox" checked={payload.warnings[key]} onChange={(event) => setWarning(key, event.target.checked)} />{warningLabels[key]}</label>)}</div>
      <label className="field"><span>Toelichting op waarschuwingen of allergenen</span><textarea maxLength={500} value={payload.warningNotes} onChange={(event) => setPayload({ ...payload, warningNotes: event.target.value })} /></label>

      <h3>Venster en capaciteit</h3>
      <div className="two-fields"><label className="field"><span>Beschikbaar vanaf *</span><input type="time" value={payload.availableFrom} onChange={(event) => setPayload({ ...payload, availableFrom: event.target.value })} /></label><label className="field"><span>Beschikbaar tot *</span><input type="time" value={payload.availableUntil} onChange={(event) => setPayload({ ...payload, availableUntil: event.target.value })} /></label></div>
      <div className="two-fields"><label className="field"><span>Bezoekduur in minuten *</span><input type="number" min={1} max={30} value={payload.visitMinutes} onChange={(event) => setPayload({ ...payload, visitMinutes: event.target.value })} /></label><label className="field"><span>Groepen tegelijk *</span><input type="number" min={1} max={20} value={payload.maxConcurrentGroups} onChange={(event) => setPayload({ ...payload, maxConcurrentGroups: event.target.value })} /></label></div>
      <div className="two-fields"><label className="field"><span>Kinderen per bezoek *</span><input type="number" min={1} max={100} value={payload.maxChildrenPerVisit} onChange={(event) => setPayload({ ...payload, maxChildrenPerVisit: event.target.value })} /></label><label className="field"><span>Kinderen totaal *</span><input type="number" min={1} max={5000} value={payload.maxChildrenTotal} onChange={(event) => setPayload({ ...payload, maxChildrenTotal: event.target.value })} /></label></div>
      <label className="field"><span>Praktische toegankelijkheid *</span><select className="choice" value={payload.accessibility} onChange={(event) => setPayload({ ...payload, accessibility: event.target.value as PortalPayload["accessibility"] })}><option value="unknown">Nog te beoordelen</option><option value="step_free">Drempelvrij</option><option value="steps">Trappen of hoge drempels</option><option value="mixed">Gedeeltelijk toegankelijk</option></select></label>
      <label className="field"><span>Toelichting toegankelijkheid</span><textarea maxLength={500} value={payload.accessibilityNotes} onChange={(event) => setPayload({ ...payload, accessibilityNotes: event.target.value })} /></label>
      <label className="field"><span>Foto van de opstelling (optioneel)</span><input type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => { const file = event.target.files?.[0]; if (file) void uploadAsset(file); event.currentTarget.value = ""; }} /><small>Alleen privé zichtbare JPG, PNG of WebP, maximaal 8 MB. De server controleert de werkelijke bestandsinhoud.</small></label>
      {payload.assetPaths.length > 0 && <p className="note">{payload.assetPaths.length} afbeelding(en) veilig aan dit concept gekoppeld.</p>}
      <label className="checkfield"><input type="checkbox" checked={payload.availability} onChange={(event) => setPayload({ ...payload, availability: event.target.checked })} />Ik ben tijdens het opgegeven venster beschikbaar en meld wijzigingen tijdig.</label>
      <label className="checkfield"><input type="checkbox" checked={payload.locationConsent} onChange={(event) => setPayload({ ...payload, locationConsent: event.target.checked })} />Ik geef toestemming om dit adres besloten te verwerken voor beoordeling, planning en uitsluitend de actuele toegewezen groep. *</label>
    </fieldset>
    {notice && <p className="form-notice" role="status">{notice}</p>}
    <div className="actions"><button className="btn outline" disabled={busy || !editable} onClick={() => void save()}>Concept opslaan</button><button className="btn" disabled={busy || !editable} onClick={() => void submit()}>Indienen voor beoordeling</button></div>
  </div>;
}
