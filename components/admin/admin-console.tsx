"use client";

import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Papa from "papaparse";
import { paymentAmount, type PaymentBatch } from "@/components/payments/payment-details";
import {
  AlertTriangle,
  ArrowRight,
  CalendarClock,
  CheckCircle2,
  Database,
  FileText,
  House,
  LifeBuoy,
  BellRing,
  Play,
  SlidersHorizontal,
  MapPinned,
  MessageSquare,
  Menu,
  X,
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
import { GroupCompositionBoard } from "@/components/admin/group-composition-board";
import { NightMap } from "@/components/maps/night-map";
import { normalizeActivity } from "@/lib/domain/activity-labels";
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
type PortalOperation = { portalId: string; systemCode: string; name: string; world: string; worldSlug: string; operationStatus: string; version: number; isFinal: boolean; contactName?: string | null; phone?: string | null; email?: string | null; formattedAddress: string | null; locationVerified: boolean; coordinate: [number, number] | null; activeReservations: number; expectedChildren: number };
type LiveAlert = { id: string; priority: "urgent" | "warning" | "info"; code: string; message: string; groupId: string | null; portalId: string | null; createdAt: string };
type PaymentRow = {
  registrationId: string;
  childPaymentMode: boolean;
  parentName?: string | null;
  parentEmail?: string | null;
  householdLabel?: string | null;
  groupCode?: string | null;
  groupName?: string | null;
  batch?: PaymentBatch | null;
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
type ChildPaymentBatch = {
  legacy?: boolean;
  id: string;
  version: number;
  totalAmountCents: number;
  status: "awaiting_payment" | "reported" | "confirmed" | "needs_review";
  childNames: string[];
  anchorChildId: string;
  anchorChildName: string;
  externalUrl: string | null;
  canPay: boolean;
};
type ChildPaymentRow = {
  childId: string;
  firstName: string;
  registrationId: string;
  registrationReference: string;
  parentName: string | null;
  parentEmail: string | null;
  groupCode: string | null;
  groupName: string | null;
  amountCents: number;
  status: "awaiting_link" | "awaiting_payment" | "reported" | "confirmed" | "waived" | "cancelled" | "needs_review";
  version: number;
  batch: ChildPaymentBatch | null;
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
type AdminRegistration = {
  id: string;
  reference: string;
  status: string;
  submittedAt: string | null;
  updatedAt: string;
  parentName: string;
  parentEmail: string;
  phone: string | null;
  groupId: string | null;
  groupCode: string | null;
  groupName: string;
  togetherCode: string | null;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  childCount: number;
  children: Array<{ id: string; name: string; age: number | null; accessibilityNote: string | null; status: string }>;
  priceCents: number;
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
const sectionMeta = {
  overview: { kicker: "De avond · voorbereiding", title: "De nacht in beeld.", description: "Alles wat nu aandacht vraagt, bij elkaar." },
  imports: { kicker: "Beheer · gegevens", title: "Imports", description: "Controleer bronbestanden voordat gegevens worden toegepast." },
  registrations: { kicker: "Deelnemers · groepen", title: "Inschrijvingen", description: "Iedere inschrijving direct in beeld, met groep en deelnemers." },
  groups: { kicker: "Deelnemers · indeling", title: "Groepsindeling", description: "Maak wandelgroepen en zie direct hoeveel kinderen iedere groep telt." },
  payments: { kicker: "Deelnemers · betalingen", title: "Betalingen", description: "Tikkies, ontvangsten en uitzonderingen per kind." },
  portals: { kicker: "De avond · voorbereiding", title: "Poorten", description: "Beoordeel huizen en houd hun gegevens actueel." },
  planner: { kicker: "De avond · voorbereiding", title: "Startpuntregie", description: "Verdeel groepen veilig over de wijk en de beschikbare tijden." },
  content: { kicker: "Website · redactie", title: "Content & sponsors", description: "Beheer zichtbare informatie en partners." },
  access: { kicker: "Organisatie · toegang", title: "Beheerders", description: "Bepaal wie welk onderdeel van de nacht mag beheren." },
  live: { kicker: "De avond · live", title: "Avondcockpit", description: "Volg alleen serverbevestigde voortgang en handel uitzonderingen af." },
  tickets: { kicker: "Eén doorlopend gesprek", title: "Messenger", description: "Nieuwe berichten, lopende gesprekken en antwoorden in één inbox." },
  updates: { kicker: "Communicatie · gericht", title: "Gerichte updates", description: "Bereik precies de groepen of huizen waarvoor een wijziging geldt." },
  simulation: { kicker: "Veilig testen", title: "Avondsimulatie", description: "Controleer de actuele plannercondities voordat de avond live gaat." },
  settings: { kicker: "Grenzen en toegang", title: "Instellingen", description: "Beheer inschrijfkanalen, groepsgrenzen en operationele voorbereiding." },
} as const;
const paymentStatusLabels: Record<string, string> = {
  cancelled: "Afgezegd",
  needs_review: "Controle nodig",
  awaiting_link: "Wacht op Tikkie",
  awaiting_payment: "Wacht op betaling",
  reported: "Betaling gemeld",
  confirmed: "Betaald",
  partial: "Deels betaald",
  refund_due: "Terugbetaling nodig",
  refunded: "Terugbetaald",
  waived: "Geen betaling nodig",
};
type PaymentViewStatus = "waiting" | "unpaid" | "paid";
const paymentViewStatusLabels: Record<PaymentViewStatus, string> = {
  waiting: "Wachtend",
  unpaid: "Niet betaald",
  paid: "Betaald",
};
function paymentViewStatus(payment: ChildPaymentRow): PaymentViewStatus {
  if (["reported", "needs_review"].includes(payment.status)) return "waiting";
  if (["confirmed", "waived"].includes(payment.status)) return "paid";
  return "unpaid";
}
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
    | "groups"
    | "payments"
    | "portals"
    | "planner"
    | "content"
    | "access"
    | "live"
    | "tickets"
    | "updates"
    | "simulation"
    | "settings"
  >("overview");
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const navigationRef = useRef<HTMLElement>(null);
  const menuButtonRef = useRef<HTMLButtonElement>(null);
  const closeMenuRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!mobileNavOpen) return;
    const menuButton = menuButtonRef.current;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    closeMenuRef.current?.focus();
    const desktop = window.matchMedia("(min-width: 1101px)");
    const closeOnDesktop = () => {
      if (desktop.matches) setMobileNavOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setMobileNavOpen(false);
      }
      if (event.key !== "Tab") return;
      const focusable = Array.from(navigationRef.current?.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), [tabindex="0"]',
      ) ?? []).filter((element) => element.getClientRects().length > 0);
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    };
    desktop.addEventListener("change", closeOnDesktop);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      desktop.removeEventListener("change", closeOnDesktop);
      document.removeEventListener("keydown", onKeyDown);
      menuButton?.focus();
    };
  }, [mobileNavOpen]);

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
  const [portalRealtimeTopic, setPortalRealtimeTopic] = useState<string | null>(null);
  const [liveConnection, setLiveConnection] = useState<"connecting" | "live" | "offline">("connecting");
  const [liveConnectionRetry, setLiveConnectionRetry] = useState(0);
  const [liveAlerts, setLiveAlerts] = useState<LiveAlert[]>([]);
  const portalMapPortals = useMemo(() => portalOperations.map((portal) => ({
    id: portal.portalId,
    code: portal.systemCode,
    name: portal.name,
    world: portal.world,
    coordinate: portal.coordinate,
    address: portal.formattedAddress ?? undefined,
    contactName: portal.contactName ?? undefined,
    phone: portal.phone ?? undefined,
    status: portal.operationStatus,
    isFinal: portal.isFinal,
  })), [portalOperations]);
  const [payments, setPayments] = useState<PaymentRow[]>([]);
  const [childPayments, setChildPayments] = useState<ChildPaymentRow[]>([]);
  const [paymentSearch, setPaymentSearch] = useState("");
  const [paymentStatusFilter, setPaymentStatusFilter] = useState<"all" | PaymentViewStatus>("all");
  const [selectedPaymentIds, setSelectedPaymentIds] = useState<string[]>([]);
  const [paymentPayerId, setPaymentPayerId] = useState("");
  const [paymentLink, setPaymentLink] = useState("");
  const [paymentBusy, setPaymentBusy] = useState(false);
  const paymentMutation = useRef(false);
  const paymentPublishKey = useRef<{ payload: string; key: string } | null>(null);
  const selectedPayments = childPayments.filter((payment) => selectedPaymentIds.includes(payment.childId));
  const selectedPayer = selectedPayments.find((payment) => payment.childId === paymentPayerId) ?? selectedPayments[0];
  const selectedPaymentTotal = selectedPayments.reduce((total, payment) => total + payment.amountCents, 0);
  const paymentQuery = paymentSearch.trim().toLocaleLowerCase("nl");
  const filteredPayments = childPayments.filter((payment) =>
    (paymentStatusFilter === "all" || paymentViewStatus(payment) === paymentStatusFilter) &&
    [payment.firstName, payment.parentName, payment.parentEmail, payment.groupCode, payment.groupName, payment.registrationReference]
      .some((value) => value?.toLocaleLowerCase("nl").includes(paymentQuery)),
  );
  const paymentGroups = Array.from(filteredPayments.reduce((groups, payment) => {
    const existing = groups.get(payment.registrationId) ?? [];
    existing.push(payment);
    groups.set(payment.registrationId, existing);
    return groups;
  }, new Map<string, ChildPaymentRow[]>()).entries());
  const [registrationChanges, setRegistrationChanges] = useState<
    RegistrationChange[]
  >([]);
  const [registrations, setRegistrations] = useState<AdminRegistration[]>([]);
  const [registrationsLoading, setRegistrationsLoading] = useState(false);
  const [registrationSearch, setRegistrationSearch] = useState("");
  const [selectedRegistrationId, setSelectedRegistrationId] = useState<string | null>(null);
  const registrationChildCount = registrations.reduce((total, registration) => total + registration.childCount, 0);
  const [togetherRequests, setTogetherRequests] = useState<TogetherRequest[]>([]);
  const [groupSizeLimit, setGroupSizeLimit] = useState(10);
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
  const loadLive = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const [cockpitResult, portalResult] = await Promise.all([
      client.schema("api").rpc("admin_evening_cockpit", { _event_slug: eventSlug }),
      client.schema("api").rpc("admin_portal_operations_snapshot", { _event_slug: eventSlug }),
    ]);
    if (!cockpitResult.error) {
      const cockpit = cockpitResult.data as { groups: LiveRun[]; portals: LivePortal[]; alerts: LiveAlert[] };
      setLiveRuns(cockpit.groups);
      setLivePortals(cockpit.portals);
      setLiveAlerts(cockpit.alerts);
    }
    if (!portalResult.error) {
      const portalSnapshot = portalResult.data as { realtimeTopic?: string; portals?: PortalOperation[] } | null;
      setPortalOperations(portalSnapshot?.portals ?? []);
      setPortalRealtimeTopic(portalSnapshot?.realtimeTopic ?? null);
    }
    if (cockpitResult.error && portalResult.error) setNotice("Live-overzicht is alleen beschikbaar voor bevoegde avondbeheerders.");
  }, [eventSlug]);
  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load();
      void loadLive();
    }, 0);
    const poll = window.setInterval(() => {
      if (section === "overview" || section === "live") void loadLive();
    }, 20_000);
    return () => {
      window.clearTimeout(timer);
      window.clearInterval(poll);
    };
  }, [load, loadLive, section]);
  useEffect(() => {
    const client = createClient();
    if (!client || !portalRealtimeTopic) return;
    const channel = client.channel(portalRealtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void loadLive())
      .subscribe((status: string) => setLiveConnection(status === "SUBSCRIBED" ? "live" : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "offline" : "connecting"));
    return () => { void client.removeChannel(channel); };
  }, [liveConnectionRetry, loadLive, portalRealtimeTopic]);

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
    const [children, legacy] = await Promise.all([
      client.schema("api").rpc("admin_child_payments_snapshot", { _event_slug: eventSlug }),
      client.schema("api").rpc("admin_payments_snapshot", { _event_slug: eventSlug }),
    ]);
    if (children.error || legacy.error) return setNotice("Het betaaloverzicht kon niet worden geladen. Controleer je betaalbeheerrechten of probeer opnieuw.");
    setChildPayments(children.data as ChildPaymentRow[]);
    setPayments(legacy.data as PaymentRow[]);
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

  async function loadRegistrations() {
    const client = createClient();
    if (!client) return;
    setRegistrationsLoading(true);
    const { data, error } = await client
      .schema("api")
      .rpc("admin_registrations_snapshot", { _event_slug: eventSlug });
    setRegistrationsLoading(false);
    if (error)
      return setNotice(
        "De inschrijvingen konden niet worden opgehaald. Controleer je beheerrechten of probeer opnieuw.",
      );
    setRegistrations((data ?? []) as AdminRegistration[]);
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
    if (!dashboard || groupSizeLimit < 2 || groupSizeLimit > 20)
      return setNotice("Kies een maximum tussen 2 en 20 kinderen.");
    const client = createClient();
    if (!client) return;
    const { error } = await client
      .schema("api")
      .rpc("admin_set_group_size_limit", {
        _event_slug: eventSlug,
        _max_group_size: groupSizeLimit,
        _expected_settings_version: dashboard.event.settingsVersion,
        _reason: "Maximale groepsgrootte gewijzigd via beheeromgeving",
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
    if (decision === "accept" && request.projectedChildren > 20)
      return setNotice("Een groep mag maximaal 20 kinderen hebben. Deel deze gezinnen in afzonderlijke groepen in.");
    const override =
      decision === "accept" &&
      request.projectedChildren > request.maxGroupSize;
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
        _reason: override ? "Samenloop geaccepteerd met bevestigde limietuitzondering" : `Samenloopverzoek ${decision === "accept" ? "geaccepteerd" : "afgewezen"}`,
      });
    setNotice(
      error
        ? `Samenloopbesluit geweigerd: ${error.message}`
        : decision === "accept"
          ? "Samenloopverzoek geaccepteerd."
          : "Samenloopverzoek afgewezen.",
    );
    await Promise.all([loadTogetherRequests(), load()]);
  }

  async function setRegistrationChannel(
    channel: "groups" | "portals",
    open: boolean,
  ) {
    if (!dashboard) return;
    const label = channel === "groups" ? "groepsinschrijvingen" : "locatieaanmeldingen";
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
        _reason: `${label} ${open ? "geopend" : "gesloten"} via beheeromgeving`,
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
        _reason: `Wijzigingsverzoek ${decision} via beheeromgeving`,
      });
    setNotice(
      error
        ? `Wijzigingsbesluit geweigerd: ${error.message}`
        : decision === "reject"
          ? "Verzoek afgewezen."
          : "Verzoek afgehandeld; registratie en betaling zijn transactioneel bijgewerkt.",
    );
    await Promise.all([loadRegistrationChanges(), load(), loadPayments()]);
  }

  async function paymentCommand(
    payment: PaymentRow,
    command: "confirm" | "refund",
  ) {
    if (paymentMutation.current) return;
    if (payment.childPaymentMode) return setNotice("Verwerk deze betaling of terugbetaling bij de gekoppelde kinderen; de inschrijving kan niet in één keer worden afgehandeld.");
    const batch = command === "confirm" ? payment.batch : null;
    const defaultCents = batch ? batch.totalAmountCents :
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
    if (batch && amountCents !== batch.totalAmountCents) return setNotice(`Bevestig het volledige gezamenlijke bedrag van ${paymentAmount(batch.totalAmountCents)}. Controleer een afwijkende ontvangst eerst met de betrokken gezinnen.`);
    const externalReference = window
      .prompt("Externe Tikkie-/bankreferentie:")
      ?.trim();
    const reason = command === "refund"
      ? "Terugbetaling vastgelegd via beheeromgeving"
      : "Betaling bevestigd via beheeromgeving";
    if (!externalReference || amountCents <= 0)
      return setNotice("Bedrag en externe referentie zijn verplicht.");
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
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
    const result = batch
      ? await client.schema("api").rpc("admin_payment_batch_confirm", {
          _batch_id: batch.id,
          _expected_version: batch.version,
          _amount_cents: amountCents,
          _external_reference: externalReference,
          _reason: reason,
          _idempotency_key: key,
        })
      : command === "confirm"
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
    } catch { setNotice("De verbinding is onderbroken. Vernieuw het overzicht en controleer de ontvangst voordat je opnieuw bevestigt."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function clearLegacyPayment(payment: PaymentRow) {
    if (paymentMutation.current || payment.childPaymentMode) return;
    const reason = "Eerdere Tikkie voor inschrijving ingetrokken";
    if (!window.confirm("Deactiveer de oude Tikkie zelf bij Tikkie. Deze actie trekt de link voor de hele inschrijving in, zodat je de kinderen apart kunt selecteren. Er wordt geen betaling teruggedraaid. Doorgaan?")) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_clear_legacy", { _registration_id: payment.registrationId, _expected_version: payment.version, _reason: reason });
      setNotice(error ? `Intrekken geweigerd: ${error.message}` : "Eerdere Tikkie ingetrokken. Deactiveer ook de externe Tikkie voordat je nieuwe links per kind verstuurt.");
      if (!error) setSelectedPaymentIds([]);
      await loadPayments();
    } catch { setNotice("De verbinding is onderbroken. Vernieuw het overzicht om de status van de eerdere Tikkie te controleren."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function confirmChildPayment(batch: ChildPaymentBatch, command: "confirm" | "refund" = "confirm") {
    if (paymentMutation.current) return;
    const amount = window.prompt(command === "refund" ? "Werkelijk buiten de app terugbetaald bedrag in euro" : "Werkelijk ontvangen bedrag in euro", (batch.totalAmountCents / 100).toFixed(2).replace(".", ","))?.trim();
    if (!amount || !/^\d+(?:[,.]\d{1,2})?$/.test(amount) || Math.round(Number(amount.replace(",", ".")) * 100) !== batch.totalAmountCents) return setNotice(`Bevestig exact ${paymentAmount(batch.totalAmountCents)} voor ${batch.childNames.join(", ")}. Controleer een afwijkende ontvangst eerst.`);
    const reference = window.prompt("Externe Tikkie-/bankreferentie:")?.trim();
    const reason = command === "refund"
      ? "Terugbetaling per kind vastgelegd via beheeromgeving"
      : "Betaling per kind bevestigd via beheeromgeving";
    if (!reference) return setNotice("Een externe referentie is verplicht.");
    if (!window.confirm(command === "refund" ? `Terugbetaling van ${paymentAmount(batch.totalAmountCents)} vastleggen voor ${batch.childNames.join(", ")}? Doe dit alleen nadat het bedrag werkelijk buiten de app is terugbetaald. Deze actie maakt geen geld over en zet uitsluitend de gekoppelde actieve kinderen weer open voor een nieuw betaalverzoek.` : `Ontvangst van ${paymentAmount(batch.totalAmountCents)} bevestigen voor ${batch.childNames.join(", ")}?`)) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc(command === "refund" ? "admin_child_payment_refund" : "admin_child_payment_confirm", { _batch_id: batch.id, _expected_version: batch.version, _amount_cents: batch.totalAmountCents, _external_reference: reference, _reason: reason, _idempotency_key: crypto.randomUUID() });
      setNotice(error ? `Betaalmutatie geweigerd: ${error.message}` : command === "refund" ? "Werkelijk uitgevoerde terugbetaling vastgelegd voor de gekoppelde kinderen. Andere kinderen blijven ongewijzigd." : "Ontvangst bevestigd voor de gekoppelde kinderen. Andere kinderen blijven ongewijzigd.");
      await Promise.all([loadPayments(), load()]);
    } catch { setNotice("De verbinding is onderbroken. Vernieuw en controleer de ontvangst voordat je opnieuw bevestigt."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function markChildPaymentUnpaid(batch: ChildPaymentBatch) {
    if (paymentMutation.current) return;
    if (!window.confirm(`Markeer de Tikkie voor ${batch.childNames.join(", ")} als niet betaald en maak de betaallink opnieuw beschikbaar?`)) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_mark_unpaid", {
        _batch_id: batch.id,
        _expected_version: batch.version,
      });
      setNotice(error ? `Statuswijziging geweigerd: ${error.message}` : "De Tikkie staat weer op niet betaald en de betaallink is opnieuw beschikbaar.");
      await loadPayments();
    } catch {
      setNotice("De verbinding is onderbroken. Vernieuw het betaaloverzicht voordat je opnieuw beslist.");
    } finally {
      paymentMutation.current = false;
      setPaymentBusy(false);
    }
  }

  async function setAdminPaymentStatus(payment: ChildPaymentRow, status: PaymentViewStatus) {
    const current = paymentViewStatus(payment);
    if (status === current) return;
    if (!payment.batch) {
      setNotice(status === "paid"
        ? "Publiceer eerst een Tikkie voor dit kind voordat je de ontvangst als betaald kunt bevestigen."
        : "Voor dit kind is nog geen betaalverzoek actief.");
      return;
    }
    if (status === "paid") {
      await confirmChildPayment(payment.batch);
      return;
    }
    if (status === "unpaid" && payment.batch.status === "reported") {
      await markChildPaymentUnpaid(payment.batch);
      return;
    }
    setNotice("Een bevestigde betaling wijzig je alleen via de aparte, gecontroleerde terugbetalingsactie.");
  }

  function selectPayment(payment: ChildPaymentRow, checked: boolean) {
    const members = payment.batch
      ? childPayments.filter((row) => row.registrationId === payment.registrationId && row.batch?.id === payment.batch?.id)
      : [payment];
    const ids = members.map((row) => row.childId);
    setSelectedPaymentIds((previous) => {
      if (!checked) return previous.filter((id) => !ids.includes(id));
      const sameRegistration = previous.filter((id) =>
        childPayments.some((row) => row.childId === id && row.registrationId === payment.registrationId),
      );
      if (sameRegistration.length !== previous.length) {
        setNotice("De eerdere selectie is gewist. Eén Tikkie bevat alleen kinderen uit dezelfde inschrijving.");
      }
      return [...new Set([...sameRegistration, ...ids])];
    });
    if (checked) setPaymentPayerId(payment.batch?.anchorChildId ?? payment.childId);
    if (checked && payment.batch?.externalUrl) setPaymentLink(payment.batch.externalUrl);
  }

  async function publishPaymentLink() {
    if (paymentMutation.current) return;
    if (!selectedPayments.length || !paymentLink.trim()) return setNotice("Selecteer kinderen en vul een Tikkie-link in.");
    if (new Set(selectedPayments.map((payment) => payment.registrationId)).size !== 1) return setNotice("Selecteer alleen kinderen uit dezelfde inschrijving.");
    if (!window.confirm(`Eén gezamenlijke Tikkie van ${paymentAmount(selectedPaymentTotal)} voor ${selectedPayments.length} kind(eren) publiceren en per e-mail versturen? Controleer dat de externe Tikkie dit totaalbedrag bevat.`)) return;
    const client = createClient();
    if (!client) return;
    const payload = { _event_slug: eventSlug, _children: selectedPayments.map(({ childId, version }) => ({ id: childId, version })), _external_url: paymentLink.trim(), _anchor_child_id: selectedPayer?.childId, _reason: "Tikkie gepubliceerd via beheeromgeving" };
    const serialized = JSON.stringify(payload);
    if (paymentPublishKey.current?.payload !== serialized) paymentPublishKey.current = { payload: serialized, key: crypto.randomUUID() };
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_publish", { ...payload, _idempotency_key: paymentPublishKey.current.key });
      setNotice(error ? `Tikkie niet gepubliceerd: ${error.message}` : "Gezamenlijke Tikkie gepubliceerd. De e-mails staan klaar voor verzending; ontvangst moet nog worden gecontroleerd.");
      if (!error) { setSelectedPaymentIds([]); setPaymentLink(""); paymentPublishKey.current = null; }
      await loadPayments();
    } catch { setNotice("De verbinding is onderbroken. Probeer dezelfde opdracht opnieuw; je selectie blijft bewaard."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function cancelPaymentBatch(batch: ChildPaymentBatch | PaymentBatch, legacy = false) {
    if (paymentMutation.current) return;
    const reason = "Gezamenlijk betaalverzoek opgeheven via beheeromgeving";
    if (!window.confirm("Deactiveer de oude Tikkie ook zelf bij Tikkie. Deze actie verwijdert de link uit de dashboards en maakt de kinderen weer apart selecteerbaar. Er wordt geen betaling of terugbetaling vastgelegd. Doorgaan?")) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc(legacy ? "admin_payment_batch_cancel" : "admin_child_payment_cancel", { _batch_id: batch.id, _expected_version: batch.version, _reason: reason });
      setNotice(error ? `Opheffen geweigerd: ${error.message}` : "Gezamenlijk betaalverzoek opgeheven. Controleer dat de externe Tikkie is gedeactiveerd voordat je een nieuw verzoek verstuurt.");
      if (!error) setSelectedPaymentIds([]);
      await loadPayments();
    } catch { setNotice("De verbinding is onderbroken. Vernieuw de betalingen om te controleren of het verzoek is opgeheven."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function liveCommand(
    run: LiveRun,
    command: "override" | "paused" | "live" | "stopped",
  ) {
    const client = createClient();
    if (!client || !run.runId || run.runVersion === null) return;
    if (command === "override" && !run.currentStopId)
      return setNotice("Deze groep heeft nu geen poort waarvoor een scanoverride nodig is.");
    const reason = command === "override"
      ? "Scanoverride uitgevoerd via avondcockpit"
      : `Groepsroute ingesteld op ${command} via avondcockpit`;
    const result =
      command === "override" && run.currentStopId
        ? await client.schema("api").rpc("run_support_override", {
            _run_id: run.runId,
            _stop_id: run.currentStopId,
            _expected_run_version: run.runVersion,
            _reason: reason,
          })
        : await client.schema("api").rpc("run_set_state", {
            _run_id: run.runId,
            _state: command,
            _expected_version: run.runVersion,
            _reason: reason,
          });
    setNotice(
      result.error
        ? `Noodhandeling geweigerd: ${result.error.message}`
        : "Noodhandeling uitgevoerd.",
    );
    await loadLive();
  }

  async function reassignLeader(run: LiveRun) {
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
        _reason: "Groepsleider vervangen via avondcockpit",
      });
    setNotice(
      error
        ? `Leiderwissel geweigerd: ${error.message}`
        : "Leider vervangen; de vorige leider heeft direct geen mutatierecht meer.",
    );
    await loadLive();
  }

  async function redirectGroup(run: LiveRun, target: "ordinary" | "finale") {
    if (!run.runId || run.runVersion === null) return;
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
      _reason: target === "finale" ? "Groep omgeleid naar laatste poort" : "Groep omgeleid naar gekozen gewone poort",
    });
    setNotice(error ? `Omleiding geweigerd: ${error.message}` : target === "finale" ? "De laatste poort is veilig gereserveerd en gepubliceerd." : "De gekozen volgende gewone poort is gereserveerd en gepubliceerd.");
    await loadLive();
  }

  async function safeWithdraw(run: LiveRun) {
    if (!run.runId || run.runVersion === null) return;
    const email = window.prompt(`Welke verantwoordelijke volwassene neemt de groep mee?\n${run.responsibleAdults.map((adult) => adult.email).join("\n")}`)?.trim().toLowerCase();
    const adult = run.responsibleAdults.find((candidate) => candidate.email.toLowerCase() === email);
    if (!adult) return setNotice("Kies een geregistreerde volwassene uit deze groep.");
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("admin_safe_withdraw_group", {
      _run_id: run.runId,
      _responsible_adult_user_id: adult.userId,
      _expected_run_version: run.runVersion,
      _reason: "Groep veilig afgemeld via avondcockpit",
    });
    setNotice(error ? `Afmelding geweigerd: ${error.message}` : "De veilige afmelding en verantwoordelijke volwassene zijn vastgelegd.");
    await loadLive();
  }

  async function activateEmergencyClosure() {
    if (!window.confirm("De voorbereide noodafsluiting activeren voor alle actieve groepen?")) return;
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_activate_emergency_closure", {
      _event_slug: eventSlug,
      _reason: "Voorbereide noodafsluiting geactiveerd via avondcockpit",
    });
    const result = data as { affectedGroups?: number } | null;
    setNotice(error ? `Noodafsluiting geweigerd: ${error.message}` : `Noodafsluiting geactiveerd voor ${result?.affectedGroups ?? 0} groepen.`);
    await loadLive();
  }

  async function setPortalState(portal: LivePortal, state: "open" | "paused" | "closed") {
    const client = createClient();
    if (!client) return;
    const { error } = await client.schema("api").rpc("portal_set_operational_state", {
      _portal_id: portal.id,
      _state: state,
      _expected_version: portal.version,
      _reason: `Poortstatus ingesteld op ${state} via avondcockpit`,
    });
    setNotice(error ? `Poortstatus geweigerd: ${error.message}` : `${portal.name} staat nu op ${state}.`);
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
      {mobileNavOpen && <button className="admin-nav-backdrop" tabIndex={-1} aria-label="Navigatie sluiten" onClick={() => setMobileNavOpen(false)} />}
      <aside
        id="admin-navigation"
        ref={navigationRef}
        className={`admin-nav${mobileNavOpen ? " is-open" : ""}`}
        role={mobileNavOpen ? "dialog" : undefined}
        aria-modal={mobileNavOpen ? true : undefined}
        aria-label="Organisatienavigatie"
        onClick={(event) => {
          if ((event.target as HTMLElement).closest("button, a")) setMobileNavOpen(false);
        }}
      >
        <div className="admin-drawer-heading">
          <span>Nachtregie</span>
          <button ref={closeMenuRef} type="button" aria-label="Menu sluiten" onClick={() => setMobileNavOpen(false)}><X aria-hidden="true" /></button>
        </div>
        <Link className="admin-brand" href="/">
          <Image src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width={180} height={76} priority />
          <span>Nachtregie · organisatie</span>
        </Link>
        <p className="admin-nav-label">Werkruimte</p>
        <button
          className={section === "overview" ? "active" : ""}
          aria-current={section === "overview" ? "page" : undefined}
          onClick={() => setSection("overview")}
        >
          <ShieldCheck />
          Cockpit
        </button>
        <button
          className={section === "imports" ? "active" : ""}
          aria-current={section === "imports" ? "page" : undefined}
          onClick={() => setSection("imports")}
        >
          <Database />
          Imports
        </button>
        <button
          className={section === "registrations" ? "active" : ""}
          aria-current={section === "registrations" ? "page" : undefined}
          onClick={() => {
            setSection("registrations");
            void Promise.all([
              loadRegistrations(),
              loadRegistrationChanges(),
              loadTogetherRequests(),
            ]);
          }}
        >
          <UsersRound />
          <span>Inschrijvingen</span>
          {dashboard.counts.registrations > 0 && <b aria-hidden="true">{dashboard.counts.registrations}</b>}
        </button>
        {(capabilities.includes("event_admin") || capabilities.includes("groups_manage")) && (
          <button
            className={section === "groups" ? "active" : ""}
            aria-current={section === "groups" ? "page" : undefined}
            onClick={() => setSection("groups")}
          >
            <UsersRound />
            Groepsindeling
          </button>
        )}
        {(capabilities.includes("event_admin") ||
          capabilities.includes("groups_manage") ||
          capabilities.includes("live_support")) && (
          <button
            className={section === "tickets" ? "active" : ""}
          aria-current={section === "tickets" ? "page" : undefined}
            onClick={() => setSection("tickets")}
          >
            <MessageSquare />
            Messenger
          </button>
        )}
        {(capabilities.includes("event_admin") ||
          capabilities.includes("content_manage") ||
          capabilities.includes("live_support")) && (
          <button
            className={section === "updates" ? "active" : ""}
          aria-current={section === "updates" ? "page" : undefined}
            onClick={() => setSection("updates")}
          >
            <BellRing />
            Deelnemersupdates
          </button>
        )}
        <button
          className={section === "payments" ? "active" : ""}
          aria-current={section === "payments" ? "page" : undefined}
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
          aria-current={section === "portals" ? "page" : undefined}
          onClick={() => setSection("portals")}
        >
          <House />
          Poortaanvragen
        </button>
        <button
          className={section === "planner" ? "active" : ""}
          aria-current={section === "planner" ? "page" : undefined}
          onClick={() => setSection("planner")}
        >
          <MapPinned />
          Startpunten en indeling
        </button>
        <button
          className={section === "content" ? "active" : ""}
          aria-current={section === "content" ? "page" : undefined}
          onClick={() => setSection("content")}
        >
          <FileText />
          Content & sponsors
        </button>
        {capabilities.includes("event_admin") && (
          <button
            className={section === "access" ? "active" : ""}
          aria-current={section === "access" ? "page" : undefined}
            onClick={() => setSection("access")}
          >
            <UserCog />
            Beheerders
          </button>
        )}
        <button
          className={section === "live" ? "active" : ""}
          aria-current={section === "live" ? "page" : undefined}
          onClick={() => {
            setSection("live");
            void loadLive();
          }}
        >
          <LifeBuoy />
          Avond live
        </button>
        <button
          className={section === "simulation" ? "active" : ""}
          aria-current={section === "simulation" ? "page" : undefined}
          onClick={() => {
            setSection("simulation");
            void loadLive();
          }}
        >
          <Play />
          Avondsimulatie
        </button>
        <button
          className={section === "settings" ? "active" : ""}
          aria-current={section === "settings" ? "page" : undefined}
          onClick={() => setSection("settings")}
        >
          <SlidersHorizontal />
          Instellingen
        </button>
      </aside>
      <div className="admin-workspace" inert={mobileNavOpen}>
        <div className="admin-topbar">
          <button ref={menuButtonRef} className="admin-menu-toggle" type="button" aria-label="Organisatienavigatie openen" aria-controls="admin-navigation" aria-expanded={mobileNavOpen} onClick={() => setMobileNavOpen(true)}>
            <Menu aria-hidden="true" />
            <span>Menu</span>
          </button>
          <span className="admin-mobile-section">{sectionMeta[section].title}</span>
          <span className="admin-desktop-crumb">De Duindorpse Poorten <i>›</i> Nachtregie</span>
          <span>{dashboard.event.date} <i>·</i> {dashboard.event.phase}</span>
        </div>
        <main className="admin-content">
        <div className="app-heading admin-page-heading row-between">
          <div>
            <p className="kicker">{sectionMeta[section].kicker}</p>
            <h1>{sectionMeta[section].title}</h1>
            <p>{sectionMeta[section].description}</p>
          </div>
          <button className="btn outline" onClick={() => void Promise.all([load(), section === "registrations" ? loadRegistrations() : Promise.resolve()])}>
            <RefreshCw />
            Vernieuwen
          </button>
        </div>
        {notice && (
          <div className="form-notice" role="status">
            {notice}
          </div>
        )}
        {section === "settings" && (
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
                        max={20}
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
          </>
        )}
        {section === "overview" && (
          <>
            <div className="dashboard-metrics cockpit-metrics">
              {["groups", "approvedPortals", "openTickets", "registrations"].map((key) => (
                <div className="metric" key={key}>
                  <strong>{dashboard.counts[key] ?? 0}</strong>
                  <span>{labels[key] ?? key}</span>
                  {key === "registrations" && (
                    <small>
                      {dashboard.counts.children ?? 0} ingeschreven {dashboard.counts.children === 1 ? "kind" : "kinderen"}
                    </small>
                  )}
                </div>
              ))}
            </div>
            <div className="cockpit-live-grid">
              <section className="panel cockpit-map-panel">
                <div className="row-between">
                  <div><p className="kicker">Wijkregie · live</p><h2>Poorten van de nacht</h2></div>
                  <div className="map-connection-actions">
                    <span className={`live-connection ${liveConnection}`}><i />{liveConnection === "live" ? "Live" : liveConnection === "offline" ? "Verbinding verbroken" : "Verbinden…"}</span>
                    {liveConnection === "offline" && <button className="text-link" type="button" onClick={() => { setLiveConnection("connecting"); setLiveConnectionRetry((value) => value + 1); void loadLive(); }}><RefreshCw />Verbinding herstellen</button>}
                  </div>
                </div>
                <p>{portalOperations.filter((portal) => portal.coordinate).length} bevestigde bestemming(en) met een geverifieerde kaartpositie.</p>
                <NightMap
                  variant="admin"
                  ariaLabel="Live beheerkaart met geverifieerde poorten"
                  onPortalSelect={() => setSection("portals")}
                  portals={portalMapPortals}
                />
              </section>
              <div className="cockpit-side-stack">
                <section className="panel cockpit-action-panel">
                  <div className="row-between"><div><p className="kicker">Direct handelen</p><h2>Dit vraagt nu aandacht.</h2></div><span className="registration-total">{liveAlerts.length + (dashboard.counts.pendingTogetherRequests ?? 0)} open</span></div>
                  {liveAlerts.length === 0 && !(dashboard.counts.pendingTogetherRequests ?? 0) ? <p className="form-notice">Geen veiligheidsmeldingen of samenloopverzoeken die nu actie vragen.</p> : <>
                    {liveAlerts.slice(0, 3).map((alert) => <div className="cockpit-action-row" key={alert.id}><AlertTriangle /><div><strong>{alert.code}</strong><span>{alert.message}</span></div><button className="text-link" onClick={() => setSection("live")}>Bekijk <ArrowRight /></button></div>)}
                    {(dashboard.counts.pendingTogetherRequests ?? 0) > 0 && <div className="cockpit-action-row"><UsersRound /><div><strong>{dashboard.counts.pendingTogetherRequests} samenloopverzoek(en)</strong><span>Controleer groepsgrootte en de gezamenlijke indeling.</span></div><button className="text-link" onClick={() => { setSection("registrations"); void Promise.all([loadRegistrations(), loadTogetherRequests(), loadRegistrationChanges()]); }}>Bekijk <ArrowRight /></button></div>}
                  </>}
                </section>
                <section className="panel cockpit-live-log">
                  <div className="row-between"><div><p className="kicker">Binnenkomend</p><h2>Live log</h2></div><button className="text-link" onClick={() => void Promise.all([load(), loadLive()])}>Vernieuwen <RefreshCw /></button></div>
                  {dashboard.recentActivity.length ? dashboard.recentActivity.slice(0, 6).map((item, index) => {
                    const activity = normalizeActivity(item.action, item.resourceType);
                    return <div className={`activity-row activity-${activity.tone}`} key={`${item.createdAt}-${index}`}><CheckCircle2 aria-hidden="true" /><div><strong>{activity.message}</strong><small>{activity.source} · {new Date(item.createdAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" })}</small></div></div>;
                  }) : <p>Nog geen activiteit.</p>}
                </section>
              </div>
            </div>
            <div className="cockpit-overview-grid">
              <section className="panel">
                <div className="row-between"><div><p className="kicker">Alle poorten</p><h2>Status en bereikbaarheid</h2></div><button className="text-link" onClick={() => setSection("portals")}>Open poorten <ArrowRight /></button></div>
                <div className="cockpit-portal-grid">{portalOperations.length === 0 ? <p>Nog geen goedgekeurde poorten.</p> : portalOperations.slice(0, 8).map((portal) => <article className={`cockpit-portal-card ${portal.operationStatus}${portal.isFinal ? " final" : ""}`} key={portal.portalId}><House /><strong>{portal.systemCode}</strong><span>{portal.name}</span><small>{portal.operationStatus === "open" ? "Open" : portal.operationStatus === "paused" ? "Pauze" : portal.operationStatus === "closed" ? "Gestopt" : "Voorbereiding"}</small></article>)}</div>
              </section>
              <section className="panel">
                <div className="row-between"><div><p className="kicker">Onderweg</p><h2>Groepen in beweging</h2></div><button className="text-link" onClick={() => setSection("live")}>Avond live <ArrowRight /></button></div>
                <div className="cockpit-group-list">{liveRuns.length === 0 ? <p>Nog geen groepen onderweg.</p> : liveRuns.slice(0, 6).map((run) => <article key={run.groupId}><span>{run.systemCode || run.groupCode}</span><div><strong>{run.displayName || "Groep " + run.groupCode}</strong><small>{run.currentPortal || "Wacht op volgende bestemming"} · {run.childCount} kinderen</small></div><b>{run.runStatus || run.status}</b></article>)}</div>
              </section>
            </div>
          </>
        )}
        {section === "simulation" && (
          <div className="admin-simulation-grid">
            <section className="panel simulation-main">
              <div className="simulation-icon"><Play /></div>
              <p className="kicker">Veilig testen met actuele condities</p>
              <h2>Repetitie van de nacht.</h2>
              <p>Deze schaduwcontrole verandert geen routes en verstuurt geen berichten. Ze laat zien of de actuele poorten, groepen en signalen klaarstaan voor een proefavond op staging.</p>
              <button className="btn" onClick={() => void loadLive()}><Play />Proefbeeld opnieuw berekenen</button>
              <div className="simulation-steps">
                <span className={dashboard.counts.groups > 0 ? "ready" : ""}><CheckCircle2 />Groepen ingedeeld</span>
                <span className={dashboard.counts.approvedPortals > 0 ? "ready" : ""}><CheckCircle2 />Poorten beschikbaar</span>
                <span className="ready"><CheckCircle2 />Capaciteit bewaakt</span>
                <span className={liveAlerts.length === 0 ? "ready" : "attention"}><CheckCircle2 />Veiligheidssignalen</span>
                <span className="ready"><CheckCircle2 />Laatste poort vereist</span>
              </div>
            </section>
            <section className="panel simulation-result">
              <p className="kicker">Wat ziet de planner?</p>
              <h2>Veilig door de wijk.</h2>
              <div><strong>{livePortals.filter((portal) => portal.operationStatus === "open").length}</strong><span>poorten open voor nieuwe groepen</span></div>
              <div><strong>{liveRuns.length}</strong><span>groepen in het actuele proefbeeld</span></div>
              <div><strong>{liveAlerts.length}</strong><span>signalen die eerst aandacht vragen</span></div>
              <p className={liveAlerts.length ? "form-warning" : "form-notice"}>{liveAlerts.length ? "Los de zichtbare signalen op voordat de avond live gaat." : "De actuele schaduwcontrole bevat geen open veiligheidssignalen."}</p>
            </section>
          </div>
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
                  {new Date(item.createdAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })}
                </span>
                <strong>{item.status}</strong>
              </div>
            ))}
          </section>
        )}
        {section === "payments" && (
          <section className="panel payment-admin-panel">
            <p className="kicker">Tikkie & ontvangstcontrole</p>
            <h2>Betalingen per kind</h2>
            <p>Selecteer precies de kinderen voor één Tikkie, ook binnen hetzelfde gezin. Je kunt bijvoorbeeld twee kinderen samen laten betalen en voor het derde kind een aparte link maken. De betaalknop verschijnt bij één gekozen kind; de andere geselecteerde kinderen verwijzen daarnaar.</p>
            <label className="field"><span>Zoek kind, ouder, e-mail, groep of referentie</span><input type="search" value={paymentSearch} onChange={(event) => setPaymentSearch(event.target.value)} placeholder="Naam van kind, ouder of groep" /></label>
            <div className="payment-status-filters" role="group" aria-label="Filter betalingen op status">
              {(["all", "waiting", "unpaid", "paid"] as const).map((status) => (
                <button key={status} type="button" className={paymentStatusFilter === status ? "active" : ""} aria-pressed={paymentStatusFilter === status} onClick={() => setPaymentStatusFilter(status)}>
                  {status === "all" ? "Alle" : paymentViewStatusLabels[status]}
                  <span>{status === "all" ? childPayments.length : childPayments.filter((payment) => paymentViewStatus(payment) === status).length}</span>
                </button>
              ))}
            </div>
            <form className="payment-publish-form" onSubmit={(event) => { event.preventDefault(); void publishPaymentLink(); }}>
              <h3>Tikkie voor geselecteerde kinderen</h3>
              <p><strong>{selectedPayments.length} kind(eren) geselecteerd · {paymentAmount(selectedPaymentTotal)}</strong></p>
              {selectedPayments.length > 0 && <ul className="payment-selection-list">{selectedPayments.map((payment) => <li key={payment.childId}>{payment.firstName} · {payment.parentName} · {paymentAmount(payment.amountCents)}</li>)}</ul>}
              {selectedPayments.length > 0 && <label className="field"><span>Betaalknop bij</span><select className="choice" value={selectedPayer?.childId ?? ""} onChange={(event) => setPaymentPayerId(event.target.value)}>{selectedPayments.map((payment) => <option key={payment.childId} value={payment.childId}>{payment.firstName} · {payment.parentName || payment.registrationReference}</option>)}</select></label>}
              <p className="note">Maak bij Tikkie één link voor exact dit totaal. Bij een bestaand verzoek selecteren we alle gekoppelde kinderen. Hef dat verzoek eerst op om de samenstelling te veranderen en deactiveer de oude externe Tikkie.</p>
              <label className="field"><span>Tikkie-link voor het totaalbedrag</span><input type="url" required value={paymentLink} onChange={(event) => setPaymentLink(event.target.value)} placeholder="https://tikkie.me/pay/…" /></label>
              <div className="actions"><button className="btn" disabled={!selectedPayments.length || paymentBusy} type="submit">{paymentBusy ? "Bezig…" : "Tikkie publiceren en e-mail versturen"}</button><button className="btn outline" type="button" disabled={paymentBusy || !selectedPayments.length} onClick={() => setSelectedPaymentIds([])}>Selectie wissen</button></div>
            </form>
            {paymentGroups.length === 0 ? <div className="payment-registration-empty">Geen inschrijvingen met kinderen gevonden voor dit filter.</div> : <div className="payment-registration-list">
              {paymentGroups.map(([registrationId, registrationPayments]) => {
                const registration = registrationPayments[0];
                const allRegistrationPayments = childPayments.filter((payment) => payment.registrationId === registrationId);
                const selectedInRegistration = allRegistrationPayments.filter((payment) => selectedPaymentIds.includes(payment.childId)).length;
                const paidCount = allRegistrationPayments.filter((payment) => paymentViewStatus(payment) === "paid").length;
                const waitingCount = allRegistrationPayments.filter((payment) => paymentViewStatus(payment) === "waiting").length;
                return <details className="payment-registration-group" key={registrationId}>
                  <summary>
                    <span className="registration-group-mark">{registration.groupCode ?? registration.registrationReference.slice(-2)}</span>
                    <span className="payment-registration-heading">
                      <strong>{registration.groupName || registration.registrationReference}</strong>
                      <small>{registration.parentName || "Ouder nog niet bekend"} · {registration.parentEmail || "geen e-mailadres"}</small>
                    </span>
                    <span className="payment-registration-reference">{registration.registrationReference}<small>{allRegistrationPayments.length} {allRegistrationPayments.length === 1 ? "kind" : "kinderen"}</small></span>
                    <span className="payment-registration-progress"><strong>{paidCount}/{allRegistrationPayments.length} betaald</strong>{waitingCount > 0 && <small>{waitingCount} wachtend op controle</small>}{selectedInRegistration > 0 && <small>{selectedInRegistration} geselecteerd</small>}</span>
                  </summary>
                  <div className="payment-registration-children">
                    {registrationPayments.map((payment) => {
                      const batchMembers = payment.batch ? childPayments.filter((row) => row.batch?.id === payment.batch?.id) : [];
                      const batchWithinRegistration = batchMembers.every((row) => row.registrationId === payment.registrationId);
                      const canSelect = batchWithinRegistration && !payment.batch?.legacy && ["awaiting_link", "awaiting_payment"].includes(payment.status) && (!payment.batch || payment.batch.status === "awaiting_payment");
                      const firstBatchRow = payment.batch && registrationPayments.find((row) => row.batch?.id === payment.batch?.id)?.childId === payment.childId;
                      const activeAnchor = payment.batch?.anchorChildId === payment.childId;
                      const adminStatus = paymentViewStatus(payment);
                      return <article className="payment-admin-row" data-testid={`child-payment-${payment.childId}`} key={payment.childId}>
                        <label className="payment-row-select"><input type="checkbox" checked={selectedPaymentIds.includes(payment.childId)} disabled={!canSelect || paymentBusy} onChange={(event) => selectPayment(payment, event.target.checked)} aria-label={`Selecteer ${payment.firstName} · ${payment.parentName || payment.registrationReference}`} /><span><strong>{payment.firstName}</strong><small>{paymentAmount(payment.amountCents)} bijdrage</small><small>{[payment.groupCode, payment.groupName].filter(Boolean).join(" · ") || "Groepsindeling volgt"}</small></span></label>
                        <div className="payment-row-amount"><span>{paymentStatusLabels[payment.status] ?? payment.status}</span><label className="payment-status-admin"><small>Status door admin</small><select value={adminStatus} disabled={paymentBusy} onChange={(event) => void setAdminPaymentStatus(payment, event.target.value as PaymentViewStatus)}><option value="waiting" disabled={adminStatus !== "waiting"}>Wachtend</option><option value="unpaid" disabled={adminStatus === "paid"}>Niet betaald</option><option value="paid" disabled={adminStatus !== "paid" && (!payment.batch || payment.batch.status === "needs_review")}>Betaald</option></select></label></div>
                        {payment.batch && <div className="payment-admin-batch">{payment.batch.legacy && <p>Dit kind is gekoppeld aan een eerder verzoek per inschrijving. Beheer dat verzoek bij de betalingshistorie voordat je kinderen afzonderlijk selecteert.</p>}{!batchWithinRegistration && <p>Deze oudere Tikkie bevat kinderen uit meerdere inschrijvingen. Hef hem eerst op; nieuwe Tikkies worden per inschrijving gemaakt.</p>}<strong>Gekoppelde kinderen · totaal {paymentAmount(payment.batch.totalAmountCents)}</strong><p>{payment.batch.childNames.join(" · ")}</p><p>{activeAnchor ? "Betaalknop bij dit kind" : `Inbegrepen bij ${payment.batch.anchorChildName} · geen aparte betaling`}</p>{payment.batch.status === "needs_review" && <p>Controle nodig: gebruik de eerdere link niet. Controleer de ontvangst en hef het verzoek zo nodig op.</p>}</div>}
                        <div className="actions">
                          {payment.batch?.externalUrl && payment.batch.status === "awaiting_payment" && (activeAnchor ? <a className="btn outline" href={payment.batch.externalUrl} target="_blank" rel="noreferrer noopener">Tikkie bij {payment.firstName}</a> : <button className="btn outline" disabled>Inbegrepen bij {payment.batch.anchorChildName}</button>)}
                          {firstBatchRow && payment.batch && !payment.batch.legacy && ["awaiting_payment", "reported"].includes(payment.batch.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void confirmChildPayment(payment.batch!)}>Bevestig ontvangst {paymentAmount(payment.batch.totalAmountCents)}</button>}
                          {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status === "reported" && <button className="btn outline" disabled={paymentBusy} onClick={() => void markChildPaymentUnpaid(payment.batch!)}>Markeer niet betaald</button>}
                          {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status === "confirmed" && <button className="btn outline" disabled={paymentBusy} onClick={() => void confirmChildPayment(payment.batch!, "refund")}>Leg terugbetaling vast</button>}
                          {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status !== "confirmed" && <button className="btn outline" disabled={paymentBusy} onClick={() => void cancelPaymentBatch(payment.batch!)}>Betaalverzoek opheffen</button>}
                        </div>
                      </article>;
                    })}
                  </div>
                </details>;
              })}
            </div>}
            <details className="payment-publish-form"><summary>Betalingshistorie en terugbetalingen per inschrijving</summary><p>Een terugbetaling wordt pas vastgelegd nadat deze werkelijk buiten de app is uitgevoerd. Nieuwe Tikkies maak je hierboven per kind. Betalingen per kind betaal je uitsluitend terug via het betreffende verzoek hierboven, zodat andere kinderen hun betaalstatus behouden.</p>{payments.map((payment) => <div className="incident-row" key={payment.id}><div><strong>{payment.parentName || payment.householdLabel || payment.registrationReference}</strong><small>{payment.reference} · ontvangen {paymentAmount(payment.netCollectedCents)} van {paymentAmount(payment.amountCents)} · {paymentStatusLabels[payment.status] ?? payment.status}</small></div><div className="actions">{!payment.childPaymentMode && payment.batch && ["awaiting_payment", "reported"].includes(payment.batch.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "confirm")}>Bevestig eerder verzoek {paymentAmount(payment.batch.totalAmountCents)}</button>}{!payment.childPaymentMode && payment.batch && payment.batch.status !== "confirmed" && <button className="btn outline" disabled={paymentBusy} onClick={() => void cancelPaymentBatch(payment.batch!, true)}>Eerder betaalverzoek opheffen</button>}{!payment.childPaymentMode && !payment.batch && payment.externalUrl && ["awaiting_payment", "reported"].includes(payment.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "confirm")}>Bevestig eerdere losse Tikkie</button>}{!payment.childPaymentMode && !payment.batch && payment.externalUrl && ["awaiting_link", "awaiting_payment", "reported"].includes(payment.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void clearLegacyPayment(payment)}>Eerdere losse Tikkie intrekken</button>}{!payment.childPaymentMode && payment.netCollectedCents > 0 && payment.status !== "refunded" && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "refund")}>Leg terugbetaling vast</button>}</div></div>)}</details>
          </section>
        )}
        {section === "registrations" && (
          <section className="panel registration-roster">
            <div className="row-between registration-roster-heading">
              <div>
                <p className="kicker">Actuele deelnemerslijst</p>
                <h2>Alle inschrijvingen</h2>
                <p>Een definitieve inschrijving verschijnt hier direct. Open een groep voor contactgegevens, kinderen en voorkeurstijden.</p>
              </div>
              <span className="registration-total">
                {registrations.length} {registrations.length === 1 ? "inschrijving" : "inschrijvingen"} ·{" "}
                {registrationChildCount} {registrationChildCount === 1 ? "kind" : "kinderen"}
              </span>
            </div>
            <label className="field registration-search">
              <span>Zoek op groepsnaam, ouder, e-mailadres of referentie</span>
              <input type="search" value={registrationSearch} onChange={(event) => setRegistrationSearch(event.target.value)} placeholder="Bijvoorbeeld De Nachtlopers of REG-…" />
            </label>
            {registrationsLoading ? <div className="registration-roster-empty"><RefreshCw className="spin" /> Inschrijvingen ophalen…</div> : (() => {
              const query = registrationSearch.trim().toLocaleLowerCase("nl");
              const visible = registrations.filter((registration) => !query || [registration.groupName, registration.groupCode, registration.parentName, registration.parentEmail, registration.reference, ...registration.children.map((child) => child.name)].some((value) => value?.toLocaleLowerCase("nl").includes(query)));
              if (visible.length === 0) return <div className="registration-roster-empty"><UsersRound /><strong>{registrations.length ? "Geen inschrijvingen gevonden" : "Nog geen inschrijvingen"}</strong><span>{registrations.length ? "Pas je zoekterm aan." : "Een afgeronde deelnemersinschrijving verschijnt hier automatisch."}</span></div>;
              return <div className="registration-list">{visible.map((registration) => {
                const open = selectedRegistrationId === registration.id;
                return <article className={"registration-admin-card" + (open ? " open" : "")} key={registration.id}>
                  <div className="registration-admin-summary">
                    <span className="registration-group-mark">{registration.groupCode ?? registration.groupName.slice(0, 2).toUpperCase()}</span>
                    <div className="registration-admin-name"><strong>{registration.groupName}</strong><span>{registration.parentName} · {registration.childCount} {registration.childCount === 1 ? "kind" : "kinderen"}</span></div>
                    <div className="registration-admin-meta"><span>{registration.reference}</span><span>{registration.submittedAt ? new Date(registration.submittedAt).toLocaleString("nl-NL", { dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Amsterdam" }) : "Inschrijving ontvangen"}</span></div>
                    <button className="btn outline registration-row-open" aria-expanded={open} onClick={() => setSelectedRegistrationId(open ? null : registration.id)}>{open ? "Sluit details" : "Bekijk details"}<ArrowRight /></button>
                  </div>
                  {open && <div className="registration-admin-details">
                    <div className="registration-contact-card"><p className="kicker">Contactpersoon</p><strong>{registration.parentName}</strong><a href={"mailto:" + registration.parentEmail}>{registration.parentEmail}</a>{registration.phone ? <a href={"tel:" + registration.phone.replace(/\s/g, "")}>{registration.phone}</a> : <span>Geen telefoonnummer vastgelegd</span>}</div>
                    <div className="registration-preference-card"><p className="kicker">Voorkeuren</p><span><CalendarClock />Start: {registration.preferredStartAt ? new Date(registration.preferredStartAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "maakt niet uit"}</span><span><CalendarClock />Gewone poorten stoppen: {registration.desiredEndAt ? new Date(registration.desiredEndAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "nog niet gekozen"}</span>{registration.togetherCode && <span>Samenloopcode: <strong>{registration.togetherCode}</strong></span>}</div>
                    <div className="registration-children-card"><p className="kicker">Kinderen</p>{registration.children.map((child) => <div key={child.id}><strong>{child.name}</strong><span>{child.age === null ? "Leeftijd niet ingevuld" : child.age + " jaar"}{child.status !== "active" ? " · " + child.status : ""}</span>{child.accessibilityNote && <small>{child.accessibilityNote}</small>}</div>)}</div>
                  </div>}
                </article>;
              })}</div>;
            })()}
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
                        disabled={request.projectedChildren > 20}
                        onClick={() =>
                          void decideTogetherRequest(request, "accept")
                        }
                      >
                        {request.projectedChildren > 20 ? "Meer dan 20 kinderen" : request.projectedChildren > request.maxGroupSize
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
        {section === "groups" && (capabilities.includes("event_admin") || capabilities.includes("groups_manage")) && <GroupCompositionBoard eventSlug={eventSlug} />}
        {section === "planner" && <StartScheduleBoard eventSlug={eventSlug} maxGroupSize={dashboard.event.maxGroupSize} />}
        {section === "live" && (
          <div className="admin-live-cockpit">
            <section className="panel">
              <div className="row-between"><div><p className="kicker">Actuele, bevestigde toestand</p><h2>Avondcockpit</h2></div><button className="btn outline" onClick={() => void loadLive()}><RefreshCw />Vernieuwen</button></div>
              <p>De kaart toont alle goedgekeurde poorten met een geverifieerde positie en werkt hun operationele status live bij. Adressen zonder bevestigde coördinaten worden niet op een plek geschat.</p>
              <NightMap variant="admin" ariaLabel="Cockpitkaart met actuele, geverifieerde poorten" onPortalSelect={() => setSection("portals")} portals={portalOperations.map((portal) => ({ id: portal.portalId, code: portal.systemCode, name: portal.name, world: portal.world, coordinate: portal.coordinate, address: portal.formattedAddress ?? undefined, contactName: portal.contactName ?? undefined, phone: portal.phone ?? undefined, status: portal.operationStatus, isFinal: portal.isFinal }))} />
            </section>
            <section className="panel">
              <p className="kicker">Meldingen op prioriteit</p><h2>Veiligheidssignalen</h2>
              {liveAlerts.length === 0 ? <p>Geen open signalen.</p> : liveAlerts.map((alert) => <div className={`form-${alert.priority === "urgent" ? "warning" : "notice"}`} key={alert.id}><strong>{alert.code}</strong><p>{alert.message}</p><small>{new Date(alert.createdAt).toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam" })}</small></div>)}
            </section>
            <section className="panel">
              <p className="kicker">Handmatige bediening</p><h2>Groepen</h2>
              {liveRuns.length === 0 ? <p>Geen ingedeelde groepen.</p> : liveRuns.map((run) => (
                <div className="incident-row" key={run.groupId}>
                  <div><strong>{[run.systemCode || run.groupCode, run.displayName].filter(Boolean).join(" · ")} · {run.currentPortal ?? "geen actieve bestemming"}</strong><small>{run.runStatus ?? run.status} · {run.childCount} kinderen · laatst bevestigd {run.lastConfirmedAt ? new Date(run.lastConfirmedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "nog niet gestart"}</small><small>Stopgrens {run.effectiveStopAt ? new Date(run.effectiveStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "–"} · finale {run.expectedFinaleArrivalAt ? new Date(run.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "–"}</small></div>
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
        </main>
      </div>
    </div>
  );
}
