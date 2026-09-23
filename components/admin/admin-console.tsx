"use client";

import { useCallback, useEffect, useState } from "react";
import Papa from "papaparse";
import {
  AlertTriangle,
  CheckCircle2,
  Database,
  FileText,
  House,
  LifeBuoy,
  MapPinned,
  RefreshCw,
  ShieldCheck,
  Upload,
  UserCog,
  UsersRound,
  WalletCards,
} from "lucide-react";
import { AdminAccessManagement } from "@/components/admin/admin-access-management";
import { PortalReviews } from "@/components/admin/portal-reviews";
import { ContentManagement } from "@/components/admin/content-management";
import { createClient } from "@/lib/supabase/client";
import { proposePlan, type PlanningInput } from "@/lib/domain/route-planner";

type Dashboard = {
  event: {
    title: string;
    phase: string;
    date: string;
    settingsVersion: number;
    groupRegistrationOpen: boolean;
    portalRegistrationOpen: boolean;
  };
  counts: Record<string, number>;
  imports: Array<{
    id: string;
    kind: string;
    status: string;
    createdAt: string;
  }>;
  recentActivity: Array<{
    action: string;
    resourceType: string;
    createdAt: string;
  }>;
};
type PlanResult = ReturnType<typeof proposePlan>;
type LiveRun = {
  groupId: string;
  groupCode: string;
  groupVersion: number;
  leaderEmail: string;
  runId: string;
  runStatus: "live" | "paused";
  runVersion: number;
  stopId: string;
  portalName: string;
};
type PaymentRow = {
  id: string;
  reference: string;
  registrationReference: string;
  amountCents: number;
  netCollectedCents: number;
  status: string;
  version: number;
  externalUrl?: string | null;
  reportedAt?: string | null;
  updatedAt: string;
};
type PlanningGroup = {
  id: string;
  code: string;
  status: string;
  planId: string;
  revision: number;
  planState: string;
  portalIds: string[];
};
type RegistrationChange = {
  id: string;
  version: number;
  status: string;
  kind: "correction" | "remove_child" | "cancellation";
  description: string;
  createdAt: string;
  registrationReference: string;
  registrationStatus: string;
  householdLabel: string;
  childName?: string | null;
  requestedAfterDeadline: boolean;
};
type PlanningSnapshot = Omit<
  PlanningInput,
  "targetGroupSize" | "maxGroupSize" | "stopsPerGroup"
> & { groups: PlanningGroup[] };

async function digest(value: unknown) {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(JSON.stringify(value)),
      ),
    ),
  ]
    .map((item) => item.toString(16).padStart(2, "0"))
    .join("");
}

const labels: Record<string, string> = {
  registrations: "Inschrijvingen",
  children: "Kinderen",
  portalApplications: "Poortaanvragen",
  approvedPortals: "Goedgekeurde poorten",
  groups: "Groepen",
  liveGroups: "Live groepen",
  openSupportCases: "Open incidenten",
  unconfirmedPayments: "Te controleren betalingen",
};
const paymentStatusLabels: Record<string, string> = {
  awaiting_link: "Wacht op Tikkie",
  awaiting_payment: "Wacht op betaling",
  reported: "Betaling gemeld",
  confirmed: "Betaald",
  partial: "Deels betaald",
  refund_due: "Terugbetaling nodig",
  refunded: "Terugbetaald",
  waived: "Geen betaling nodig",
};
const requiredColumns: Record<string, string[]> = {
  portals: ["street", "house_number", "postal_code"],
  registrations: ["email", "child_name"],
  payments: ["reference", "amount_cents"],
  graph: ["from", "to", "duration_seconds"],
  starts: ["name", "starts_at", "max_children"],
};

