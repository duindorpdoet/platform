"use client";

import { useCallback, useEffect, useState } from "react";
import Papa from "papaparse";
import { AlertTriangle, CheckCircle2, Database, LifeBuoy, MapPinned, RefreshCw, ShieldCheck, Upload } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { proposePlan, type PlanningInput } from "@/lib/domain/route-planner";

type Dashboard = { event: { title: string; phase: string; date: string; settingsVersion: number }; counts: Record<string, number>; imports: Array<{ id: string; kind: string; status: string; createdAt: string }>; recentActivity: Array<{ action: string; resourceType: string; createdAt: string }> };
type PlanResult = ReturnType<typeof proposePlan>;
type LiveRun = { groupId: string; groupCode: string; runId: string; runStatus: "live" | "paused"; runVersion: number; stopId: string; portalName: string };

async function digest(value: unknown) { return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))].map((item) => item.toString(16).padStart(2, "0")).join(""); }

const labels: Record<string, string> = { registrations: "Inschrijvingen", children: "Kinderen", portalApplications: "Poortaanvragen", approvedPortals: "Goedgekeurde poorten", groups: "Groepen", liveGroups: "Live groepen", openSupportCases: "Open incidenten", unconfirmedPayments: "Te controleren betalingen" };
const requiredColumns: Record<string, string[]> = { portals: ["street", "house_number", "postal_code"], registrations: ["email", "child_name"], payments: ["reference", "amount_cents"], graph: ["from", "to", "duration_seconds"], starts: ["name", "starts_at", "max_children"] };

