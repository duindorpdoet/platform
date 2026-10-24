"use client";
import {useEventDetails} from "@/components/redesign/event-details";
import {VirtualRehearsal} from "@/components/redesign/virtual-rehearsal";
import {AdminPortalThanks} from "@/components/redesign/portal-thanks";

import Image from "next/image";
import {useSnapshotRefresh} from "@/lib/realtime/use-snapshot-refresh";
import {createCoalescedRefresh} from "@/lib/realtime/coalesced-refresh";
import {EveningFreshness,emptyEveningHealth} from "./evening-freshness";
import {EveningReadiness} from "./evening-readiness";
import {EveningActionDialog,type EveningAction} from "./evening-action-dialog";
import "../../modern/evening-ops.css";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Papa from "papaparse";
import { paymentAmount, type PaymentBatch } from "@/components/payments/payment-details";
import {
  AlertTriangle,
  ArrowRight,
  CalendarClock,
  CheckCircle2,
  House,
  LifeBuoy,
  BellRing,
  Play,
  SlidersHorizontal,
  MessageSquare,
  Menu,
  X,
  RefreshCw,
  Upload,
  UsersRound,
  Search,
  LayoutDashboard,
  ChevronRight,
  ArrowUpRight,
  CalendarDays,
  DoorOpen,
} from "lucide-react";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { AdminAccessManagement } from "@/components/admin/admin-access-management";
import { PoortkamerOverview } from "@/components/admin/poortkamer-overview";
import { PortalReviews } from "@/components/admin/portal-reviews";
import { Redactiekamer } from "@/components/editorial/redactiekamer";
import { ContentManagement } from "@/components/admin/content-management";
import { MessengerInbox } from "@/components/admin/messenger-inbox";
import { ParticipantUpdates } from "@/components/admin/participant-updates";
import { ShareStudioAdmin } from "@/components/admin/share-studio-admin";
import { StatisticsDashboard } from "@/components/admin/statistics-dashboard";
import { EnvironmentTracker } from "@/components/analytics/environment-tracker";
import { PushSecurity } from "@/components/admin/push-security";
import { GroupSizePolicy } from "@/components/admin/group-size-policy";
import { StartScheduleBoard } from "@/components/admin/start-schedule-board";
import { TogetherManagement } from "@/components/admin/together-management";
import { PoortenboekAdmin } from "@/components/poortenboek/admin";
import { GroupCompositionBoard } from "@/components/admin/group-composition-board";
import { NightMap } from "@/components/maps/night-map";
import { PushNotificationSettings } from "@/components/pwa/pwa-experience";
import { normalizeActivity } from "@/lib/domain/activity-labels";
import { paymentRegistrationStage, type PaymentRegistrationStage } from "@/lib/domain/payment-registration-stage";
import { createClient } from "@/lib/supabase/client";
import {withRequestDeadline} from "@/lib/redesign/request-deadline";