export function AdminConsole({ eventSlug, capabilities }: { eventSlug: string; capabilities: string[] }) {
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [section, setSection] = useState<
    | "overview"
    | "imports"
    | "registrations"
    | "payments"
    | "portals"
    | "planner"
    | "content"
    | "access"
    | "live"
  >("overview");
  const [importKind, setImportKind] = useState("portals");
  const [importResult, setImportResult] = useState<{
    status: string;
    errors: Array<{
      row: number;
      field?: string;
      code: string;
      message: string;
    }>;
  } | null>(null);
  const [plan, setPlan] = useState<PlanResult | null>(null);
  const [planIds, setPlanIds] = useState<string[]>([]);
  const [notice, setNotice] = useState("");
  const [liveRuns, setLiveRuns] = useState<LiveRun[]>([]);
  const [payments, setPayments] = useState<PaymentRow[]>([]);
  const [registrationChanges, setRegistrationChanges] = useState<
    RegistrationChange[]
  >([]);
  const [planningGroups, setPlanningGroups] = useState<PlanningGroup[]>([]);
  const [supportReason, setSupportReason] = useState("");
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data } = await client
      .schema("api")
      .rpc("admin_dashboard", { _event_slug: eventSlug });
    setDashboard(data as Dashboard);
  }, [eventSlug]);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function dryRun(file: File) {
    const parsed = Papa.parse<Record<string, string>>(await file.text(), {
      header: true,
      skipEmptyLines: true,
    });
    const errors: Array<{
      row: number;
      field?: string;
      code: string;
      message: string;
    }> = parsed.errors.map((error) => ({
      row: (error.row ?? 0) + 2,
      code: error.code,
      message: error.message,
    }));
    const columns = parsed.meta.fields ?? [];
    for (const field of requiredColumns[importKind])
      if (!columns.includes(field))
        errors.push({
          row: 1,
          field,
          code: "MISSING_COLUMN",
          message: `Kolom ${field} ontbreekt.`,
        });
    parsed.data.forEach((row, index) =>
      requiredColumns[importKind].forEach((field) => {
        if (!String(row[field] ?? "").trim())
          errors.push({
            row: index + 2,
            field,
            code: "REQUIRED",
            message: `${field} is verplicht.`,
          });
      }),
    );
    const sourceHash = await digest(await file.text());
    const client = createClient();
    if (!client) return;
    const result = await client.schema("api").rpc("admin_record_import", {
      _event_slug: eventSlug,
      _kind: importKind,
      _source_hash: sourceHash,
      _errors: errors,
    });
    if (result.error) return setNotice("Dry-run kon niet worden vastgelegd.");
    setImportResult({
      status: (result.data as { status: string }).status,
      errors,
    });
    setNotice("Dry-run opgeslagen; er zijn geen rijen toegepast.");
    await load();
  }

  async function calculatePlan() {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_planning_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice("Planningsinvoer is niet toegankelijk.");
    const snapshot = data as PlanningSnapshot;
    setPlanningGroups(snapshot.groups);
    const result = proposePlan({
      parties: snapshot.parties,
      starts: snapshot.starts,
      portals: snapshot.portals,
      targetGroupSize: 7,
      maxGroupSize: 10,
      stopsPerGroup: 6,
    });
    setPlan(result);
    setPlanIds([]);
    setNotice(
      result.conflicts.length
        ? "Het voorstel bevat blokkerende conflicten."
        : "Deterministisch voorstel berekend. Er is nog niets gepubliceerd.",
    );
  }

  async function savePlan() {
    if (!plan || plan.conflicts.length || !plan.groups.length) return;
    const client = createClient();
    if (!client) return;
    const inputHash = await digest(plan);
    const key = crypto.randomUUID();
    const { data, error } = await client.schema("api").rpc("admin_apply_plan", {
      _event_slug: eventSlug,
      _proposal: plan,
      _input_hash: inputHash,
      _idempotency_key: key,
      _request_hash: await digest({ plan, key }),
    });
    if (error) return setNotice(`Voorstel opslaan mislukt: ${error.message}`);
    setPlanIds((data as { planIds: string[] }).planIds);
    setNotice(
      "Voorstel als geldige routeversies opgeslagen. Publicatie is nog niet uitgevoerd.",
    );
    await load();
  }

  async function publishPlan() {
    const client = createClient();
    if (!client || !planIds.length) return;
    if (
      !window.confirm(
        "Publiceer deze routeversies? Deelnemers zien nog steeds alleen hun huidige bestemming.",
      )
    )
      return;
    const { error } = await client.schema("api").rpc("admin_publish_plans", {
      _event_slug: eventSlug,
      _plan_ids: planIds,
      _reason: "Expliciete publicatie na controle van het voorstel",
    });
    setNotice(
      error
        ? "Publicatie is geweigerd."
        : "Routeversies zijn gepubliceerd en geaudit.",
    );
    if (!error) setPlanIds([]);
    await load();
  }

  async function createPlanRevision(group: PlanningGroup) {
    const portalInput = window
      .prompt(
        "Poort-ID's in de nieuwe volgorde, door komma's gescheiden:",
        group.portalIds.join(", "),
      )
      ?.trim();
    if (!portalInput) return;
    const portalIds = portalInput
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    const reason = window
      .prompt("Waarom is deze routecorrectie nodig? (minimaal 10 tekens)")
      ?.trim();
    if (!reason || reason.length < 10)
      return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_create_plan_revision", {
        _group_id: group.id,
        _portal_ids: portalIds,
        _reason: reason,
      });
    if (error) return setNotice(`Correctieversie geweigerd: ${error.message}`);
    const revision = data as { planId: string; revision: number };
    setPlanIds((current) => [...new Set([...current, revision.planId])]);
    setPlanningGroups((current) =>
      current.map((item) =>
        item.id === group.id
          ? {
              ...item,
              planId: revision.planId,
              revision: revision.revision,
              planState: "valid",
              portalIds,
            }
          : item,
      ),
    );
    setNotice(
      `Routeversie ${revision.revision} opgeslagen als concept. De gepubliceerde route is niet gewijzigd.`,
    );
  }

  async function loadLive() {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_live_snapshot", { _event_slug: eventSlug });
    if (error)
      return setNotice(
        "Live-overzicht is alleen beschikbaar voor avondondersteuning.",
      );
    setLiveRuns(data as LiveRun[]);
  }

  async function loadPayments() {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_payments_snapshot", { _event_slug: eventSlug });
    if (error)
      return setNotice(
        "Het betaaloverzicht is alleen beschikbaar voor betaalbeheer.",
      );
    setPayments(data as PaymentRow[]);
  }

  async function loadRegistrationChanges() {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_registration_changes_snapshot", { _event_slug: eventSlug });
    if (error)
      return setNotice(
        "Wijzigingsverzoeken zijn alleen beschikbaar voor inschrijvingsbeheer.",
      );
    setRegistrationChanges(data as RegistrationChange[]);
  }

  async function setRegistrationChannel(
    channel: "groups" | "portals",
    open: boolean,
  ) {
    if (!dashboard) return;
    const label = channel === "groups" ? "groepsinschrijvingen" : "locatieaanmeldingen";
    const reason = window
      .prompt(
        `Waarom wil je de ${label} ${open ? "openzetten" : "sluiten"}? (minimaal 10 tekens)`,
      )
      ?.trim();
    if (!reason || reason.length < 10)
      return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    if (
      !window.confirm(
        `${open ? "Open" : "Sluit"} de ${label}? Deze wijziging is direct zichtbaar voor bezoekers.`,
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_set_registration_channel", {
        _event_slug: eventSlug,
        _channel: channel,
        _open: open,
        _expected_settings_version: dashboard.event.settingsVersion,
        _reason: reason,
      });
    setNotice(
      error
        ? error.message.includes("STALE_VERSION")
          ? "De instellingen zijn intussen gewijzigd. Het overzicht is vernieuwd; probeer het nogmaals."
          : `De ${label} konden niet worden gewijzigd.`
        : `De ${label} staan nu ${open ? "open" : "gesloten"}.`,
    );
    await load();
  }

  async function decideRegistrationChange(
    change: RegistrationChange,
    decision: "apply" | "close" | "reject",
  ) {
    const reason = window
      .prompt("Leg de beslissing vast (minimaal 10 tekens):")
      ?.trim();
    if (!reason || reason.length < 10)
      return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    if (
      decision === "apply" &&
      !window.confirm(
        change.kind === "cancellation"
          ? "Annuleer de inschrijving en maak zo nodig een expliciete terugbetaaltaak?"
          : "Verwijder dit kind en herbereken het bedrag met behoud van de betaalhistorie?",
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_decide_registration_change", {
        _case_id: change.id,
        _expected_case_version: change.version,
        _decision: decision,
        _reason: reason,
      });
    setNotice(
      error
        ? `Wijzigingsbesluit geweigerd: ${error.message}`
        : decision === "reject"
          ? "Verzoek afgewezen en geaudit."
          : "Verzoek afgehandeld; registratie en betaling zijn transactioneel bijgewerkt.",
    );
    await Promise.all([loadRegistrationChanges(), load(), loadPayments()]);
  }

  async function paymentCommand(
    payment: PaymentRow,
    command: "confirm" | "refund",
  ) {
    const defaultCents =
      command === "refund"
        ? payment.netCollectedCents
        : Math.max(0, payment.amountCents - payment.netCollectedCents);
    const amountInput = window
      .prompt(
        `${command === "refund" ? "Werkelijk terugbetaald" : "Werkelijk ontvangen"} bedrag in euro`,
        (defaultCents / 100).toFixed(2).replace(".", ","),
      )
      ?.trim();
    if (!amountInput || !/^\d+(?:[,.]\d{1,2})?$/.test(amountInput))
      return setNotice(
        "Vul een geldig positief bedrag met maximaal twee decimalen in.",
      );
    const amountCents = Math.round(Number(amountInput.replace(",", ".")) * 100);
    const externalReference = window
      .prompt("Externe Tikkie-/bankreferentie:")
      ?.trim();
    const reason = window.prompt("Verplichte auditreden:")?.trim();
    if (!externalReference || !reason || reason.length < 5 || amountCents <= 0)
      return setNotice(
        "Bedrag, externe referentie en minimaal vijf tekens reden zijn verplicht.",
      );
    if (
      !window.confirm(
        `${command === "refund" ? "Terugbetaling" : "Betaling"} van € ${(amountCents / 100).toFixed(2).replace(".", ",")} append-only vastleggen?`,
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const key = crypto.randomUUID();
    const requestHash = await digest({
      paymentId: payment.id,
      version: payment.version,
      amountCents,
      externalReference,
      reason,
      command,
    });
    const result =
      command === "confirm"
        ? await client.schema("api").rpc("payment_confirm_versioned", {
            _payment_request_id: payment.id,
            _expected_version: payment.version,
            _amount_cents: amountCents,
            _external_reference: externalReference,
            _reason: reason,
            _idempotency_key: key,
            _request_hash: requestHash,
          })
        : await client.schema("api").rpc("payment_refund", {
            _payment_request_id: payment.id,
            _amount_cents: amountCents,
            _external_reference: externalReference,
            _reason: reason,
            _idempotency_key: key,
            _request_hash: requestHash,
          });
    setNotice(
      result.error
        ? `Betaalmutatie geweigerd: ${result.error.message}`
        : "Betaalmutatie append-only opgeslagen en geaudit.",
    );
    await Promise.all([loadPayments(), load()]);
  }

  async function setPaymentLink(payment: PaymentRow) {
    const url = window
      .prompt(
        "Volledige Tikkie-link (https://…tikkie.me/…):",
        payment.externalUrl ?? "",
      )
      ?.trim();
    const reason = window
      .prompt("Auditreden voor deze betaallink (minimaal 10 tekens):")
      ?.trim();
    if (!url || !reason || reason.length < 10)
      return setNotice("Een geldige Tikkie-link en auditreden zijn verplicht.");
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("payment_set_external_link", {
        _payment_request_id: payment.id,
        _expected_version: payment.version,
        _external_url: url,
        _reason: reason,
      });
    setNotice(
      error
        ? `Betaallink geweigerd: ${error.message}`
        : "Tikkie-link veilig gekoppeld; de betaling blijft open tot handmatige controle.",
    );
    await loadPayments();
  }

  async function liveCommand(
    run: LiveRun,
    command: "override" | "paused" | "live" | "stopped",
  ) {
    const client = createClient();
    if (!client) return;
    if (supportReason.trim().length < 10)
      return setNotice(
        "Leg voor een noodhandeling minimaal tien tekens reden vast.",
      );
    const result =
      command === "override"
        ? await client.schema("api").rpc("run_support_override", {
            _run_id: run.runId,
            _stop_id: run.stopId,
            _expected_run_version: run.runVersion,
            _reason: supportReason,
          })
        : await client.schema("api").rpc("run_set_state", {
            _run_id: run.runId,
            _state: command,
            _expected_version: run.runVersion,
            _reason: supportReason,
          });
    setNotice(
      result.error
        ? `Noodhandeling geweigerd: ${result.error.message}`
        : "Noodhandeling uitgevoerd en in de auditlog vastgelegd.",
    );
    if (!result.error) setSupportReason("");
    await loadLive();
  }

  async function reassignLeader(run: LiveRun) {
    if (supportReason.trim().length < 10)
      return setNotice(
        "Leg voor een leiderwissel minimaal tien tekens reden vast.",
      );
    const email = window
      .prompt(
        "Geverifieerd accountadres van de nieuwe groepsleider:",
        run.leaderEmail,
      )
      ?.trim()
      .toLowerCase();
    if (!email || !/^\S+@\S+\.\S+$/.test(email) || email === run.leaderEmail)
      return setNotice("Kies een ander geldig en geverifieerd accountadres.");
    if (
      !window.confirm(
        `Leider van ${run.groupCode} direct vervangen door ${email}? De oude sessie verliest meteen mutatierecht.`,
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_assign_group_leader_by_email", {
        _group_id: run.groupId,
        _new_leader_email: email,
        _expected_group_version: run.groupVersion,
        _reason: supportReason,
      });
    setNotice(
      error
        ? `Leiderwissel geweigerd: ${error.message}`
        : "Leider vervangen; de vorige leider heeft direct geen mutatierecht meer.",
    );
    if (!error) setSupportReason("");
    await loadLive();
  }

  if (!dashboard)
    return (
      <div className="panel loading-state">
        <RefreshCw className="spin" />
        Beheergegevens ophalen…
      </div>
    );
  return (
    <div className="admin-shell">
      <aside className="admin-nav">
        <p className="kicker">Organisatie</p>
        <button
          className={section === "overview" ? "active" : ""}
          onClick={() => setSection("overview")}
        >
          <ShieldCheck />
          Overzicht
        </button>
        <button
          className={section === "imports" ? "active" : ""}
          onClick={() => setSection("imports")}
        >
          <Database />
          Imports
        </button>
        <button
          className={section === "registrations" ? "active" : ""}
          onClick={() => {
            setSection("registrations");
            void loadRegistrationChanges();
          }}
        >
          <UsersRound />
          Inschrijvingen
        </button>
        <button
          className={section === "payments" ? "active" : ""}
          onClick={() => {
            setSection("payments");
            void loadPayments();
          }}
        >
          <WalletCards />
          Betalingen
        </button>
        <button
          className={section === "portals" ? "active" : ""}
          onClick={() => setSection("portals")}
        >
          <House />
          Poortaanvragen
        </button>
        <button
          className={section === "planner" ? "active" : ""}
          onClick={() => setSection("planner")}
        >
          <MapPinned />
          Routeplanner
        </button>
        <button
          className={section === "content" ? "active" : ""}
          onClick={() => setSection("content")}
        >
          <FileText />
          Content & sponsors
        </button>
        {capabilities.includes("event_admin") && (
          <button
            className={section === "access" ? "active" : ""}
            onClick={() => setSection("access")}
          >
            <UserCog />
            Beheerders
          </button>
        )}
        <button
          className={section === "live" ? "active" : ""}
          onClick={() => {
            setSection("live");
            void loadLive();
          }}
        >
          <LifeBuoy />
          Avondhulp
        </button>
      </aside>
      <div className="admin-content">
        <div className="app-heading row-between">
          <div>
            <p className="kicker">
              {dashboard.event.phase} · {dashboard.event.date}
            </p>
            <h1>{dashboard.event.title}</h1>
          </div>
          <button className="btn outline" onClick={() => void load()}>
            <RefreshCw />
            Vernieuwen
          </button>
        </div>
        {notice && (
          <div className="form-notice" role="status">
            {notice}
          </div>
        )}
        {section === "overview" && (
          <>
            <section className="panel registration-controls">
              <p className="kicker">Aanmeldingen beheren</p>
              <div className="row-between registration-controls-heading">
                <div>
                  <h2>Open ieder kanaal op het juiste moment.</h2>
                  <p>Laat bijvoorbeeld eerst woningen, portieken en bedrijven aanmelden en open de groepsinschrijving pas later. Wijzigingen gelden direct en komen in de auditlog.</p>
                </div>
              </div>
              <div className="settings-grid">
                <article className="panel registration-channel">
                  <UsersRound />
                  <div>
                    <h3>Groepsinschrijvingen</h3>
                    <p>Voor ouders die kinderen willen inschrijven om mee te lopen.</p>
                  </div>
                  <button
                    className={`btn ${dashboard.event.groupRegistrationOpen ? "outline" : ""}`}
                    role="switch"
                    aria-checked={dashboard.event.groupRegistrationOpen}
                    onClick={() => void setRegistrationChannel("groups", !dashboard.event.groupRegistrationOpen)}
                  >
                    {dashboard.event.groupRegistrationOpen ? "Open · klik om te sluiten" : "Gesloten · klik om te openen"}
                  </button>
                </article>
                <article className="panel registration-channel">
                  <House />
                  <div>
                    <h3>Locatieaanmeldingen</h3>
                    <p>Voor woningen, portieken, winkels en bedrijven die een poort willen worden.</p>
                  </div>
                  <button
                    className={`btn ${dashboard.event.portalRegistrationOpen ? "outline" : ""}`}
                    role="switch"
                    aria-checked={dashboard.event.portalRegistrationOpen}
                    onClick={() => void setRegistrationChannel("portals", !dashboard.event.portalRegistrationOpen)}
                  >
                    {dashboard.event.portalRegistrationOpen ? "Open · klik om te sluiten" : "Gesloten · klik om te openen"}
                  </button>
                </article>
              </div>
            </section>
            <div className="dashboard-metrics">
              {Object.entries(dashboard.counts).map(([key, value]) => (
                <div className="metric" key={key}>
                  <strong>{value}</strong>
                  <span>{labels[key] ?? key}</span>
                </div>
              ))}
            </div>
            <section className="panel activity">
              <p className="kicker">Recente auditactiviteit</p>
              {dashboard.recentActivity.length ? (
                dashboard.recentActivity.map((item, index) => (
                  <div
                    className="activity-row"
                    key={`${item.createdAt}-${index}`}
                  >
                    <CheckCircle2 />
                    <div>
                      <strong>{item.action}</strong>
                      <small>
                        {item.resourceType} ·{" "}
                        {new Date(item.createdAt).toLocaleString("nl-NL")}
                      </small>
                    </div>
                  </div>
                ))
              ) : (
                <p>Nog geen activiteit.</p>
              )}
            </section>
          </>
        )}
        {section === "imports" && (
          <section className="panel">
            <p className="kicker">Altijd eerst valideren</p>
            <h2>CSV dry-run</h2>
            <p>
              Een dry-run schrijft alleen een batch en rijgebonden fouten;
              operationele tabellen blijven onaangeraakt.
            </p>
            <label className="field">
              <span>Type bestand</span>
              <select
                value={importKind}
                onChange={(event) => setImportKind(event.target.value)}
              >
                {Object.keys(requiredColumns).map((kind) => (
                  <option key={kind}>{kind}</option>
                ))}
              </select>
            </label>
            <label className="import-drop">
              <Upload />
              <span>Kies CSV voor controle</span>
              <input
                type="file"
                accept=".csv,text/csv"
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  if (file) void dryRun(file);
                }}
              />
            </label>
            {importResult && (
              <div>
                <h3>Status: {importResult.status}</h3>
                {importResult.errors.map((error, index) => (
                  <p className="form-error" key={index}>
                    Rij {error.row}
                    {error.field ? `, ${error.field}` : ""}: {error.message}
                  </p>
                ))}
              </div>
            )}
            <div className="separator" />
            <h3>Laatste batches</h3>
            {dashboard.imports.map((item) => (
              <div className="summary-row" key={item.id}>
                <span>
                  {item.kind} ·{" "}
                  {new Date(item.createdAt).toLocaleString("nl-NL")}
                </span>
                <strong>{item.status}</strong>
              </div>
            ))}
          </section>
        )}
        {section === "payments" && (
          <section className="panel">
            <p className="kicker">Handmatige Tikkie-controle</p>
            <h2>Betalingen en terugbetalingen</h2>
            <p>
              Alle bedragen komen uit het append-only grootboek. Een
              oudermelding is geen bevestiging; een terugbetaling wordt pas
              vastgelegd nadat die buiten de app werkelijk is uitgevoerd.
            </p>
            {payments.length === 0 ? (
              <p>Geen betaalverzoeken.</p>
            ) : (
              payments.map((payment) => (
                <div className="incident-row" key={payment.id}>
                  <div>
                    <strong>
                      {payment.reference} · {payment.registrationReference}
                    </strong>
                    <small>
                      {paymentStatusLabels[payment.status] ?? payment.status} · ontvangen €{" "}
                      {(payment.netCollectedCents / 100)
                        .toFixed(2)
                        .replace(".", ",")}{" "}
                      van €{" "}
                      {(payment.amountCents / 100).toFixed(2).replace(".", ",")}{" "}
                      · versie {payment.version}
                    </small>
                  </div>
                  <div className="actions">
                    {["awaiting_link", "awaiting_payment"].includes(
                      payment.status,
                    ) && (
                      <button
                        className="btn outline"
                        onClick={() => void setPaymentLink(payment)}
                      >
                        Tikkie-link instellen
                      </button>
                    )}
                    {!["confirmed", "refunded", "waived"].includes(
                      payment.status,
                    ) && (
                      <button
                        className="btn outline"
                        onClick={() => void paymentCommand(payment, "confirm")}
                      >
                        Bevestig ontvangst
                      </button>
                    )}
                    {payment.netCollectedCents > 0 &&
                      payment.status !== "refunded" && (
                        <button
                          className="btn outline"
                          onClick={() => void paymentCommand(payment, "refund")}
                        >
                          Leg terugbetaling vast
                        </button>
                      )}
                  </div>
                </div>
              ))
            )}
          </section>
        )}
        {section === "registrations" && (
          <section className="panel">
            <p className="kicker">Gecontroleerde wijzigingen</p>
            <h2>Correcties en annuleringen</h2>
            <p>
              Een verzoek wijzigt nooit direct deelnemers of bedragen.
              Goedkeuring maakt een revisie; een overbetaling wordt zichtbaar
              als terugbetaaltaak en de bestaande betaalregels blijven intact.
            </p>
            {registrationChanges.length === 0 ? (
              <p>Geen wijzigingsverzoeken.</p>
            ) : (
              registrationChanges.map((change) => (
                <div className="incident-row" key={change.id}>
                  <div>
                    <strong>
                      {change.registrationReference} · {change.householdLabel}
                    </strong>
                    <small>
                      {change.kind.replaceAll("_", " ")}
                      {change.childName ? ` · ${change.childName}` : ""} ·{" "}
                      {change.status}
                      {change.requestedAfterDeadline ? " · na deadline" : ""}
                    </small>
                    <p>{change.description}</p>
                  </div>
                  {["open", "acknowledged"].includes(change.status) && (
                    <div className="actions">
                      <button
                        className="btn outline"
                        onClick={() =>
                          void decideRegistrationChange(
                            change,
                            change.kind === "correction" ? "close" : "apply",
                          )
                        }
                      >
                        {change.kind === "correction"
                          ? "Sluit als afgehandeld"
                          : "Controleer en pas toe"}
                      </button>
                      <button
                        className="text-link"
                        onClick={() =>
                          void decideRegistrationChange(change, "reject")
                        }
                      >
                        Afwijzen
                      </button>
                    </div>
                  )}
                </div>
              ))
            )}
          </section>
        )}
        {section === "portals" && <PortalReviews eventSlug={eventSlug} />}
        {section === "content" && <ContentManagement eventSlug={eventSlug} />}
        {section === "access" && <AdminAccessManagement eventSlug={eventSlug} />}
        {section === "planner" && (
          <section className="panel">
            <p className="kicker">Deterministisch · versieerbaar</p>
            <h2>Indelingsvoorstel</h2>
            <p>
              De planner houdt inschrijvingen met dezelfde viertekencode bij elkaar, respecteert groeps- en
              startcapaciteit, controleert tijdvensters en verdeelt zes
              verschillende werelden. Conflicten blokkeren opslag.
            </p>
            <div className="actions">
              <button className="btn" onClick={() => void calculatePlan()}>
                Bereken voorstel
              </button>
              <button
                className="btn outline"
                disabled={!plan?.groups.length || !!plan.conflicts.length}
                onClick={() => void savePlan()}
              >
                Sla als conceptversies op
              </button>
              <button
                className="btn outline"
                disabled={!planIds.length}
                onClick={() => void publishPlan()}
              >
                Publiceer expliciet
              </button>
            </div>
            {plan && (
              <div className="planner-result">
                {plan.conflicts.map((conflict) => (
                  <div
                    className="form-warning"
                    key={`${conflict.code}-${conflict.subjectId}`}
                  >
                    <AlertTriangle />
                    {conflict.code}: {conflict.message}
                  </div>
                ))}
                {plan.groups.map((group) => (
                  <div className="summary-row" key={group.key}>
                    <span>
                      {group.key}: {group.childCount} kinderen,{" "}
                      {group.portalIds.length} poorten
                    </span>
                    <strong>{group.partyIds.length} inschrijving(en)</strong>
                  </div>
                ))}
              </div>
            )}
            {planningGroups.length > 0 && (
              <div className="planner-result">
                <div className="separator" />
                <h3>Bestaande routeversies</h3>
                <p>
                  Een correctie maakt altijd een nieuwe conceptversie. De
                  huidige publicatie en reeds gestarte runs blijven intact.
                </p>
                {planningGroups.map((group) => (
                  <div className="summary-row" key={group.id}>
                    <span>
                      {group.code} · versie {group.revision} · {group.planState}{" "}
                      · {group.portalIds.length} poorten
                    </span>
                    <button
                      className="text-link"
                      onClick={() => void createPlanRevision(group)}
                    >
                      Maak correctieversie
                    </button>
                  </div>
                ))}
              </div>
            )}
          </section>
        )}
        {section === "live" && (
          <section className="panel">
            <p className="kicker">Geaudit noodpad</p>
            <h2>Avondondersteuning</h2>
            <p>
              Een override vervangt alleen de fysieke scan van de huidige poort;
              deelnemersstatussen en afronding blijven apart verplicht. Stoppen
              is onomkeerbaar.
            </p>
            <label className="field">
              <span>Verplichte reden</span>
              <textarea
                rows={3}
                value={supportReason}
                onChange={(event) => setSupportReason(event.target.value)}
              />
            </label>
            {liveRuns.length === 0 ? (
              <p>Geen live of gepauzeerde groepen.</p>
            ) : (
              liveRuns.map((run) => (
                <div className="incident-row" key={run.runId}>
                  <div>
                    <strong>
                      {run.groupCode} · {run.portalName}
                    </strong>
                    <small>
                      {run.runStatus} · versie {run.runVersion} · leider{" "}
                      {run.leaderEmail}
                    </small>
                  </div>
                  <div className="actions">
                    <button
                      className="btn outline"
                      onClick={() => void liveCommand(run, "override")}
                    >
                      Scanoverride
                    </button>
                    <button
                      className="btn outline"
                      onClick={() =>
                        void liveCommand(
                          run,
                          run.runStatus === "paused" ? "live" : "paused",
                        )
                      }
                    >
                      {run.runStatus === "paused" ? "Hervatten" : "Pauzeren"}
                    </button>
                    <button
                      className="btn outline"
                      onClick={() => void reassignLeader(run)}
                    >
                      Leider vervangen
                    </button>
                    <button
                      className="btn outline"
                      onClick={() => {
                        if (window.confirm("Groep definitief stoppen?"))
                          void liveCommand(run, "stopped");
                      }}
                    >
                      Stoppen
                    </button>
                  </div>
                </div>
              ))
            )}
          </section>
        )}
      </div>
    </div>
  );
}