export function AdminConsole({ eventSlug }: { eventSlug: string }) {
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [section, setSection] = useState<"overview" | "imports" | "planner" | "live">("overview");
  const [importKind, setImportKind] = useState("portals");
  const [importResult, setImportResult] = useState<{ status: string; errors: Array<{ row: number; field?: string; code: string; message: string }> } | null>(null);
  const [plan, setPlan] = useState<PlanResult | null>(null);
  const [planIds, setPlanIds] = useState<string[]>([]);
  const [notice, setNotice] = useState("");
  const [liveRuns, setLiveRuns] = useState<LiveRun[]>([]);
  const [supportReason, setSupportReason] = useState("");
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data } = await client.schema("api").rpc("admin_dashboard", { _event_slug: eventSlug }); setDashboard(data as Dashboard); }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  async function dryRun(file: File) {
    const parsed = Papa.parse<Record<string, string>>(await file.text(), { header: true, skipEmptyLines: true });
    const errors: Array<{ row: number; field?: string; code: string; message: string }> = parsed.errors.map((error) => ({ row: (error.row ?? 0) + 2, code: error.code, message: error.message }));
    const columns = parsed.meta.fields ?? [];
    for (const field of requiredColumns[importKind]) if (!columns.includes(field)) errors.push({ row: 1, field, code: "MISSING_COLUMN", message: `Kolom ${field} ontbreekt.` });
    parsed.data.forEach((row, index) => requiredColumns[importKind].forEach((field) => { if (!String(row[field] ?? "").trim()) errors.push({ row: index + 2, field, code: "REQUIRED", message: `${field} is verplicht.` }); }));
    const sourceHash = await digest(await file.text());
    const client = createClient(); if (!client) return;
    const result = await client.schema("api").rpc("admin_record_import", { _event_slug: eventSlug, _kind: importKind, _source_hash: sourceHash, _errors: errors });
    if (result.error) return setNotice("Dry-run kon niet worden vastgelegd.");
    setImportResult({ status: (result.data as { status: string }).status, errors }); setNotice("Dry-run opgeslagen; er zijn geen rijen toegepast."); await load();
  }

  async function calculatePlan() {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_planning_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Planningsinvoer is niet toegankelijk.");
    const result = proposePlan({ ...(data as Omit<PlanningInput, "targetGroupSize" | "maxGroupSize" | "stopsPerGroup">), targetGroupSize: 7, maxGroupSize: 10, stopsPerGroup: 6 });
    setPlan(result); setPlanIds([]); setNotice(result.conflicts.length ? "Het voorstel bevat blokkerende conflicten." : "Deterministisch voorstel berekend. Er is nog niets gepubliceerd.");
  }

  async function savePlan() {
    if (!plan || plan.conflicts.length || !plan.groups.length) return;
    const client = createClient(); if (!client) return;
    const inputHash = await digest(plan);
    const key = crypto.randomUUID();
    const { data, error } = await client.schema("api").rpc("admin_apply_plan", { _event_slug: eventSlug, _proposal: plan, _input_hash: inputHash, _idempotency_key: key, _request_hash: await digest({ plan, key }) });
    if (error) return setNotice(`Voorstel opslaan mislukt: ${error.message}`);
    setPlanIds((data as { planIds: string[] }).planIds); setNotice("Voorstel als geldige routeversies opgeslagen. Publicatie is nog niet uitgevoerd."); await load();
  }

  async function publishPlan() {
    const client = createClient(); if (!client || !planIds.length) return;
    if (!window.confirm("Publiceer deze routeversies? Deelnemers zien nog steeds alleen hun huidige bestemming.")) return;
    const { error } = await client.schema("api").rpc("admin_publish_plans", { _event_slug: eventSlug, _plan_ids: planIds, _reason: "Expliciete publicatie na controle van het voorstel" });
    setNotice(error ? "Publicatie is geweigerd." : "Routeversies zijn gepubliceerd en geaudit."); if (!error) setPlanIds([]); await load();
  }

  async function loadLive() {
    const client = createClient(); if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_live_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Live-overzicht is alleen beschikbaar voor avondondersteuning.");
    setLiveRuns(data as LiveRun[]);
  }

  async function liveCommand(run: LiveRun, command: "override" | "paused" | "live" | "stopped") {
    const client = createClient(); if (!client) return;
    if (supportReason.trim().length < 10) return setNotice("Leg voor een noodhandeling minimaal tien tekens reden vast.");
    const result = command === "override"
      ? await client.schema("api").rpc("run_support_override", { _run_id: run.runId, _stop_id: run.stopId, _expected_run_version: run.runVersion, _reason: supportReason })
      : await client.schema("api").rpc("run_set_state", { _run_id: run.runId, _state: command, _expected_version: run.runVersion, _reason: supportReason });
    setNotice(result.error ? `Noodhandeling geweigerd: ${result.error.message}` : "Noodhandeling uitgevoerd en in de auditlog vastgelegd.");
    if (!result.error) setSupportReason("");
    await loadLive();
  }

  if (!dashboard) return <div className="panel loading-state"><RefreshCw className="spin" />Beheergegevens ophalen…</div>;
  return <div className="admin-shell"><aside className="admin-nav"><p className="kicker">Organisatie</p><button className={section === "overview" ? "active" : ""} onClick={() => setSection("overview")}><ShieldCheck />Overzicht</button><button className={section === "imports" ? "active" : ""} onClick={() => setSection("imports")}><Database />Imports</button><button className={section === "planner" ? "active" : ""} onClick={() => setSection("planner")}><MapPinned />Routeplanner</button><button className={section === "live" ? "active" : ""} onClick={() => { setSection("live"); void loadLive(); }}><LifeBuoy />Avondhulp</button></aside><div className="admin-content"><div className="app-heading row-between"><div><p className="kicker">{dashboard.event.phase} · {dashboard.event.date}</p><h1>{dashboard.event.title}</h1></div><button className="btn outline" onClick={() => void load()}><RefreshCw />Vernieuwen</button></div>{notice && <div className="form-notice" role="status">{notice}</div>}{section === "overview" && <><div className="dashboard-metrics">{Object.entries(dashboard.counts).map(([key, value]) => <div className="metric" key={key}><strong>{value}</strong><span>{labels[key] ?? key}</span></div>)}</div><section className="panel activity"><p className="kicker">Recente auditactiviteit</p>{dashboard.recentActivity.length ? dashboard.recentActivity.map((item, index) => <div className="activity-row" key={`${item.createdAt}-${index}`}><CheckCircle2 /><div><strong>{item.action}</strong><small>{item.resourceType} · {new Date(item.createdAt).toLocaleString("nl-NL")}</small></div></div>) : <p>Nog geen activiteit.</p>}</section></>}{section === "imports" && <section className="panel"><p className="kicker">Altijd eerst valideren</p><h2>CSV dry-run</h2><p>Een dry-run schrijft alleen een batch en rijgebonden fouten; operationele tabellen blijven onaangeraakt.</p><label className="field"><span>Type bestand</span><select value={importKind} onChange={(event) => setImportKind(event.target.value)}>{Object.keys(requiredColumns).map((kind) => <option key={kind}>{kind}</option>)}</select></label><label className="import-drop"><Upload /><span>Kies CSV voor controle</span><input type="file" accept=".csv,text/csv" onChange={(event) => { const file = event.target.files?.[0]; if (file) void dryRun(file); }} /></label>{importResult && <div><h3>Status: {importResult.status}</h3>{importResult.errors.map((error, index) => <p className="form-error" key={index}>Rij {error.row}{error.field ? `, ${error.field}` : ""}: {error.message}</p>)}</div>}<div className="separator" /><h3>Laatste batches</h3>{dashboard.imports.map((item) => <div className="summary-row" key={item.id}><span>{item.kind} · {new Date(item.createdAt).toLocaleString("nl-NL")}</span><strong>{item.status}</strong></div>)}</section>}{section === "planner" && <section className="panel"><p className="kicker">Deterministisch · versieerbaar</p><h2>Indelingsvoorstel</h2><p>De planner houdt samenloopwensen intact, respecteert groeps- en startcapaciteit, controleert tijdvensters en verdeelt zes verschillende werelden. Conflicten blokkeren opslag.</p><div className="actions"><button className="btn" onClick={() => void calculatePlan()}>Bereken voorstel</button><button className="btn outline" disabled={!plan?.groups.length || !!plan.conflicts.length} onClick={() => void savePlan()}>Sla als conceptversies op</button><button className="btn outline" disabled={!planIds.length} onClick={() => void publishPlan()}>Publiceer expliciet</button></div>{plan && <div className="planner-result">{plan.conflicts.map((conflict) => <div className="form-warning" key={`${conflict.code}-${conflict.subjectId}`}><AlertTriangle />{conflict.code}: {conflict.message}</div>)}{plan.groups.map((group) => <div className="summary-row" key={group.key}><span>{group.key}: {group.childCount} kinderen, {group.portalIds.length} poorten</span><strong>{group.partyIds.length} inschrijving(en)</strong></div>)}</div>}</section>}{section === "live" && <section className="panel"><p className="kicker">Geaudit noodpad</p><h2>Avondondersteuning</h2><p>Een override vervangt alleen de fysieke scan van de huidige poort; deelnemersstatussen en afronding blijven apart verplicht. Stoppen is onomkeerbaar.</p><label className="field"><span>Verplichte reden</span><textarea rows={3} value={supportReason} onChange={(event) => setSupportReason(event.target.value)} /></label>{liveRuns.length === 0 ? <p>Geen live of gepauzeerde groepen.</p> : liveRuns.map((run) => <div className="incident-row" key={run.runId}><div><strong>{run.groupCode} · {run.portalName}</strong><small>{run.runStatus} · versie {run.runVersion}</small></div><div className="actions"><button className="btn outline" onClick={() => void liveCommand(run, "override")}>Scanoverride</button><button className="btn outline" onClick={() => void liveCommand(run, run.runStatus === "paused" ? "live" : "paused")}>{run.runStatus === "paused" ? "Hervatten" : "Pauzeren"}</button><button className="btn outline" onClick={() => { if (window.confirm("Groep definitief stoppen?")) void liveCommand(run, "stopped"); }}>Stoppen</button></div></div>)}</section>}</div></div>;
}
