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
  BellRing,
  MapPinned,
  MessageSquare,
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
import { MessengerInbox } from "@/components/admin/messenger-inbox";
import { ParticipantUpdates } from "@/components/admin/participant-updates";
import { StartScheduleBoard } from "@/components/admin/start-schedule-board";
import { NightMap } from "@/components/maps/night-map";
import { createClient } from "@/lib/supabase/client";

type Dashboard = {
  event: {
    title: string;
    phase: string;
    date: string;
    settingsVersion: number;
    groupRegistrationOpen: boolean;
    portalRegistrationOpen: boolean;
    maxGroupSize: number;
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
type LiveRun = {
  groupId: string;
  groupCode: string;
  systemCode?: string;
  displayName?: string | null;
  groupVersion: number;
  leaderEmail: string | null;
  responsibleAdults: Array<{ userId: string; email: string }>;
  status: string;
  runId: string | null;
  runStatus: "ready" | "live" | "paused" | null;
  runVersion: number | null;
  currentStopId: string | null;
  currentPortal: string | null;
  currentKind: "ordinary" | "finale" | null;
  currentCoordinate: [number, number] | null;
  lastConfirmedAt: string | null;
  elapsedSeconds: number | null;
  effectiveStopAt: string | null;
  expectedFinaleArrivalAt: string | null;
  childCount: number;
};
type LivePortal = { id: string; systemCode?: string; name: string; operationStatus: string; version: number; isFinal: boolean; activeReservations: number; expectedChildren: number };
type PortalOperation = { portalId: string; systemCode: string; name: string; operationStatus: string; contactName?: string | null; phone?: string | null; email?: string | null; formattedAddress: string; activeReservations: number; expectedChildren: number };
type LiveAlert = { id: string; priority: "urgent" | "warning" | "info"; code: string; message: string; groupId: string | null; portalId: string | null; createdAt: string };
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
type TogetherRequest = {
  id: string;
  version: number;
  status: "pending" | "accepted" | "rejected";
  requestedCode: string;
  registrationReference: string;
  sourceChildren: number;
  targetChildren: number;
  projectedChildren: number;
  maxGroupSize: number;
  limitOverridden: boolean;
  createdAt: string;
};
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
  pendingTogetherRequests: "Samenloopverzoeken",
  openTickets: "Open gesprekken",
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
    | "tickets"
    | "updates"
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
  const [notice, setNotice] = useState("");
  const [liveRuns, setLiveRuns] = useState<LiveRun[]>([]);
  const [livePortals, setLivePortals] = useState<LivePortal[]>([]);
  const [portalOperations, setPortalOperations] = useState<PortalOperation[]>([]);
  const [liveAlerts, setLiveAlerts] = useState<LiveAlert[]>([]);
  const [payments, setPayments] = useState<PaymentRow[]>([]);
  const [registrationChanges, setRegistrationChanges] = useState<
    RegistrationChange[]
  >([]);
  const [togetherRequests, setTogetherRequests] = useState<TogetherRequest[]>([]);
  const [groupSizeLimit, setGroupSizeLimit] = useState(10);
  const [supportReason, setSupportReason] = useState("");
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data } = await client
      .schema("api")
      .rpc("admin_dashboard", { _event_slug: eventSlug });
    const next = data as Dashboard;
    setDashboard(next);
    setGroupSizeLimit(next.event.maxGroupSize);
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

  async function loadLive() {
    const client = createClient();
    if (!client) return;
    const [cockpitResult, portalResult] = await Promise.all([
      client.schema("api").rpc("admin_evening_cockpit", { _event_slug: eventSlug }),
      client.schema("api").rpc("admin_portal_operations_snapshot", { _event_slug: eventSlug }),
    ]);
    if (cockpitResult.error) return setNotice("Live-overzicht is alleen beschikbaar voor avondondersteuning.");
    const cockpit = cockpitResult.data as { groups: LiveRun[]; portals: LivePortal[]; alerts: LiveAlert[] };
    setLiveRuns(cockpit.groups);
    setLivePortals(cockpit.portals);
    setLiveAlerts(cockpit.alerts);
    if (!portalResult.error) setPortalOperations(((portalResult.data as { portals?: PortalOperation[] } | null)?.portals ?? []));
  }

  async function startMessage(subjectKind: "group" | "portal", subjectId: string, label: string) {
    const body = window.prompt("Bericht aan " + label, "")?.trim();
    if (!body) return;
    const client = createClient();
    if (!client) return;
    const payload = { eventSlug, subjectKind, subjectId, body };
    const { error } = await client.schema("api").rpc("admin_messenger_create", {
      _event_slug: eventSlug,
      _subject_kind: subjectKind,
      _subject_id: subjectId,
      _body: body,
      _idempotency_key: crypto.randomUUID(),
      _request_hash: await digest(payload),
    });
    setNotice(error ? "Het bericht kon niet worden verstuurd." : "Bericht verstuurd en opgeslagen in Messenger.");
    if (!error) setSection("tickets");
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

  async function loadTogetherRequests() {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_together_requests_snapshot", { _event_slug: eventSlug });
    if (error)
      return setNotice(
        "Samenloopverzoeken zijn niet toegankelijk voor dit account.",
      );
    setTogetherRequests(data as TogetherRequest[]);
  }

  async function saveGroupSizeLimit() {
    if (!dashboard || groupSizeLimit < 2 || groupSizeLimit > 50)
      return setNotice("Kies een maximum tussen 2 en 50 kinderen.");
    const reason = window
      .prompt(
        "Waarom wijzig je de maximale groepsgrootte? (minimaal 10 tekens)",
      )
      ?.trim();
    if (!reason || reason.length < 10)
      return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_set_group_size_limit", {
        _event_slug: eventSlug,
        _max_group_size: groupSizeLimit,
        _expected_settings_version: dashboard.event.settingsVersion,
        _reason: reason,
      });
    setNotice(
      error
        ? error.message.includes("GROUP_SIZE_LIMIT_BELOW_ACTIVE_PARTY")
          ? "Er bestaat al een grotere samenloopgroep. Verhoog de limiet of laat de bestaande groepsgrens staan."
          : "De limiet kon niet worden gewijzigd; de actuele instellingen zijn opgehaald."
        : `De maximale groepsgrootte is nu ${groupSizeLimit} kinderen.`,
    );
    await Promise.all([load(), loadTogetherRequests()]);
  }

  async function decideTogetherRequest(
    request: TogetherRequest,
    decision: "accept" | "reject",
  ) {
    const override =
      decision === "accept" &&
      request.projectedChildren > request.maxGroupSize;
    const reason = window
      .prompt(
        override
          ? `Deze groep wordt ${request.projectedChildren} kinderen, boven de limiet van ${request.maxGroupSize}. Leg de veiligheidsafweging vast:`
          : "Leg de beslissing vast (minimaal 10 tekens):",
      )
      ?.trim();
    if (!reason || reason.length < 10)
      return setNotice("Een auditreden van minimaal tien tekens is verplicht.");
    if (
      override &&
      !window.confirm(
        `Limiet bewust overschrijden en ${request.projectedChildren} kinderen samen indelen? Start- en locatiecapaciteit blijven wel blokkeren.`,
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_decide_together_request", {
        _request_id: request.id,
        _expected_version: request.version,
        _decision: decision,
        _override_limit: override,
        _reason: reason,
      });
    setNotice(
      error
        ? `Samenloopbesluit geweigerd: ${error.message}`
        : decision === "accept"
          ? "Samenloopverzoek geaccepteerd en geaudit."
          : "Samenloopverzoek afgewezen en geaudit.",
    );
    await Promise.all([loadTogetherRequests(), load()]);
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
    if (!client || !run.runId || run.runVersion === null) return;
    if (command === "override" && !run.currentStopId)
      return setNotice("Deze groep heeft nu geen poort waarvoor een scanoverride nodig is.");
    if (supportReason.trim().length < 10)
      return setNotice(
        "Leg voor een noodhandeling minimaal tien tekens reden vast.",
      );
    const result =
      command === "override" && run.currentStopId
        ? await client.schema("api").rpc("run_support_override", {
            _run_id: run.runId,
            _stop_id: run.currentStopId,
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
        run.leaderEmail ?? "",
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

  async function redirectGroup(run: LiveRun, target: "ordinary" | "finale") {
    if (!run.runId || run.runVersion === null) return;
    if (supportReason.trim().length < 10)
      return setNotice("Leg voor een omleiding minimaal tien tekens reden vast.");
    let portalId: string | null = null;
    if (target === "ordinary") {
      const choices = livePortals.filter((portal) => !portal.isFinal && portal.operationStatus === "open");
      portalId = window.prompt(`ID van de gewenste gewone poort:\n${choices.map((portal) => `${portal.name}: ${portal.id}`).join("\n")}`)?.trim() ?? null;
      if (!portalId || !choices.some((portal) => portal.id === portalId))
        return setNotice("Kies een open, goedgekeurde gewone poort uit de lijst.");
    }
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("admin_redirect_group", {
      _run_id: run.runId,
      _target: target,
      _preferred_portal_id: portalId,
      _expected_run_version: run.runVersion,
      _reason: supportReason,
    });
    setNotice(error ? `Omleiding geweigerd: ${error.message}` : target === "finale" ? "De laatste poort is veilig gereserveerd en gepubliceerd." : "De gekozen volgende gewone poort is gereserveerd en gepubliceerd.");
    if (!error) setSupportReason("");
    await loadLive();
  }

  async function safeWithdraw(run: LiveRun) {
    if (!run.runId || run.runVersion === null) return;
    if (supportReason.trim().length < 10)
      return setNotice("Leg voor een veilige afmelding minimaal tien tekens reden vast.");
    const email = window.prompt(`Welke verantwoordelijke volwassene neemt de groep mee?\n${run.responsibleAdults.map((adult) => adult.email).join("\n")}`)?.trim().toLowerCase();
    const adult = run.responsibleAdults.find((candidate) => candidate.email.toLowerCase() === email);
    if (!adult) return setNotice("Kies een geregistreerde volwassene uit deze groep.");
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("admin_safe_withdraw_group", {
      _run_id: run.runId,
      _responsible_adult_user_id: adult.userId,
      _expected_run_version: run.runVersion,
      _reason: supportReason,
    });
    setNotice(error ? `Afmelding geweigerd: ${error.message}` : "De veilige afmelding en verantwoordelijke volwassene zijn vastgelegd.");
    if (!error) setSupportReason("");
    await loadLive();
  }

  async function activateEmergencyClosure() {
    if (supportReason.trim().length < 10)
      return setNotice("Leg voor de noodafsluiting minimaal tien tekens reden vast.");
    if (!window.confirm("De voorbereide noodafsluiting activeren voor alle actieve groepen?")) return;
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_activate_emergency_closure", {
      _event_slug: eventSlug,
      _reason: supportReason,
    });
    const result = data as { affectedGroups?: number } | null;
    setNotice(error ? `Noodafsluiting geweigerd: ${error.message}` : `Noodafsluiting geactiveerd voor ${result?.affectedGroups ?? 0} groepen.`);
    if (!error) setSupportReason("");
    await loadLive();
  }

  async function setPortalState(portal: LivePortal, state: "open" | "paused" | "closed") {
    if (supportReason.trim().length < 10 && state !== "open")
      return setNotice("Leg voor pauzeren of sluiten minimaal tien tekens reden vast.");
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("portal_set_operational_state", {
      _portal_id: portal.id,
      _state: state,
      _expected_version: portal.version,
      _reason: state === "open" ? "Opnieuw geopend vanuit avondcockpit" : supportReason,
    });
    setNotice(error ? `Poortstatus geweigerd: ${error.message}` : `${portal.name} staat nu op ${state}.`);
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
            void Promise.all([
              loadRegistrationChanges(),
              loadTogetherRequests(),
            ]);
          }}
        >
          <UsersRound />
          Inschrijvingen
        </button>
        {(capabilities.includes("event_admin") ||
          capabilities.includes("groups_manage") ||
          capabilities.includes("live_support")) && (
          <button
            className={section === "tickets" ? "active" : ""}
            onClick={() => setSection("tickets")}
          >
            <MessageSquare />
            Hulp & contact
          </button>
        )}
        {(capabilities.includes("event_admin") ||
          capabilities.includes("content_manage") ||
          capabilities.includes("live_support")) && (
          <button
            className={section === "updates" ? "active" : ""}
            onClick={() => setSection("updates")}
          >
            <BellRing />
            Deelnemersupdates
          </button>
        )}
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
          Startpunten en indeling
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
          Avondcockpit
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
                {(capabilities.includes("event_admin") ||
                  capabilities.includes("groups_manage")) && (
                  <article className="panel registration-channel group-limit-control">
                    <UsersRound />
                    <div>
                      <h3>Maximale groepsgrootte</h3>
                      <p>
                        Geldt voor het totaal aantal kinderen dat via een
                        samenloopcode wordt verbonden én voor de routeplanner.
                      </p>
                    </div>
                    <label className="field">
                      <span>Aantal kinderen</span>
                      <input
                        type="number"
                        min={2}
                        max={50}
                        value={groupSizeLimit}
                        onChange={(event) =>
                          setGroupSizeLimit(Number(event.target.value))
                        }
                      />
                    </label>
                    <button
                      className="btn outline"
                      disabled={
                        groupSizeLimit === dashboard.event.maxGroupSize
                      }
                      onClick={() => void saveGroupSizeLimit()}
                    >
                      Limiet opslaan
                    </button>
                  </article>
                )}
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
            <p className="kicker">Samenloopcode & capaciteit</p>
            <h2>Open samenloopverzoeken</h2>
            <p>
              Iedere geldige aanvraag wacht op een expliciet besluit. Controleer capaciteit,
              gezamenlijke tijden en veiligheid; een overschrijding vraagt bovendien een
              vastgelegde veiligheidsafweging.
            </p>
            {togetherRequests.filter((request) => request.status === "pending")
              .length === 0 ? (
              <p>Geen samenloopverzoeken die op controle wachten.</p>
            ) : (
              togetherRequests
                .filter((request) => request.status === "pending")
                .map((request) => (
                  <div className="incident-row" key={request.id}>
                    <div>
                      <strong>
                        {request.registrationReference} wil bij code {request.requestedCode}
                      </strong>
                      <small>
                        {request.sourceChildren} + {request.targetChildren} = {request.projectedChildren} kinderen · limiet {request.maxGroupSize}
                      </small>
                    </div>
                    <div className="actions">
                      <button
                        className="btn"
                        onClick={() =>
                          void decideTogetherRequest(request, "accept")
                        }
                      >
                        {request.projectedChildren > request.maxGroupSize
                          ? "Accepteren met uitzondering"
                          : "Accepteren"}
                      </button>
                      <button
                        className="text-link"
                        onClick={() =>
                          void decideTogetherRequest(request, "reject")
                        }
                      >
                        Afwijzen
                      </button>
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
        {section === "tickets" &&
          (capabilities.includes("event_admin") ||
            capabilities.includes("groups_manage") ||
            capabilities.includes("live_support")) && (
            <MessengerInbox eventSlug={eventSlug} />
          )}
        {section === "updates" &&
          (capabilities.includes("event_admin") ||
            capabilities.includes("content_manage") ||
            capabilities.includes("live_support")) && (
            <ParticipantUpdates eventSlug={eventSlug} />
          )}
        {section === "portals" && <PortalReviews eventSlug={eventSlug} />}
        {section === "content" && <ContentManagement eventSlug={eventSlug} />}
        {section === "access" && <AdminAccessManagement eventSlug={eventSlug} />}
        {section === "planner" && <StartScheduleBoard eventSlug={eventSlug} maxGroupSize={dashboard.event.maxGroupSize} />}
        {section === "live" && (
          <div className="admin-live-cockpit">
            <section className="panel">
              <div className="row-between"><div><p className="kicker">Actuele, bevestigde toestand</p><h2>Avondcockpit</h2></div><button className="btn outline" onClick={() => void loadLive()}><RefreshCw />Vernieuwen</button></div>
              <p>De kaart toont alleen serverbevestigde bestemmingen. Alle handmatige acties gebruiken dezelfde route-, veiligheids- en capaciteitscontroles als de dispatcher.</p>
              <NightMap variant="admin" ariaLabel="Cockpitkaart met actuele groepsbestemmingen" portals={liveRuns.filter((run) => run.currentCoordinate).map((run) => ({ id: run.groupId, name: `Groep ${run.groupCode}`, world: run.currentKind === "finale" ? "Laatste poort" : "Actuele poort", coordinate: run.currentCoordinate }))} />
            </section>
            <section className="panel">
              <p className="kicker">Meldingen op prioriteit</p><h2>Veiligheidssignalen</h2>
              {liveAlerts.length === 0 ? <p>Geen open signalen.</p> : liveAlerts.map((alert) => <div className={`form-${alert.priority === "urgent" ? "warning" : "notice"}`} key={alert.id}><strong>{alert.code}</strong><p>{alert.message}</p><small>{new Date(alert.createdAt).toLocaleString("nl-NL")}</small></div>)}
            </section>
            <section className="panel">
              <p className="kicker">Geaudit beheerpad</p><h2>Groepen</h2>
              <label className="field"><span>Verplichte reden voor een handmatige actie</span><textarea rows={3} value={supportReason} onChange={(event) => setSupportReason(event.target.value)} /></label>
              {liveRuns.length === 0 ? <p>Geen ingedeelde groepen.</p> : liveRuns.map((run) => (
                <div className="incident-row" key={run.groupId}>
                  <div><strong>{[run.systemCode || run.groupCode, run.displayName].filter(Boolean).join(" · ")} · {run.currentPortal ?? "geen actieve bestemming"}</strong><small>{run.runStatus ?? run.status} · {run.childCount} kinderen · laatst bevestigd {run.lastConfirmedAt ? new Date(run.lastConfirmedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" }) : "nog niet gestart"}</small><small>Stopgrens {run.effectiveStopAt ? new Date(run.effectiveStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" }) : "–"} · finale {run.expectedFinaleArrivalAt ? new Date(run.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" }) : "–"}</small></div>
                  <button className="btn outline" onClick={() => void startMessage("group", run.groupId, [run.systemCode || run.groupCode, run.displayName].filter(Boolean).join(" · "))}><MessageSquare />Bericht sturen</button>
                  {run.runId && run.runVersion !== null && <div className="actions">
                    {run.currentStopId && <button className="btn outline" onClick={() => void liveCommand(run, "override")}>Scanoverride</button>}
                    <button className="btn outline" onClick={() => void liveCommand(run, run.runStatus === "paused" ? "live" : "paused")}>{run.runStatus === "paused" ? "Hervatten" : "Pauzeren"}</button>
                    {run.runStatus === "live" && run.currentKind !== "finale" && <button className="btn outline" onClick={() => void redirectGroup(run, "ordinary")}>Andere gewone poort</button>}
                    {run.runStatus === "live" && run.currentKind !== "finale" && <button className="btn outline" onClick={() => void redirectGroup(run, "finale")}>Nu naar laatste poort</button>}
                    <button className="btn outline" onClick={() => void reassignLeader(run)}>Leider vervangen</button>
                    <button className="btn outline" onClick={() => void safeWithdraw(run)}>Veilig afmelden</button>
                  </div>}
                </div>
              ))}
            </section>
            <section className="panel"><p className="kicker">Poorten en finale-instroom</p><h2>Contact en capaciteit per poort</h2>{portalOperations.map((details) => { const portal = livePortals.find((item) => item.id === details.portalId); return <div className="incident-row portal-operation-card" key={details.portalId}><div><strong>{details.systemCode} · {details.name}</strong><span>{details.formattedAddress}</span><small>{details.contactName || "Geen contactpersoon opgegeven"} · {details.operationStatus} · {details.activeReservations} groepen · {details.expectedChildren} kinderen verwacht</small><div className="actions">{details.phone && <a className="text-link" href={"tel:" + details.phone.replace(/\s/g, "")}>{details.phone}</a>}{details.email && <a className="text-link" href={"mailto:" + details.email}>{details.email}</a>}<button className="btn outline" onClick={() => void startMessage("portal", details.portalId, details.systemCode + " · " + details.name)}><MessageSquare />Bericht sturen</button></div></div>{portal && <div className="actions"><button className="btn outline" disabled={portal.operationStatus === "open"} onClick={() => void setPortalState(portal, "open")}>Open</button><button className="btn outline" disabled={portal.operationStatus === "paused"} onClick={() => void setPortalState(portal, "paused")}>Na huidige groep pauzeren</button><button className="btn outline" disabled={portal.operationStatus === "closed"} onClick={() => void setPortalState(portal, "closed")}>Direct sluiten</button></div>}</div>; })}</section>
            <section className="panel emergency"><AlertTriangle /><div><p className="kicker">Alleen bij uitval van de laatste poort</p><h2>Voorbereide noodafsluiting</h2><p>Deze actie sluit de eindpoort, trekt reserveringen in, stopt de actieve routes en publiceert uitsluitend de vooraf ingestelde veilige verzamelinstructie.</p></div><button className="btn outline" onClick={() => void activateEmergencyClosure()}>Noodafsluiting activeren</button></section>
          </div>
        )}
      </div>
    </div>
  );
}
