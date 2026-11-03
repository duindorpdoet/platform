"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Pencil, RefreshCw, Search } from "lucide-react";
import type { FestivalController } from "./client";
import { money } from "./participant";
import { csvField } from "@/lib/frightnight/csv";
import { ZoneReviewForm, zoneReviewLabel } from "./zone-review";
import { HelpManagement } from "./help-management";
type Resource = "registrations" | "zones" | "payments" | "incidents" | "announcements" | "parties" | "bookings" | "sink" | "content" | "audit";
type Row = Record<string, unknown>;
const columns: Record<Resource, [string, string][]> = {
  registrations: [["label", "Gezelschap"], ["status", "Inschrijving"], ["routeType", "Tocht"], ["persons", "Personen"], ["maxIntensity", "Max. spanning"], ["paymentStatus", "Betaling"], ["amountCents", "Bedrag"]],
  zones: [["name", "Zone"], ["address", "Adres"], ["type", "Vorm"], ["intensity", "Pompoenen"], ["capacity", "Capaciteit"], ["expectedVisitors", "Verwacht"], ["occupancy", "Capaciteitsclaim"], ["status", "Status"], ["reviewStatus", "Beoordeling"], ["reviewReason", "Beoordelingsreden"]],
  payments: [["order_id", "Betaalpoging"], ["registration_id", "Gezelschap"], ["amount_cents", "Bedrag"], ["status", "Status"], ["provider_ref", "Providerbevestiging"]],
  incidents: [["category", "Onderwerp"], ["text", "Hulpvraag"], ["status", "Status"], ["assignedTo", "Behandelaar"], ["version", "Versie"], ["response", "Antwoord"], ["createdAt", "Tijd"]],
  announcements: [["text", "Organisatiebericht"], ["audience", "Doelgroep"], ["targetId", "Ontvanger"], ["version", "Versie"], ["updatedAt", "Bijgewerkt"]],
  parties: [["id", "Samenlooproute"], ["state", "Toestand"], ["version", "Routeversie"], ["preferences", "Gezamenlijke voorkeuren"]],
  bookings: [["registrationId", "Gezelschap"], ["activityId", "Activiteit"], ["seats", "Plaatsen"], ["status", "Boeking"]],
  sink: [["template", "Berichttype"], ["mode", "Bezorggrens"], ["attempts", "Pogingen"], ["createdAt", "Tijd"]],
  content: [["key", "Inhoud"], ["body", "Tekst"], ["published", "Gepubliceerd"], ["version", "Versie"]],
  audit: [["id", "Correlatie"], ["action", "Handeling"], ["createdAt", "Tijd"], ["details", "Besluitinformatie"]],
};
const statuses: Record<Resource, [string, string][]> = {
  registrations: [["draft", "Nog niet actief"], ["active", "Actief"], ["cancelled", "Geannuleerd"], ["archived", "Gearchiveerd"]],
  zones: [["open", "Open"], ["busy", "Druk"], ["paused", "Pauze"], ["closed", "Gesloten"]],
  payments: [["open", "Open"], ["paid", "Betaald"], ["failed", "Mislukt"], ["cancelled", "Geannuleerd"], ["expired", "Verlopen"], ["refunded", "Terugbetaald"]],
  incidents: [["open", "Open"], ["resolved", "Afgehandeld"]],
  parties: [["ready", "Nog niet gestart"], ["walking", "Onderweg"], ["waiting", "Wacht op bestemming"], ["paused", "Gepauzeerd"], ["finished", "Voltooid"], ["merged", "Samengevoegd"], ["archived", "Gearchiveerd"]],
  bookings: [["booked", "Geboekt"], ["cancelled", "Geannuleerd"], ["checked_in", "Aanwezig"]],
  announcements: [], sink: [["sink", "Alleen testsink"]], content: [["published", "Gepubliceerd"], ["draft", "Concept"]], audit: [],
};
const names: Record<Resource, string> = { registrations: "inschrijvingen", zones: "zones", payments: "betalingen", incidents: "hulpvragen", announcements: "organisatieberichten", parties: "samenlooproutes", bookings: "boekingen", sink: "testmail", content: "inhoud", audit: "logboekregels" };
export function AdminResource({ controller: c, resource, title, onAnnouncementEdit, refreshVersion = 0 }: { controller: FestivalController; resource: Resource; title: string; onAnnouncementEdit?: (row: Row) => void; refreshVersion?: number }) {
  const [rows, setRows] = useState<Row[]>([]); const [total, setTotal] = useState(0); const [next, setNext] = useState<number | null>(null);
  const [loading, setLoading] = useState(true); const [error, setError] = useState(""); const [query, setQuery] = useState(""); const [refund, setRefund] = useState<Row | null>(null);
  const [selection, setSelection] = useState({ search: "", status: "", paymentStatus: "", routeType: "", cursor: 0 });
  const generation = useRef(0); const abort = useRef<AbortController | null>(null);
  const supportsRoute = ["registrations", "payments", "incidents", "bookings", "parties", "sink"].includes(resource);
  useEffect(() => { const timer = setTimeout(() => setSelection(current => current.search === query.trim() ? current : { ...current, search: query.trim(), cursor: 0 }), 300); return () => clearTimeout(timer); }, [query]);
  const read = useCallback(async () => {
    const request = ++generation.current; abort.current?.abort(); const controller = new AbortController(); abort.current = controller;
    setLoading(true); setError("");
    const payload = { resource, cursor: selection.cursor, limit: 50, search: selection.search, ...(selection.status ? { status: selection.status } : {}), ...(selection.paymentStatus ? { paymentStatus: selection.paymentStatus } : {}), ...(selection.routeType ? { routeType: selection.routeType } : {}) };
    try {
      const response = await fetch("/api/frightnight/admin/list", { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "same-origin", body: JSON.stringify(payload), cache: "no-store", signal: AbortSignal.any([controller.signal, AbortSignal.timeout(12000)]) });
      const body = await response.json(); if (!response.ok) throw new Error(body.error?.message ?? "De lijst kon niet worden opgehaald.");
      if (request !== generation.current || controller.signal.aborted) return;
      const data = body.data ?? body; setRows(data.items ?? []); setTotal(data.total ?? 0); setNext(data.nextCursor ?? null);
    } catch (cause) { if (request === generation.current && !controller.signal.aborted) setError(cause instanceof Error ? cause.message : "De lijst is tijdelijk niet beschikbaar."); }
    finally { if (request === generation.current && !controller.signal.aborted) setLoading(false); }
  }, [resource, selection]);
  useEffect(() => { const timer = setTimeout(() => void read(), 0); return () => { clearTimeout(timer); abort.current?.abort(); }; }, [read, c.snapshot?.event.id, refreshVersion]);
  const filter = (key: "status" | "paymentStatus" | "routeType", value: string) => setSelection(current => ({ ...current, [key]: value, search: query.trim(), cursor: 0 }));
  const value = (row: Row, key: string): string => {
    const item = row[key];
    if (resource === "incidents" && key === "status") return item === "resolved" ? "Afgehandeld" : "Open";
    if (resource === "incidents" && key === "assignedTo") return item ? c.snapshot?.incidentStaffChoices?.find(person => person.id === item)?.label ?? "Toegewezen medewerker" : "In wachtrij";
    if (key === "reviewStatus") return zoneReviewLabel(String(item ?? ""));
    if (key === "registrationId" || key === "registration_id") return c.snapshot?.registrations?.find(registration => registration.id === item)?.label ?? String(item ?? "");
    if (key === "activityId") return c.snapshot?.activities.find(activity => activity.id === item)?.name ?? String(item ?? "");
    if (key === "amount_cents" || key === "amountCents") return money(Number(item));
    if (key === "createdAt" || key === "updatedAt") return new Date(String(item)).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" });
    if (key === "audience") return ({ all: "Iedereen", lantern: "Lantaarnentocht", roots: "Worteltocht", registration: "Eén gezelschap", zone: "Onderweg naar één zone" } as Record<string, string>)[String(item)] ?? String(item);
    if (key === "targetId") return row.audience === "registration" ? c.snapshot?.registrations?.find(registration => registration.id === item)?.label ?? String(item ?? "—") : row.audience === "zone" ? c.snapshot?.zones?.find(zone => zone.id === item)?.name ?? String(item ?? "—") : "—";
    if (key === "routeType") return item === "lantern" ? "Lantaarnentocht" : item === "roots" ? "Worteltocht" : String(item ?? "—");
    if (key === "preferences" && item && typeof item === "object") { const preferences = item as Row; return `${preferences.persons} personen · max. ${preferences.maxIntensity} pompoenen${preferences.avoidSmoke ? " · geen rook" : ""}${preferences.avoidStrobes ? " · geen flitsen" : ""}${preferences.stepFree ? " · zonder treden" : ""}`; }
    if (key === "occupancy" && item && typeof item === "object") { const load = item as Row; return `${load.effectivePersons} totaal · ${load.appPersons} app · ${load.extraPersons} extra · ${load.overlapPersons} overlap · ${load.available} vrij${load.observationStale ? " · waarneming verouderd, bevestiging nodig" : load.admissionBlocked ? " · nieuwe toegang geblokkeerd" : ""}`; }
    if (typeof item === "boolean") return item ? "Ja" : "Nee";
    return typeof item === "object" ? JSON.stringify(item) : String(item ?? "—");
  };
  const actions = ["payments", "bookings", "parties", "sink", "zones", "incidents", "announcements"].includes(resource);
  return <section className="fn-panel"><h2>{title}</h2><div className="fn-toolbar"><label className="fn-search"><Search size={18} /><input aria-label={`Zoek in alle ${names[resource]}`} placeholder={`Zoek in alle ${names[resource]}`} maxLength={120} value={query} onChange={event => setQuery(event.target.value)} /></label>
    {statuses[resource].length > 0 && <label className="ui-field">{resource === "registrations" ? "Inschrijvingsstatus" : "Status"}<select aria-label={resource === "registrations" ? "Filter inschrijvingsstatus" : "Filter status"} value={selection.status} onChange={event => filter("status", event.target.value)}><option value="">Alle statussen</option>{statuses[resource].map(([key, label]) => <option value={key} key={key}>{label}</option>)}</select></label>}
    {resource === "registrations" && <label className="ui-field">Betaalstatus<select aria-label="Filter betaalstatus" value={selection.paymentStatus} onChange={event => filter("paymentStatus", event.target.value)}><option value="">Alle betalingen</option>{[["unpaid", "Onbetaald"], ...statuses.payments].map(([key, label]) => <option value={key} key={key}>{label}</option>)}</select></label>}
    {supportsRoute && <label className="ui-field">Avonddeel<select aria-label="Filter avonddeel" value={selection.routeType} onChange={event => filter("routeType", event.target.value)}><option value="">Beide tochten</option><option value="lantern">Lantaarnentocht · 17:00–18:30</option><option value="roots">Worteltocht · 18:30–21:00</option></select></label>}
    <button className="ui-button" disabled={loading} onClick={() => void read()}><RefreshCw size={16} />Vernieuwen</button><button className="ui-button" disabled={loading || !!error || !rows.length} onClick={() => { const content = [[...columns[resource].map(column => column[1])], ...rows.map(row => columns[resource].map(([key]) => value(row, key)))].map(row => row.map(csvField).join(";")).join("\r\n"); const url = URL.createObjectURL(new Blob(["\uFEFF" + content], { type: "text/csv;charset=utf-8" })); const a = document.createElement("a"); a.href = url; a.download = `frightnight-${resource}-pagina-${Math.floor(selection.cursor / 50) + 1}.csv`; a.click(); URL.revokeObjectURL(url); }}><Download size={16} /> Exporteer pagina</button></div>
    <p className="fn-caption">Zoeken en filteren gebeurt over alle {names[resource]} van deze editie. Elke aanvraag haalt maximaal 50 rijen op. De export bevat de getoonde pagina.</p>
    {error && <p className="fn-error" role="alert">{error}</p>}{loading ? <p role="status">Beveiligde lijst ophalen…</p> : error ? <p>De actuele lijst is niet beschikbaar. Vernieuw om opnieuw te proberen.</p> : <><p className="fn-caption" role="status">{total} resultaten voor de gekozen filters in deze editie.</p><div className="fn-table-scroll"><table><thead><tr>{columns[resource].map(([key, label]) => <th key={key}>{label}</th>)}{actions && <th>Actie</th>}</tr></thead><tbody>{rows.map((row, index) => <tr key={String(row.id ?? row.order_id ?? row.key ?? index)}>{columns[resource].map(([key]) => <td key={key}>{value(row, key)}</td>)}
      {resource === "announcements" && <td><span className="ui-status">In-app gepubliceerd</span><button className="ui-button small" disabled={c.busy || !onAnnouncementEdit} onClick={() => onAnnouncementEdit?.(row)}><Pencil size={15} /> Bericht wijzigen</button></td>}
      {resource === "sink" && <td><a className="ui-button small" href={`/api/frightnight/mail-preview?id=${encodeURIComponent(String(row.id))}&cursor=${selection.cursor}`} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Testmail bekijken</a></td>}
      {resource === "zones" && <td>{typeof row.photoPath === "string" && row.photoPath && <a className="ui-button small" href={`/api/frightnight/zone-photo?zoneId=${encodeURIComponent(String(row.id))}`} target="_blank" rel="noopener noreferrer" aria-label={`Bekijk de huidige zonefoto van ${String(row.name)}`}>Bekijk zonefoto</a>}<ZoneReviewForm key={`${row.id}:${row.version}`} controller={c} zone={{ id: String(row.id), name: String(row.name), version: Number(row.version), reviewReason: typeof row.reviewReason === "string" ? row.reviewReason : null }} onSaved={read} /><select aria-label={`Status van ${String(row.name)}`} disabled={c.busy} value={String(row.status)} onChange={async event => { if (await c.command("zone.status", { zoneId: row.id, status: event.target.value, expectedVersion: row.version }, Number(row.version))) await read(); }}>{statuses.zones.map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select>{row.reviewStatus === "approved" && <a className="ui-button small" href={`/api/frightnight/qr?zoneId=${encodeURIComponent(String(row.id))}`} target="_blank" rel="noopener noreferrer">QR-bord</a>}</td>}
      {resource === "incidents" && <td><HelpManagement key={`${row.id}:${row.version}`} controller={c} incident={{ id: String(row.id), version: Number(row.version), status: String(row.status), assignedTo: typeof row.assignedTo === "string" ? row.assignedTo : null, response: typeof row.response === "string" ? row.response : null }} onSaved={read} /></td>}
      {resource === "payments" && <td>{row.status === "paid" && <button className="ui-button small" disabled={c.busy} onClick={() => setRefund(row)}>Testrefund beoordelen</button>}</td>}
      {resource === "parties" && <td><button className="ui-button small" disabled={c.busy} onClick={async () => { if (await c.command("admin.recalculate", { partyId: row.id })) await read(); }}>Gericht herberekenen</button><button className="ui-button small" disabled={c.busy} onClick={async () => { if (await c.command("admin.recalculate", { partyId: row.id, returnToDuinpad: true })) await read(); }}>Naar Duinpad leiden</button></td>}
      {resource === "bookings" && <td>{row.status === "booked" ? <button className="ui-button small" disabled={c.busy} onClick={async () => { if (await c.command("admin.activity.checkin", { bookingId: row.id })) await read(); }}>Aanwezig melden</button> : "Geen open incheck"}</td>}</tr>)}</tbody></table></div><div className="fn-pagination"><span>{rows.length ? `${selection.cursor + 1}–${selection.cursor + rows.length} van ${total}` : "Geen resultaten op deze pagina"}</span><button className="ui-button" disabled={selection.cursor === 0 || loading} onClick={() => setSelection(current => ({ ...current, cursor: Math.max(0, current.cursor - 50) }))}><ChevronLeft size={16} /> Vorige</button><button className="ui-button" disabled={next === null || loading} onClick={() => { if (next !== null) setSelection(current => ({ ...current, cursor: next })); }}>Volgende <ChevronRight size={16} /></button></div></>}
    {refund && resource === "payments" && <div className="fn-danger-zone"><h3>Gecontroleerde testrefund</h3><p>Volledig testbedrag: <strong>{money(Number(refund.amount_cents))}</strong>. De server controleert betaling, provideromgeving en eerdere refunds.</p><form onSubmit={async event => { event.preventDefault(); const data = new FormData(event.currentTarget); if (await c.command("payment.refund", { registrationId: refund.registration_id, reason: data.get("reason") })) { setRefund(null); await read(); } }}><label className="ui-field">Reden<input required name="reason" minLength={5} maxLength={250} /></label><label className="fn-check"><input required type="checkbox" /> Ik bevestig de volledige testrefund voor dit gezelschap.</label><button className="ui-button" disabled={c.busy}>Testrefund bij provider aanvragen</button><button className="ui-button" type="button" disabled={c.busy} onClick={() => setRefund(null)}>Sluiten</button></form></div>}
  </section>;
}