type Dashboard = {
  event: {
    id: string;
    title: string;
    phase: string;
    date: string;
    settingsVersion: number;
    groupRegistrationOpen: boolean;
    portalRegistrationOpen: boolean;
    maxGroupSize: number;
    targetGroupSize?: number;
    targetFollowsMaximum?: boolean;
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
  partyId: string | null;
  clusterReference: string | null;
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
  security: {kicker:"Beheer · apparaatmeldingen",title:"Push & beveiliging",description:"Apparaten en grenzen voor beveiligde pushmeldingen."},
  praatkamer: { kicker: "Poorten · samen praten", title: "Praatkamer", description: "Tips en overleg met de poortteams." },
  overview: { kicker: "De avond · voorbereiding", title: "Jouw evenement, helder in beeld.", description: "De voorbereidingen, je deelnemers en de volgende stap. Allemaal op één plek." },
  statistics: { kicker: "Organisatie · inzicht", title: "Statistieken", description: "Installaties, logins, omgevingsgebruik en deelactiviteit." },
  imports: { kicker: "Beheer · gegevens", title: "Imports", description: "Controleer bronbestanden voordat gegevens worden toegepast." },
  registrations: { kicker: "Deelnemers · groepen", title: "Inschrijvingen", description: "Iedere inschrijving direct in beeld, met groep en deelnemers." },
  together: { kicker: "Deelnemers · samenloop", title: "Samenloop", description: "Beheer bevestigde samenlopen en beoordeel verzoeken om samen te lopen." },
  poortenboek: { kicker: "Deelnemers · kindomgeving", title: "Het Poortenboek", description: "Keuzenamen, stemrondes en sluitingsmomenten voor de kindteams." },
  groups: { kicker: "Deelnemers · indeling", title: "Groepsindeling", description: "Maak wandelgroepen en zie direct hoeveel kinderen iedere groep telt." },
  payments: { kicker: "Deelnemers · betalingen", title: "Betalingen", description: "Betaallinks, ontvangsten en uitzonderingen per kind." },
  portals: { kicker: "De avond · voorbereiding", title: "Poorten", description: "Beoordeel huizen en houd hun gegevens actueel." },
  planner: { kicker: "De avond · voorbereiding", title: "Startregie", description: "Verdeel routegroepen veilig over startpunten en beschikbare tijden." },
  editorial: { kicker: "Verhalen · nieuws · Nachtpost", title: "Redactiekamer", description: "Schrijf het verhaal van de nacht en bereik de juiste mensen." },
  share: { kicker: "Communicatie · delen", title: "Deelstudio", description: "Beheer deelkaarten, campagneperiodes en privacyvriendelijke funnels." },
  content: { kicker: "Website · redactie", title: "Content & sponsors", description: "Beheer zichtbare informatie en partners." },
  access: { kicker: "Organisatie · toegang", title: "Beheerders", description: "Bepaal wie welk onderdeel van de nacht mag beheren." },
  readiness: {kicker:"De avond · voorbereiding",title:"Gereed voor de avond",description:"Voorbereiding per groep en poort, met bron en tijdstip."},
  live: { kicker: "De avond · live", title: "Avondcockpit", description: "Volg de groepen en poorten en help waar dat nodig is." },
  tickets: { kicker: "Eén doorlopend gesprek", title: "Messenger", description: "Nieuwe berichten, lopende gesprekken en antwoorden in één inbox." },
  updates: { kicker: "Communicatie · gericht", title: "Gerichte updates", description: "Bereik precies de groepen of huizen waarvoor een wijziging geldt." },
  simulation: { kicker: "Samen oefenen", title: "Generale repetitie", description: "Test de hele tocht virtueel met een eigen testgroep, van eerste scan tot laatste zegel." },
  thanks: { kicker: "Een warm bedankje", title: "Bedankjes", description: "Bekijk de dankwoorden van gezinnen voor de poortbewoners." },
  settings: { kicker: "Grenzen en toegang", title: "Instellingen", description: "Beheer inschrijfkanalen, groepsgrenzen en operationele voorbereiding." },
} as const;
const runStatusLabels:Record<string,string>={draft:"Concept",ready:"Voor vertrek",live:"Onderweg",paused:"Gepauzeerd",completed:"Afgerond",stopped:"Afgemeld",archived:"Gearchiveerd"};
const paymentStatusLabels: Record<string, string> = {
  cancelled: "Afgezegd",
  needs_review: "Controle nodig",
  awaiting_link: "Wacht op betaallink",
  awaiting_payment: "Wacht op betaling",
  reported: "Betaling gemeld",
  confirmed: "Betaald",
  partial: "Deels betaald",
  refund_due: "Terugbetaling nodig",
  refunded: "Terugbetaald",
  waived: "Geen betaling nodig",
};
type PaymentViewStatus = "waiting" | "unpaid" | "paid";
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

export function AdminConsole({ eventSlug, capabilities, editorialEnabled = false }: { eventSlug: string; capabilities: string[]; editorialEnabled?: boolean }) {
  const event=useEventDetails();
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const sectionAllowed=(key:string)=>{
    const can=(...items:string[])=>capabilities.includes('event_admin')||items.some(item=>capabilities.includes(item));
    const allowed:Record<string,boolean>={overview:can('registration_manage','portals_manage','groups_manage','live_support'),registrations:can('registration_manage'),together:can('registration_manage','groups_manage'),groups:can('groups_manage'),payments:can('payments_manage'),poortenboek:can('groups_manage'),portals:can('portals_manage'),planner:can('groups_manage'),tickets:can('groups_manage','live_support'),updates:can('content_manage','live_support'),praatkamer:can('portals_manage','live_support'),editorial:editorialEnabled&&can('content_manage','content_publish','communications_manage','communications_send'),share:can('communications_manage'),content:can('content_manage','content_publish'),readiness:can('live_support','groups_manage','portals_manage'),live:can('live_support'),simulation:can('live_support'),thanks:can('live_support'),settings:can(),security:can(),access:can(),imports:can('registration_manage','portals_manage','groups_manage'),statistics:can()};
    return allowed[key]??false;
  };
  const [section, setSection] = useState<
    | "praatkamer"
    | "overview"
    | "statistics"
    | "imports"
    | "registrations"
    | "groups"
    | "together"
    | "poortenboek"
    | "payments"
    | "portals"
    | "planner"
    | "editorial"
    | "share"
    | "content"
    | "access"
    | "readiness"
    | "live"
    | "tickets"
    | "updates"
    | "simulation"
    | "thanks"
    | "settings"
    | "security"
  >(()=>{const requested=new URLSearchParams(typeof window === "undefined" ? "" : window.location.search).get("view");return requested&&requested in sectionMeta&&sectionAllowed(requested)?requested as keyof typeof sectionMeta:(sectionAllowed("overview")?"overview":Object.keys(sectionMeta).find(sectionAllowed)??"overview") as keyof typeof sectionMeta});
  const canUsePraatkamer = capabilities.some(c => ["event_admin", "portals_manage", "live_support"].includes(c));
  const canManageGroups = capabilities.includes("event_admin") || capabilities.includes("groups_manage");
  const canManageTogether = canManageGroups || capabilities.includes("registration_manage");
  const canUseTickets = capabilities.includes("event_admin") || capabilities.includes("groups_manage") || capabilities.includes("live_support");
  const canUseLive = capabilities.includes("event_admin") || capabilities.includes("live_support");
  const canManageShares = capabilities.includes("event_admin") || capabilities.includes("communications_manage");
  const canViewStatistics = capabilities.includes("event_admin");
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [commandOpen, setCommandOpen] = useState(false);
  const [commandQuery, setCommandQuery] = useState("");
  useEffect(() => { const key=(event:KeyboardEvent)=>{if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==="k"){event.preventDefault();setCommandOpen(value=>!value)}};window.addEventListener("keydown",key);return()=>window.removeEventListener("keydown",key)},[]);
  const contentRef = useRef<HTMLElement>(null);
  useEffect(() => { contentRef.current?.scrollTo({ top: 0 }); }, [section]);
  const navigationRef = useRef<HTMLElement>(null);
  const headerMenuButtonRef = useRef<HTMLButtonElement>(null);
  const bottomNavMoreButtonRef = useRef<HTMLButtonElement>(null);
  const navigationOpenerRef = useRef<HTMLButtonElement | null>(null);
  const closeMenuRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!mobileNavOpen) return;
    const menuButton = navigationOpenerRef.current;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const focusFrame = window.requestAnimationFrame(() => closeMenuRef.current?.focus());
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
      window.cancelAnimationFrame(focusFrame);
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
  const [eveningHealth,setEveningHealth]=useState(emptyEveningHealth);
  const sourceRequests=useRef({dashboard:0,cockpit:0,portals:0});
  const [eveningAction,setEveningAction]=useState<EveningAction|null>(null);
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
  const [selectedPaymentIds, setSelectedPaymentIds] = useState<string[]>([]);
  const [paymentPayerId, setPaymentPayerId] = useState("");
  const [paymentLink, setPaymentLink] = useState("");
  const [paymentBusy, setPaymentBusy] = useState(false);
  const paymentMutation = useRef(false);
  const paymentForm = useRef<HTMLFormElement | null>(null);
  const paymentPublishKey = useRef<{ payload: string; key: string } | null>(null);
  const selectedPayments = childPayments.filter((payment) => selectedPaymentIds.includes(payment.childId));
  const selectedPayer = selectedPayments.find((payment) => payment.childId === paymentPayerId) ?? selectedPayments[0];
  const selectedPaymentTotal = selectedPayments.reduce((total, payment) => total + payment.amountCents, 0);
  const paymentQuery = paymentSearch.trim().toLocaleLowerCase("nl");
  const paymentGroups = Array.from(childPayments.reduce((groups, payment) => {
    const existing = groups.get(payment.registrationId) ?? [];
    existing.push(payment);
    groups.set(payment.registrationId, existing);
    return groups;
  }, new Map<string, ChildPaymentRow[]>()).entries()).filter(([, registrationPayments]) =>
    paymentRegistrationStage(registrationPayments) !== null && registrationPayments.some((payment) =>
      [payment.firstName, payment.parentName, payment.parentEmail, payment.groupCode, payment.groupName, payment.registrationReference]
        .some((value) => value?.toLocaleLowerCase("nl").includes(paymentQuery)),
    ),
  );
  const paymentSections: Array<{ stage: PaymentRegistrationStage; title: string; description: string; groups: Array<[string, ChildPaymentRow[]]> }> = [
    { stage: "needs_link", title: "Nog een betaallink sturen", description: "Inschrijvingen met één of meer kinderen waarvoor nog geen betaallink klaarstaat.", groups: [] },
    { stage: "link_sent", title: "Betaallink verstuurd", description: "Inschrijvingen met een actieve link, een betaalmelding of een betaling die controle nodig heeft.", groups: [] },
    { stage: "paid", title: "Betaalde inschrijvingen", description: "Inschrijvingen waarvoor alle actieve kinderen betaald of vrijgesteld zijn.", groups: [] },
  ];
  for (const group of paymentGroups) {
    const stage = paymentRegistrationStage(group[1]);
    const target = paymentSections.find((candidate) => candidate.stage === stage);
    if (target) target.groups.push(group);
  }
  const [registrationChanges, setRegistrationChanges] = useState<
    RegistrationChange[]
  >([]);
  const [registrations, setRegistrations] = useState<AdminRegistration[]>([]);
  const [registrationsLoading, setRegistrationsLoading] = useState(false);
  const [registrationSearch, setRegistrationSearch] = useState("");
  const [selectedRegistrationId, setSelectedRegistrationId] = useState<string | null>(null);
  const registrationChildCount = registrations.reduce((total, registration) => total + registration.childCount, 0);
  const [togetherRequests, setTogetherRequests] = useState<TogetherRequest[]>([]);
  const load=useCallback(async()=>{
    const request=++sourceRequests.current.dashboard;
    try{const client=createClient();if(!client)throw new Error();const result=await withRequestDeadline(client.schema("api").rpc("admin_dashboard",{_event_slug:eventSlug}));
      if(request!==sourceRequests.current.dashboard)return;
      if(!result||result.error||!result.data)throw new Error();
      const next=result.data as Dashboard;if(!next.event?.id||!next.counts)throw new Error();setDashboard(next);setEveningHealth(current=>({...current,dashboard:{at:Date.now(),error:null}}));
    }catch{if(request===sourceRequests.current.dashboard)setEveningHealth(current=>({...current,dashboard:{...current.dashboard,error:"Overzicht en meldingstellers konden niet worden bijgewerkt."}}));}
  },[eventSlug]);
  const loadLive=useCallback(async()=>{
    const cockpitRequest=++sourceRequests.current.cockpit,portalRequest=++sourceRequests.current.portals;
    const client=createClient();if(!client)return;
    await Promise.allSettled([
      (async()=>{try{const result=await withRequestDeadline(client.schema("api").rpc("admin_evening_cockpit",{_event_slug:eventSlug}));if(cockpitRequest!==sourceRequests.current.cockpit)return;if(result.error||!result.data)throw new Error();const cockpit=result.data as {groups:LiveRun[];portals:LivePortal[];alerts:LiveAlert[]};if(!Array.isArray(cockpit.groups)||!Array.isArray(cockpit.portals)||!Array.isArray(cockpit.alerts))throw new Error();setLiveRuns(cockpit.groups);setLivePortals(cockpit.portals);setLiveAlerts(cockpit.alerts);setEveningHealth(current=>({...current,cockpit:{at:Date.now(),error:null}}));}catch{if(cockpitRequest===sourceRequests.current.cockpit)setEveningHealth(current=>({...current,cockpit:{...current.cockpit,error:"Groepen en veiligheidssignalen konden niet worden bijgewerkt."}}));}})(),
      (async()=>{try{const result=await withRequestDeadline(client.schema("api").rpc("admin_portal_operations_snapshot",{_event_slug:eventSlug}));if(portalRequest!==sourceRequests.current.portals)return;if(result.error||!result.data)throw new Error();const portals=result.data as {realtimeTopic?:string;portals?:PortalOperation[]};if(!Array.isArray(portals.portals))throw new Error();setPortalOperations(portals.portals??[]);setPortalRealtimeTopic(portals.realtimeTopic??null);setEveningHealth(current=>({...current,portals:{at:Date.now(),error:null}}));}catch{if(portalRequest===sourceRequests.current.portals)setEveningHealth(current=>({...current,portals:{...current.portals,error:"Poorten en capaciteit konden niet worden bijgewerkt."}}));}})()
    ]);
  },[eventSlug]);
  const refreshEvening=useCallback(async()=>{await Promise.allSettled([load(),loadLive()]);},[load,loadLive]);
  useSnapshotRefresh(refreshEvening);
  useEffect(()=>{const timer=setTimeout(()=>void refreshEvening(),0);return()=>clearTimeout(timer);},[refreshEvening]);
  useEffect(() => {
    const client = createClient();
    if (!client || !portalRealtimeTopic || !["overview", "live"].includes(section)) return;
    const refreshQueue = createCoalescedRefresh(refreshEvening);
    const channel = client.channel(portalRealtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, refreshQueue.request)
      .subscribe((status: string) => setLiveConnection(status === "SUBSCRIBED" ? "live" : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "offline" : "connecting"));
    return () => { refreshQueue.dispose(); void client.removeChannel(channel); };
  }, [liveConnectionRetry, refreshEvening, portalRealtimeTopic, section]);

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

  const loadRegistrations = useCallback(async () => {
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
  }, [eventSlug]);

  useEffect(() => {
    if (section !== "registrations") return;
    const client = createClient();
    if (!client) return;
    if (!dashboard?.event.id) return;
    const channel = client.channel(`admin-event:${dashboard.event.id}`, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void loadRegistrations()).subscribe();
    const poll = window.setInterval(() => void loadRegistrations(), 30_000);
    return () => { window.clearInterval(poll); void client.removeChannel(channel); };
  }, [dashboard?.event.id, loadRegistrations, section]);

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


  async function decideTogetherRequest(
    request: TogetherRequest,
    decision: "accept" | "reject",
  ) {
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
      .prompt("Externe betaal- of bankreferentie:")
      ?.trim();
    const reason = command === "refund"
      ? "Terugbetaling vastgelegd via beheeromgeving"
      : "Betaling bevestigd via beheeromgeving";
    if (!externalReference || amountCents <= 0)
      return setNotice("Bedrag en externe referentie zijn verplicht.");
    if (
      !window.confirm(
        `${command === "refund" ? "Terugbetaling" : "Betaling"} van € ${(amountCents / 100).toFixed(2).replace(".", ",")} vastleggen?`,
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
        : "De betaling is vastgelegd in de betalingshistorie.",
    );
    await Promise.all([loadPayments(), load()]);
    } catch { setNotice("De verbinding is onderbroken. Vernieuw het overzicht en controleer de ontvangst voordat je opnieuw bevestigt."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function clearLegacyPayment(payment: PaymentRow) {
    if (paymentMutation.current || payment.childPaymentMode) return;
    const reason = "Eerdere betaallink voor inschrijving ingetrokken";
    if (!window.confirm("Deactiveer het oude betaalverzoek ook bij de gebruikte bank of betaalprovider. Deze actie trekt de link voor de hele inschrijving in, zodat je de kinderen apart kunt selecteren. Er wordt geen betaling teruggedraaid. Doorgaan?")) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_clear_legacy", { _registration_id: payment.registrationId, _expected_version: payment.version, _reason: reason });
      setNotice(error ? `Intrekken geweigerd: ${error.message}` : "Eerdere betaallink ingetrokken. Deactiveer ook het externe betaalverzoek voordat je nieuwe links per kind verstuurt.");
      if (!error) setSelectedPaymentIds([]);
      await loadPayments();
    } catch { setNotice("De verbinding is onderbroken. Vernieuw het overzicht om de status van de eerdere betaallink te controleren."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function confirmChildPayment(batch: ChildPaymentBatch, command: "confirm" | "refund" = "confirm") {
    if (paymentMutation.current) return;
    const amount = window.prompt(command === "refund" ? "Werkelijk buiten de app terugbetaald bedrag in euro" : "Werkelijk ontvangen bedrag in euro", (batch.totalAmountCents / 100).toFixed(2).replace(".", ","))?.trim();
    if (!amount || !/^\d+(?:[,.]\d{1,2})?$/.test(amount) || Math.round(Number(amount.replace(",", ".")) * 100) !== batch.totalAmountCents) return setNotice(`Bevestig exact ${paymentAmount(batch.totalAmountCents)} voor ${batch.childNames.join(", ")}. Controleer een afwijkende ontvangst eerst.`);
    const reference = window.prompt("Externe betaal- of bankreferentie:")?.trim();
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
    if (!window.confirm(`Markeer het betaalverzoek voor ${batch.childNames.join(", ")} als niet betaald en maak de betaallink opnieuw beschikbaar?`)) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_mark_unpaid", {
        _batch_id: batch.id,
        _expected_version: batch.version,
      });
      setNotice(error ? `Statuswijziging geweigerd: ${error.message}` : "Het betaalverzoek staat weer op niet betaald en de betaallink is opnieuw beschikbaar.");
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
        ? "Publiceer eerst een betaallink voor dit kind voordat je de ontvangst als betaald kunt bevestigen."
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
        setNotice("De eerdere selectie is gewist. Eén betaallink bevat alleen kinderen uit dezelfde inschrijving.");
      }
      return [...new Set([...sameRegistration, ...ids])];
    });
    if (checked) setPaymentPayerId(payment.batch?.anchorChildId ?? payment.childId);
    if (checked && payment.batch?.externalUrl) setPaymentLink(payment.batch.externalUrl);
  }

  function prepareReplacementPaymentLink(batch: ChildPaymentBatch) {
    const members = childPayments.filter((payment) => payment.batch?.id === batch.id);
    setSelectedPaymentIds(members.map((payment) => payment.childId));
    setPaymentPayerId(batch.anchorChildId);
    setPaymentLink("");
    setNotice(`Nieuwe betaallink voor ${members.map((payment) => payment.firstName).join(" en ")} staat klaar om in te vullen.`);
    window.requestAnimationFrame(() => paymentForm.current?.scrollIntoView({ behavior: "smooth", block: "center" }));
  }

  async function publishPaymentLink() {
    if (paymentMutation.current) return;
    if (!selectedPayments.length || !paymentLink.trim()) return setNotice("Selecteer kinderen en vul een betaallink in.");
    if (new Set(selectedPayments.map((payment) => payment.registrationId)).size !== 1) return setNotice("Selecteer alleen kinderen uit dezelfde inschrijving.");
    if (!window.confirm(`Eén gezamenlijke betaallink van ${paymentAmount(selectedPaymentTotal)} voor ${selectedPayments.length} kind(eren) publiceren en per e-mail versturen? Controleer dat het externe betaalverzoek dit totaalbedrag bevat.`)) return;
    const client = createClient();
    if (!client) return;
    const payload = { _event_slug: eventSlug, _children: selectedPayments.map(({ childId, version }) => ({ id: childId, version })), _external_url: paymentLink.trim(), _anchor_child_id: selectedPayer?.childId, _reason: "Betaallink gepubliceerd via beheeromgeving" };
    const serialized = JSON.stringify(payload);
    if (paymentPublishKey.current?.payload !== serialized) paymentPublishKey.current = { payload: serialized, key: crypto.randomUUID() };
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc("admin_child_payment_publish", { ...payload, _idempotency_key: paymentPublishKey.current.key });
      setNotice(error ? `Betaallink niet gepubliceerd: ${error.message}` : "Gezamenlijke betaallink gepubliceerd. De e-mails staan klaar voor verzending; ontvangst moet nog worden gecontroleerd.");
      if (!error) { setSelectedPaymentIds([]); setPaymentLink(""); paymentPublishKey.current = null; }
      await loadPayments();
    } catch { setNotice("De verbinding is onderbroken. Probeer dezelfde opdracht opnieuw; je selectie blijft bewaard."); }
    finally { paymentMutation.current = false; setPaymentBusy(false); }
  }

  async function cancelPaymentBatch(batch: ChildPaymentBatch | PaymentBatch, legacy = false) {
    if (paymentMutation.current) return;
    const reason = "Gezamenlijk betaalverzoek opgeheven via beheeromgeving";
    if (!window.confirm("Deactiveer het oude betaalverzoek ook bij de gebruikte bank of betaalprovider. Deze actie verwijdert de link uit de dashboards en maakt de kinderen weer apart selecteerbaar. Er wordt geen betaling of terugbetaling vastgelegd. Doorgaan?")) return;
    const client = createClient();
    if (!client) return;
    paymentMutation.current = true;
    setPaymentBusy(true);
    try {
      const { error } = await client.schema("api").rpc(legacy ? "admin_payment_batch_cancel" : "admin_child_payment_cancel", { _batch_id: batch.id, _expected_version: batch.version, _reason: reason });
      setNotice(error ? `Opheffen geweigerd: ${error.message}` : "Gezamenlijk betaalverzoek opgeheven. Controleer dat het externe betaalverzoek is gedeactiveerd voordat je een nieuw verzoek verstuurt.");
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
        `Leider van ${run.groupCode} direct vervangen door ${email}? De vorige groepsleider kan daarna geen wijzigingen meer doen.`,
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
        : "Leider vervangen; de vorige groepsleider kan geen wijzigingen meer doen.",
    );
    await loadLive();
  }

  function redirectGroup(run:LiveRun,target:"ordinary"|"finale") {if(run.runId)setEveningAction({runId:run.runId,groupId:run.groupId,groupCode:run.systemCode||run.groupCode,mode:target,opener:document.activeElement as HTMLElement|null});}
  function safeWithdraw(run:LiveRun) {if(run.runId)setEveningAction({runId:run.runId,groupId:run.groupId,groupCode:run.systemCode||run.groupCode,mode:"withdraw",opener:document.activeElement as HTMLElement|null});}

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

  async function sendTestPush() {
    setNotice("Testmelding wordt verstuurd…");
    try {
      const response = await fetch("/api/push/test", { method: "POST", cache: "no-store" });
      const result = await response.json() as { data?: { delivered?: number }; error?: { message?: string } };
      if (!response.ok) throw new Error(result.error?.message || "De testmelding kon niet worden verstuurd.");
      setNotice(`Testmelding afgeleverd op ${result.data?.delivered ?? 0} apparaat/apparaten.`);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "De testmelding kon niet worden verstuurd.");
    }
  }

  const notificationCount = (canUseLive ? liveAlerts.length : 0)
    + (canManageTogether ? dashboard?.counts.pendingTogetherRequests ?? 0 : 0)
    + (canUseTickets ? dashboard?.counts.openTickets ?? 0 : 0);

  if (!dashboard&&eveningHealth.dashboard.error)return <div className="panel" role="alert"><h1>Beheergegevens niet beschikbaar</h1><p>{eveningHealth.dashboard.error}</p><button className="btn" onClick={()=>void refreshEvening()}>Opnieuw proberen</button></div>;
  if (!dashboard)
    return (
      <div className="panel loading-state">
        <RefreshCw className="spin" />
        Beheergegevens ophalen…
      </div>
    );
  const navGroups=[
    {key:"overview",label:"Overzicht",icon:LayoutDashboard,sections:["overview"]},
    {key:"participants",label:"Deelnemers",icon:UsersRound,sections:["registrations","together","groups","payments","poortenboek"]},
    {key:"portals",label:"Poorten",icon:DoorOpen,sections:["portals"]},
    {key:"planning",label:"Startregie",icon:CalendarClock,sections:["planner"]},
    {key:"communications",label:"Communicatie",icon:MessageSquare,sections:["tickets","updates","praatkamer",...(editorialEnabled?["editorial"]:[]),"share","content"]},
    {key:"evening",label:"De avond",icon:LifeBuoy,sections:["live","readiness","simulation","thanks"]},
    {key:"management",label:"Beheer",icon:SlidersHorizontal,sections:["settings","security","access","imports","statistics"]}
  ];
  const permittedNavGroups=navGroups.map(item=>({...item,sections:item.sections.filter(sectionAllowed)})).filter(item=>item.sections.length>0);
  const activeGroup=permittedNavGroups.find(item=>item.sections.includes(section))??permittedNavGroups[0]??navGroups[0];
  function openSection(next:keyof typeof sectionMeta){if(!sectionAllowed(next))return;setSection(next);setMobileNavOpen(false);setCommandOpen(false);setCommandQuery("");history.replaceState(null,"",`/admin?view=${next}`);if(next==="registrations")void Promise.all([loadRegistrations(),loadRegistrationChanges(),loadTogetherRequests()]);if(next==="payments")void loadPayments();if(next==="live"||next==="simulation")void loadLive();}
  const commandResults=Object.entries(sectionMeta).filter(([key,value])=>sectionAllowed(key)&&(!commandQuery||`${value.title} ${value.description}`.toLowerCase().includes(commandQuery.toLowerCase())));
  return (
    <div className="admin-shell modern-admin-shell">
      {eveningAction&&<EveningActionDialog key={eveningAction.runId+eveningAction.mode} action={eveningAction} onClose={()=>setEveningAction(null)} onSaved={async message=>{setNotice(message);await refreshEvening();}}/>}
      <EnvironmentTracker surface={section === "editorial" ? "editorial" : "admin"} />
      <Dialog open={commandOpen} onOpenChange={setCommandOpen}><DialogContent className="modern-command-dialog"><DialogTitle>Waar wil je naartoe?</DialogTitle><DialogDescription>Zoek een onderdeel van je evenement.</DialogDescription><div className="modern-command-input"><Search/><input autoFocus type="search" value={commandQuery} onChange={event=>setCommandQuery(event.target.value)} placeholder="Zoek inschrijvingen, startregie, berichten…" aria-label="Zoek onderdeel"/><kbd>ESC</kbd></div><div className="modern-command-results">{commandResults.map(([key,value])=><button key={key} onClick={()=>openSection(key as keyof typeof sectionMeta)}><span><strong>{value.title}</strong><small>{value.description}</small></span><ArrowUpRight/></button>)}{commandResults.length===0&&<p>Geen onderdeel gevonden. Probeer een andere zoekterm.</p>}</div></DialogContent></Dialog>
      {mobileNavOpen && <button className="admin-nav-backdrop" tabIndex={-1} aria-label="Navigatie sluiten" onClick={() => setMobileNavOpen(false)} />}
      <aside
        id="admin-navigation"
        ref={navigationRef}
        className={`admin-nav${mobileNavOpen ? " is-open" : ""}`}
        role={mobileNavOpen ? "dialog" : undefined}
        aria-modal={mobileNavOpen ? true : undefined}
        aria-label="Organisatienavigatie"
        onTransitionEnd={(event) => {
          if (mobileNavOpen && event.target === event.currentTarget && event.propertyName === "transform" && !event.currentTarget.contains(document.activeElement)) closeMenuRef.current?.focus();
        }}
        onClick={(event) => {
          if ((event.target as HTMLElement).closest("button, a")) setMobileNavOpen(false);
        }}
      >
        <div className="admin-drawer-heading">
          <span>Nachtregie</span>
          <button ref={closeMenuRef} type="button" aria-label="Menu sluiten" onClick={() => setMobileNavOpen(false)}><X aria-hidden="true" /></button>
        </div>
        <Link className="admin-brand modern-admin-brand" href="/">
          <Image src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" width={64} height={44} priority />
          <span><strong>De Poorten<span className="modern-brand-spark">✦</span></strong><small>ORGANISATIE</small></span>
        </Link>
        <div className="modern-event-select"><span className="modern-event-date"><strong>{event.day}</strong>{event.monthShort.toUpperCase()}</span><div><strong>Halloween {event.year}</strong><small>Duindorp · Den Haag</small></div><ChevronRight /></div>
        <p className="modern-nav-heading">WERKRUIMTE</p>
        <nav className="modern-primary-nav" aria-label="Hoofdonderdelen organisatie">{permittedNavGroups.map(item=><button key={item.key} className={activeGroup.key===item.key?"active":""} aria-current={activeGroup.key===item.key?"page":undefined} onClick={()=>openSection(item.sections[0] as keyof typeof sectionMeta)}><item.icon/><span>{item.label}</span>{item.key==="participants"&&dashboard.counts.registrations>0?<b>{dashboard.counts.registrations}</b>:item.key==="communications"&&(dashboard.counts.openTickets??0)>0?<i/>:null}</button>)}</nav>
        <div className="modern-admin-sidebar-bottom"><div className="modern-night-card"><span>DE NACHT KOMT DICHTERBIJ</span><strong>Samen maken<br/>we de magie.</strong><small>{event.dateShort} · {event.times}</small><button onClick={()=>openSection("simulation")}><Play size={14}/> Generale openen <ArrowUpRight size={14}/></button></div><Link className="modern-public-link" href="/"><ArrowUpRight/> Bekijk de website</Link><button className="modern-admin-profile" onClick={()=>openSection("settings")}><span>DS</span><div><strong>Organisatie</strong><small>De Duindorpse Poorten</small></div><SlidersHorizontal/></button></div>
      </aside>
      <div className="admin-workspace" inert={mobileNavOpen}>
        <header className="admin-appbar" aria-label="Nachtregie werkbalk">
          <button ref={headerMenuButtonRef} className="admin-menu-toggle" type="button" aria-label="Organisatienavigatie openen" aria-controls="admin-navigation" aria-expanded={mobileNavOpen} onClick={() => { navigationOpenerRef.current = headerMenuButtonRef.current; setMobileNavOpen(true); }}>
            <Menu aria-hidden="true" /><span>Menu</span>
          </button>
          <div className="modern-admin-breadcrumb"><span>Organisatie</span><ChevronRight/><strong>{activeGroup.label}</strong></div>
          <button className="modern-command-trigger" aria-label="Zoek een onderdeel" onClick={()=>setCommandOpen(true)}><Search/><span>Zoek een onderdeel…</span><kbd>⌘ K</kbd></button><span className="modern-event-pill"><CalendarDays/>{event.dateLong}</span>
          <Dialog open={notificationsOpen} onOpenChange={setNotificationsOpen}>
            <DialogTrigger asChild>
              <button type="button" className="admin-notifications-button" aria-label={`Meldingen openen${notificationCount ? `, ${notificationCount} open aandachtspunten` : ""}`}>
                <BellRing aria-hidden="true" />
                {notificationCount > 0 && <b aria-hidden="true">{notificationCount > 99 ? "99+" : notificationCount}</b>}
              </button>
            </DialogTrigger>
            <DialogContent className="admin-notifications-dialog" showCloseButton={false}>
              <DialogTitle>Meldingen</DialogTitle>
              <DialogDescription>Open aandachtspunten voor de organisatie.</DialogDescription>
              <DialogClose className="admin-notifications-close" aria-label="Meldingen sluiten"><X aria-hidden="true" /></DialogClose>
              {notificationCount === 0 && <p>Er zijn op dit moment geen open aandachtspunten.</p>}
              {canUseLive && liveAlerts.map((alert) => <button type="button" className="admin-notification-item" key={alert.id} onClick={() => { setSection("live"); setNotificationsOpen(false); }}><AlertTriangle aria-hidden="true" /><span><strong>{alert.code}</strong><small>{alert.message}</small></span><ArrowRight aria-hidden="true" /></button>)}
              {canManageTogether && (dashboard.counts.pendingTogetherRequests ?? 0) > 0 && <button type="button" className="admin-notification-item" onClick={() => { setSection("together"); setNotificationsOpen(false); }}><UsersRound aria-hidden="true" /><span><strong>{dashboard.counts.pendingTogetherRequests} samenloopverzoek(en)</strong><small>Bekijk de aanvragen die op beoordeling wachten.</small></span><ArrowRight aria-hidden="true" /></button>}
              {canUseTickets && (dashboard.counts.openTickets ?? 0) > 0 && <button type="button" className="admin-notification-item" onClick={() => { setSection("tickets"); setNotificationsOpen(false); }}><MessageSquare aria-hidden="true" /><span><strong>{dashboard.counts.openTickets} open gesprek(ken)</strong><small>Open de berichten van deelnemers.</small></span><ArrowRight aria-hidden="true" /></button>}
            </DialogContent>
          </Dialog>
        </header>
        {activeGroup.sections.length>1&&<nav className="modern-admin-subnav" aria-label={`${activeGroup.label} onderdelen`}>{activeGroup.sections.map(key=><button key={key} className={section===key?"active":""} aria-current={section===key?"page":undefined} onClick={()=>openSection(key as keyof typeof sectionMeta)}>{({registrations:"Inschrijvingen",together:"Samenlopen",groups:"Groepsindeling",payments:"Betalingen",poortenboek:"Poortenboek",tickets:"Inbox",updates:"Updates",praatkamer:"Praatkamer",editorial:"Redactiekamer",share:"Deelstudio",content:"Website & sponsors",live:"Livecockpit",readiness:"Gereed voor de avond",simulation:"Generale",thanks:"Bedankjes",settings:"Instellingen",security:"Push & beveiliging",access:"Beheerders",imports:"Imports",statistics:"Statistieken"} as Record<string,string>)[key]}</button>)}</nav>}
        <main ref={contentRef} id="admin-content" className="admin-content" data-admin-section={section} tabIndex={-1}>
        {section === "statistics" ? null : ["praatkamer", "groups", "together", "poortenboek", "portals", "planner", "tickets", "updates", "editorial", "share", "content", "access"].includes(section) ? <h1 className="sr-only">{sectionMeta[section].title}</h1> : <header className="app-heading admin-page-heading row-between">
          <div>
            <p className="kicker">{sectionMeta[section].kicker}</p>
            <h1>{sectionMeta[section].title}</h1>
            <p>{sectionMeta[section].description}</p>
          </div>
          <div className="actions">{section==="overview"&&<button className="btn" onClick={()=>openSection("live")}><LifeBuoy/>Open avondcockpit<ArrowUpRight/></button>}<button className="btn outline modern-refresh-button" aria-label="Overzicht vernieuwen" onClick={() => void Promise.all([load(), section === "registrations" ? loadRegistrations() : Promise.resolve()])}><RefreshCw /></button></div>
        </header>}
        {notice && (
          <div className="form-notice" role="status">
            {notice}
          </div>
        )}
        {section === "security" && <PushSecurity/>}
        {section === "settings" && (
          <>
            <section className="panel registration-controls">
              <p className="kicker">Aanmeldingen beheren</p>
              <div className="row-between registration-controls-heading">
                <div>
                  <h2>Open ieder kanaal op het juiste moment.</h2>
                  <p>Laat bijvoorbeeld eerst woningen, portieken en bedrijven aanmelden en open de groepsinschrijving pas later. Wijzigingen gelden direct.</p>
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
                  <GroupSizePolicy eventSlug={eventSlug} maximum={dashboard.event.maxGroupSize} target={dashboard.event.targetGroupSize??dashboard.event.maxGroupSize} followsMaximum={dashboard.event.targetFollowsMaximum??true} settingsVersion={dashboard.event.settingsVersion} onSaved={async()=>{await Promise.all([load(),loadTogetherRequests()]);}} onOpenGroups={()=>openSection('groups')}/>
                )}
                {capabilities.includes("event_admin") && <article className="panel registration-channel">
                  <BellRing />
                  <div><h3>Staging-testmelding</h3><p>Zet meldingen op dit apparaat aan en verstuur daarna een neutrale test. Deze test is beschikbaar in de testomgeving.</p></div>
                  <PushNotificationSettings />
                  <button className="btn outline" type="button" onClick={() => void sendTestPush()}>Testmelding versturen</button>
                </article>}
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
            <div className="modern-overview-actions"><button onClick={()=>openSection("together")}><span className="modern-shortcut-icon violet"><UsersRound/></span><span><strong>Samen op pad</strong><small>{dashboard.counts.pendingTogetherRequests??0} samenloopverzoek(en) beoordelen</small></span><ArrowUpRight/></button><button onClick={()=>openSection("planner")}><span className="modern-shortcut-icon amber"><CalendarClock/></span><span><strong>Iedereen een goede start</strong><small>Open de startindeling</small></span><ArrowUpRight/></button><button onClick={()=>openSection("tickets")}><span className="modern-shortcut-icon mint"><MessageSquare/></span><span><strong>Even contact</strong><small>{dashboard.counts.openTickets??0} open gesprek(ken)</small></span><ArrowUpRight/></button></div>
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
                  <div className="row-between"><div><p className="kicker">Direct handelen</p><h2>Even jouw aandacht</h2></div><span className="registration-total">{liveAlerts.length + (dashboard.counts.pendingTogetherRequests ?? 0)} open</span></div>
                  {liveAlerts.length === 0 && !(dashboard.counts.pendingTogetherRequests ?? 0) ? <p className="form-notice">Geen veiligheidsmeldingen of samenloopverzoeken die nu actie vragen.</p> : <>
                    {liveAlerts.slice(0, 3).map((alert) => <div className="cockpit-action-row" key={alert.id}><AlertTriangle /><div><strong>{alert.code}</strong><span>{alert.message}</span></div><button className="text-link" onClick={() => setSection("live")}>Bekijk <ArrowRight /></button></div>)}
                    {(dashboard.counts.pendingTogetherRequests ?? 0) > 0 && <div className="cockpit-action-row"><UsersRound /><div><strong>{dashboard.counts.pendingTogetherRequests} samenloopverzoek(en)</strong><span>Controleer groepsgrootte en de gezamenlijke indeling.</span></div><button className="text-link" onClick={() => { setSection("together"); }}>Bekijk <ArrowRight /></button></div>}
                  </>}
                </section>
                <section className="panel cockpit-live-log">
                  <div className="row-between"><div><p className="kicker">Binnenkomend</p><h2>Laatste activiteit</h2></div><button className="text-link" onClick={() => void Promise.all([load(), loadLive()])}>Vernieuwen <RefreshCw /></button></div>
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
                <div className="cockpit-group-list">{liveRuns.length === 0 ? <p>Nog geen groepen onderweg.</p> : liveRuns.slice(0, 6).map((run) => <article key={run.groupId}><span>{run.systemCode || run.groupCode}</span><div><strong>{run.displayName || "Groep " + run.groupCode}</strong><small>{run.currentPortal || "Wacht op volgende bestemming"} · {run.childCount} kinderen</small></div><b>{({live:"Onderweg",ready:"Voor vertrek",paused:"Gepauzeerd",draft:"Concept",completed:"Afgerond"} as Record<string,string>)[run.runStatus || run.status] || run.status}</b></article>)}</div>
              </section>
            </div>
          </>
        )}
        {section === "simulation" && <VirtualRehearsal/>}
        {section === "thanks" && <AdminPortalThanks/>}
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
            <p className="kicker">Betaallinks & ontvangstcontrole</p>
            <h2>Betalingen per inschrijving</h2>
            <p>Open een inschrijving en selecteer de kinderen die samen op één betaallink komen. Een eerder verstuurde link kun je voor dezelfde kinderen vervangen wanneer die is verlopen.</p>
            <label className="field"><span>Zoek kind, ouder, e-mail, groep of referentie</span><input type="search" value={paymentSearch} onChange={(event) => setPaymentSearch(event.target.value)} placeholder="Naam van kind, ouder of groep" /></label>
            {selectedPayments.length > 0 && <form ref={paymentForm} className="payment-publish-form" onSubmit={(event) => { event.preventDefault(); void publishPaymentLink(); }}>
              <h3>Betaallink voor geselecteerde kinderen</h3>
              <p><strong>{selectedPayments.length} kind(eren) geselecteerd · {paymentAmount(selectedPaymentTotal)}</strong></p>
              <ul className="payment-selection-list">{selectedPayments.map((payment) => <li key={payment.childId}>{payment.firstName} · {payment.parentName} · {paymentAmount(payment.amountCents)}</li>)}</ul>
              <label className="field"><span>Betaalknop bij</span><select className="choice" value={selectedPayer?.childId ?? ""} onChange={(event) => setPaymentPayerId(event.target.value)}>{selectedPayments.map((payment) => <option key={payment.childId} value={payment.childId}>{payment.firstName} · {payment.parentName || payment.registrationReference}</option>)}</select></label>
              <p className="note">Maak bij je bank of betaalprovider één veilige HTTPS-link voor exact dit totaal. Bij een bestaand verzoek selecteren we alle gekoppelde kinderen. Hef dat verzoek eerst op om de samenstelling te veranderen en deactiveer de oude externe betaallink.</p>
              <label className="field"><span>Betaallink voor het totaalbedrag</span><input type="url" inputMode="url" autoComplete="url" required value={paymentLink} onChange={(event) => setPaymentLink(event.target.value)} placeholder="https://betaalprovider.nl/verzoek/…" /></label>
              <div className="actions"><button className="btn" disabled={paymentBusy} type="submit">{paymentBusy ? "Bezig…" : "Betaallink publiceren en e-mail versturen"}</button><button className="btn outline" type="button" disabled={paymentBusy} onClick={() => { setSelectedPaymentIds([]); setPaymentLink(""); }}>Selectie wissen</button></div>
            </form>}
            <div className="payment-state-lists">
              {paymentSections.map((paymentSection) => <section className={`payment-state-section payment-state-${paymentSection.stage}`} key={paymentSection.stage} aria-labelledby={`payment-state-${paymentSection.stage}`}>
                <header className="payment-state-heading">
                  <div><p className="kicker">Per inschrijving</p><h3 id={`payment-state-${paymentSection.stage}`}>{paymentSection.title}</h3><p>{paymentSection.description}</p></div>
                  <strong>{paymentSection.groups.length}</strong>
                </header>
                {paymentSection.groups.length === 0 ? <div className="payment-registration-empty">{paymentQuery ? "Geen inschrijvingen gevonden voor deze zoekopdracht." : "Geen inschrijvingen in deze lijst."}</div> : <div className="payment-registration-list">
                  {paymentSection.groups.map(([registrationId, registrationPayments]) => {
                    const registration = registrationPayments[0];
                    const selectedInRegistration = registrationPayments.filter((payment) => selectedPaymentIds.includes(payment.childId)).length;
                    const activePayments = registrationPayments.filter((payment) => payment.status !== "cancelled");
                    const paidCount = activePayments.filter((payment) => paymentViewStatus(payment) === "paid").length;
                    const waitingCount = activePayments.filter((payment) => paymentViewStatus(payment) === "waiting").length;
                    return <details className="payment-registration-group" key={registrationId}>
                      <summary>
                        <span className="registration-group-mark">{registration.groupCode ?? registration.registrationReference.slice(-2)}</span>
                        <span className="payment-registration-heading">
                          <strong>{registration.groupName || registration.registrationReference}</strong>
                          <small>{registration.parentName || "Ouder nog niet bekend"} · {registration.parentEmail || "geen e-mailadres"}</small>
                        </span>
                        <span className="payment-registration-reference">{registration.registrationReference}<small>{activePayments.length} {activePayments.length === 1 ? "kind" : "kinderen"}</small></span>
                        <span className="payment-registration-progress"><strong>{paidCount}/{activePayments.length} betaald</strong>{waitingCount > 0 && <small>{waitingCount} wachtend op controle</small>}{selectedInRegistration > 0 && <small>{selectedInRegistration} geselecteerd</small>}</span>
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
                            {payment.batch && <div className="payment-admin-batch">{payment.batch.legacy && <p>Dit kind is gekoppeld aan een eerder verzoek per inschrijving. Beheer dat verzoek bij de betalingshistorie voordat je kinderen afzonderlijk selecteert.</p>}{!batchWithinRegistration && <p>Deze oudere betaallink bevat kinderen uit meerdere inschrijvingen. Hef hem eerst op; nieuwe betaallinks worden per inschrijving gemaakt.</p>}<strong>Gekoppelde kinderen · totaal {paymentAmount(payment.batch.totalAmountCents)}</strong><p>{payment.batch.childNames.join(" · ")}</p><p>{activeAnchor ? "Betaalknop bij dit kind" : `Inbegrepen bij ${payment.batch.anchorChildName} · geen aparte betaling`}</p>{payment.batch.status === "needs_review" && <p>Controle nodig: gebruik de eerdere link niet. Controleer de ontvangst en hef het verzoek zo nodig op.</p>}</div>}
                            <div className="actions">
                              {payment.batch?.externalUrl && payment.batch.status === "awaiting_payment" && (activeAnchor ? <a className="btn outline" href={payment.batch.externalUrl} target="_blank" rel="noreferrer noopener">Betaallink bij {payment.firstName}</a> : <button className="btn outline" disabled>Inbegrepen bij {payment.batch.anchorChildName}</button>)}
                              {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status === "awaiting_payment" && <button className="btn outline" type="button" disabled={paymentBusy} onClick={() => prepareReplacementPaymentLink(payment.batch!)}>Nieuwe betaallink sturen</button>}
                              {firstBatchRow && payment.batch && !payment.batch.legacy && ["awaiting_payment", "reported"].includes(payment.batch.status) && <button className="btn outline" type="button" disabled={paymentBusy} onClick={() => void confirmChildPayment(payment.batch!)}>Bevestig ontvangst {paymentAmount(payment.batch.totalAmountCents)}</button>}
                              {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status === "reported" && <button className="btn outline" type="button" disabled={paymentBusy} onClick={() => void markChildPaymentUnpaid(payment.batch!)}>Markeer niet betaald</button>}
                              {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status === "confirmed" && <button className="btn outline" type="button" disabled={paymentBusy} onClick={() => void confirmChildPayment(payment.batch!, "refund")}>Leg terugbetaling vast</button>}
                              {firstBatchRow && payment.batch && !payment.batch.legacy && payment.batch.status !== "confirmed" && <button className="btn outline" type="button" disabled={paymentBusy} onClick={() => void cancelPaymentBatch(payment.batch!)}>Betaalverzoek opheffen</button>}
                            </div>
                          </article>;
                        })}
                      </div>
                    </details>;
                  })}
                </div>}
              </section>)}
            </div>
            <details className="payment-publish-form"><summary>Betalingshistorie en terugbetalingen per inschrijving</summary><p>Een terugbetaling wordt pas vastgelegd nadat deze werkelijk buiten de app is uitgevoerd. Nieuwe betaallinks maak je hierboven per kind. Betalingen per kind betaal je uitsluitend terug via het betreffende verzoek hierboven, zodat andere kinderen hun betaalstatus behouden.</p>{payments.map((payment) => <div className="incident-row" key={payment.id}><div><strong>{payment.parentName || payment.householdLabel || payment.registrationReference}</strong><small>{payment.reference} · ontvangen {paymentAmount(payment.netCollectedCents)} van {paymentAmount(payment.amountCents)} · {paymentStatusLabels[payment.status] ?? payment.status}</small></div><div className="actions">{!payment.childPaymentMode && payment.batch && ["awaiting_payment", "reported"].includes(payment.batch.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "confirm")}>Bevestig eerder verzoek {paymentAmount(payment.batch.totalAmountCents)}</button>}{!payment.childPaymentMode && payment.batch && payment.batch.status !== "confirmed" && <button className="btn outline" disabled={paymentBusy} onClick={() => void cancelPaymentBatch(payment.batch!, true)}>Eerder betaalverzoek opheffen</button>}{!payment.childPaymentMode && !payment.batch && payment.externalUrl && ["awaiting_payment", "reported"].includes(payment.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "confirm")}>Bevestig eerdere losse betaallink</button>}{!payment.childPaymentMode && !payment.batch && payment.externalUrl && ["awaiting_link", "awaiting_payment", "reported"].includes(payment.status) && <button className="btn outline" disabled={paymentBusy} onClick={() => void clearLegacyPayment(payment)}>Eerdere losse betaallink intrekken</button>}{!payment.childPaymentMode && payment.netCollectedCents > 0 && payment.status !== "refunded" && <button className="btn outline" disabled={paymentBusy} onClick={() => void paymentCommand(payment, "refund")}>Leg terugbetaling vast</button>}</div></div>)}</details>
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
              const visible = registrations.filter((registration) => !query || [registration.groupName, registration.groupCode, registration.parentName, registration.parentEmail, registration.reference, registration.clusterReference, registration.togetherCode, ...registration.children.map((child) => child.name)].some((value) => value?.toLocaleLowerCase("nl").includes(query)));
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
                    <div className="registration-preference-card"><p className="kicker">Voorkeuren</p><span><CalendarClock />Start: {registration.preferredStartAt ? new Date(registration.preferredStartAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "maakt niet uit"}</span><span><CalendarClock />Gewone poorten stoppen: {registration.desiredEndAt ? new Date(registration.desiredEndAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "nog niet gekozen"}</span>{registration.clusterReference && <span>Samenloopnummer: <strong>{registration.clusterReference}</strong></span>}{registration.togetherCode && <span>Samenloopcode: <strong>{registration.togetherCode}</strong></span>}</div>
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
            <div className="row-between"><h2>Open samenloopverzoeken</h2><button type="button" className="btn outline" onClick={() => setSection("together")}>Alle samenlopen beheren</button></div>
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
                        {request.projectedChildren > (dashboard?.event.maxGroupSize ?? request.maxGroupSize)
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
        {section === "praatkamer" && canUsePraatkamer && <PoortkamerOverview eventSlug={eventSlug} praatkamerOnly />}
        {section === "portals" && <PortalReviews eventSlug={eventSlug} />}
        {section === "editorial" && editorialEnabled && <Redactiekamer capabilities={capabilities} />}
        {section === "share" && canManageShares && <ShareStudioAdmin eventSlug={eventSlug} />}
        {section === "statistics" && canViewStatistics && <StatisticsDashboard eventSlug={eventSlug} />}
        {section === "content" && <ContentManagement eventSlug={eventSlug} />}
        {section === "access" && <AdminAccessManagement eventSlug={eventSlug} />}
        {section === "together" && canManageTogether && <TogetherManagement eventSlug={eventSlug} />}
        {section === "poortenboek" && canManageGroups && <PoortenboekAdmin />}
        {section === "groups" && (capabilities.includes("event_admin") || capabilities.includes("groups_manage")) && <GroupCompositionBoard eventSlug={eventSlug} />}
        {section === "planner" && <StartScheduleBoard eventSlug={eventSlug} maxGroupSize={dashboard.event.maxGroupSize} onOpenPortals={() => setSection("portals")} />}
        {["overview","live"].includes(section)&&<EveningFreshness health={eveningHealth} connection={liveConnection} reload={refreshEvening}/>}
        {section==="readiness"&&<EveningReadiness eventSlug={eventSlug}/>}
        {section === "live" && (
          <div className="admin-live-cockpit">
            <section className="panel">
              <div className="row-between"><div><p className="kicker">Actuele, bevestigde toestand</p><h2>Avondcockpit</h2></div><button className="btn outline" onClick={() => void refreshEvening()}><RefreshCw />Vernieuwen</button></div>
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
                  <div><strong>{[run.systemCode || run.groupCode, run.displayName].filter(Boolean).join(" · ")} · {run.currentPortal ?? "geen actieve bestemming"}</strong><small>{runStatusLabels[run.runStatus??run.status]??"Nog niet gestart"} · {run.childCount} kinderen · laatst bevestigd {run.lastConfirmedAt ? new Date(run.lastConfirmedAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "nog niet gestart"}</small><small>Stopgrens {run.effectiveStopAt ? new Date(run.effectiveStopAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "–"} · finale {run.expectedFinaleArrivalAt ? new Date(run.expectedFinaleArrivalAt).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }) : "–"}</small></div>
                  <button className="btn outline" onClick={() => void startMessage("group", run.groupId, [run.systemCode || run.groupCode, run.displayName].filter(Boolean).join(" · "))}><MessageSquare />Bericht sturen</button>
                  {run.runId && run.runVersion !== null && ["live","paused"].includes(run.runStatus??"") && <div className="actions">
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
        <nav className="admin-bottomnav" aria-label="Snelle organisatienavigatie">
          <button className={section === "overview" ? "active" : ""} aria-current={section === "overview" ? "page" : undefined} onClick={() => setSection("overview")}><House /><span>Overzicht</span></button>
          {canUsePraatkamer && <button className={section === "praatkamer" ? "active" : ""} aria-current={section === "praatkamer" ? "page" : undefined} onClick={() => setSection("praatkamer")}><UsersRound /><span>Praatkamer</span></button>}
          {canUseLive && <button className={section === "live" ? "active" : ""} aria-current={section === "live" ? "page" : undefined} onClick={() => { setSection("live"); void loadLive(); }}><LifeBuoy /><span>Live</span></button>}
          {canUseTickets && <button className={section === "tickets" ? "active" : ""} aria-current={section === "tickets" ? "page" : undefined} onClick={() => setSection("tickets")}><MessageSquare /><span>Inbox</span></button>}
          <button ref={bottomNavMoreButtonRef} className="admin-bottomnav-more" aria-expanded={mobileNavOpen} aria-controls="admin-navigation" onClick={() => { navigationOpenerRef.current = bottomNavMoreButtonRef.current; setMobileNavOpen(true); }}><Menu /><span>Meer</span></button>
        </nav>
      </div>
    </div>
  );
}
