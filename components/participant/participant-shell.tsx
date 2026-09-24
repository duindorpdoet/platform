"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Bell,
  Check,
  CheckCircle2,
  ChevronRight,
  Clock3,
  Contact,
  DoorOpen,
  Eye,
  Footprints,
  Home,
  KeyRound,
  LockKeyhole,
  MessageCircle,
  MoonStar,
  Pause,
  RefreshCw,
  Route,
  Settings2,
  ShieldCheck,
  Sparkles,
  TicketCheck,
  UserRound,
  Users,
  X,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { SignOutButton } from "@/components/auth/account-actions";
import { GroupExperience } from "@/components/group/group-experience";
import { GroupTickets } from "@/components/group/group-tickets";
import { PortalDashboard } from "@/components/portal/portal-dashboard";
import { createClient } from "@/lib/supabase/client";

export type ParticipantRoleKey = "walker" | "viewer" | "homeowner";
type ParticipantRole = {
  key: ParticipantRoleKey;
  label: string;
  groupId?: string | null;
  portalId?: string | null;
  accessId?: string | null;
  expiresAt?: string | null;
};
export type ParticipantContext = {
  event: {
    id: string;
    title: string;
    localDate: string;
    phase: string;
    startsAt: string;
    paymentDeadline: string;
    supportEmail: string;
    supportPhone?: string | null;
  };
  roles: ParticipantRole[];
  preferences?: { reducedMotion: boolean; readableMode: boolean };
};

type NavItem = { key: string; label: string; icon: LucideIcon };
const roleSlugs: Record<ParticipantRoleKey, string> = { walker: "meeloper", viewer: "meekijker", homeowner: "huiseigenaar" };
const navigation: Record<ParticipantRoleKey, NavItem[]> = {
  walker: [
    { key: "nu", label: "Nu", icon: MoonStar },
    { key: "route", label: "Route", icon: Route },
    { key: "groep", label: "Groep", icon: Users },
    { key: "nachtpas", label: "Nachtpas", icon: TicketCheck },
    { key: "meer", label: "Meer", icon: Settings2 },
  ],
  viewer: [
    { key: "volgen", label: "Volgen", icon: Eye },
    { key: "groep", label: "Groep", icon: Users },
    { key: "updates", label: "Updates", icon: Bell },
    { key: "meer", label: "Meer", icon: Settings2 },
  ],
  homeowner: [
    { key: "mijn-poort", label: "Mijn poort", icon: DoorOpen },
    { key: "verwacht", label: "Verwacht", icon: Clock3 },
    { key: "updates", label: "Updates", icon: Bell },
    { key: "meer", label: "Meer", icon: Settings2 },
  ],
};

export function ParticipantShell({
  context,
  eventSlug,
  userId,
  role,
  section,
  inviteToken,
}: {
  context: ParticipantContext;
  eventSlug: string;
  userId: string;
  role?: ParticipantRoleKey;
  section?: string;
  inviteToken?: string;
}) {
  const router = useRouter();
  const [inviteNotice, setInviteNotice] = useState(inviteToken ? "Meekijkuitnodiging controleren…" : "");
  const selectedRole = role ? context.roles.find((item) => item.key === role) : undefined;
  const items = selectedRole ? navigation[selectedRole.key] : [];
  const activeSection = items.some((item) => item.key === section) ? section! : items[0]?.key;

  useEffect(() => {
    document.documentElement.dataset.readable = context.preferences?.readableMode ? "true" : "false";
    document.documentElement.dataset.reduceMotion = context.preferences?.reducedMotion ? "true" : "false";
    return () => {
      delete document.documentElement.dataset.readable;
      delete document.documentElement.dataset.reduceMotion;
    };
  }, [context.preferences?.readableMode, context.preferences?.reducedMotion]);

  useEffect(() => {
    if (!inviteToken) return;
    let active = true;
    void (async () => {
      const client = createClient();
      if (!client) return;
      const { error } = await client.schema("api").rpc("group_viewer_invite_accept", { _invite_token: inviteToken });
      if (!active) return;
      if (error) {
        setInviteNotice("Deze meekijkuitnodiging is ongeldig, verlopen, ingetrokken of voor een ander e-mailadres.");
        window.history.replaceState({}, "", "/omgeving");
      } else {
        setInviteNotice("Meekijktoegang geactiveerd. Je ziet alleen beperkte groepsvoortgang en relevante updates.");
        router.replace("/omgeving/meekijker/volgen");
        router.refresh();
      }
    })();
    return () => { active = false; };
  }, [inviteToken, router]);

  if (!selectedRole) {
    return <div className="participant-empty page-transition">
      <div className="participant-empty-art" />
      <section className="participant-card participant-empty-copy">
        <p className="participant-eyebrow">Persoonlijke omgeving</p>
        <h1>{inviteNotice || "Nog geen actieve toegang"}</h1>
        <p>Schrijf je in om mee te lopen, meld een huis of bedrijf aan, of open de persoonlijke uitnodiging van een groepsleider.</p>
        <div className="participant-actions"><Link className="btn" href="/meelopen">Inschrijven</Link><Link className="btn outline" href="/huis-aanmelden">Plek aanmelden</Link></div>
      </section>
    </div>;
  }

  return <div className={`participant-environment role-${selectedRole.key}`}>
    <aside className="participant-sidebar" aria-label="Persoonlijke navigatie">
      <Link className="participant-brand" href="/"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" /></Link>
      <RoleIdentity role={selectedRole} />
      <ParticipantNavigation role={selectedRole.key} activeSection={activeSection} desktop />
      <div className="participant-sidebar-foot"><p>31 oktober 2026</p><span>Duindorp · Den Haag</span><SignOutButton /></div>
    </aside>
    <div className="participant-main">
      <header className="participant-topbar">
        <div><p className="participant-eyebrow">Jouw Halloweenavond</p><strong>{selectedRole.label}</strong></div>
        {context.roles.length > 1 && <RoleSwitcher roles={context.roles} selected={selectedRole.key} />}
      </header>
      {inviteNotice && <div className="participant-notice" role="status">{inviteNotice}</div>}
      <main className="participant-content" id="participant-content">
        {selectedRole.key === "walker" && <WalkerSection context={context} eventSlug={eventSlug} userId={userId} role={selectedRole} section={activeSection} />}
        {selectedRole.key === "viewer" && <ViewerSection context={context} eventSlug={eventSlug} role={selectedRole} section={activeSection} />}
        {selectedRole.key === "homeowner" && <HomeownerSection context={context} eventSlug={eventSlug} role={selectedRole} section={activeSection} />}
      </main>
    </div>
    <ParticipantNavigation role={selectedRole.key} activeSection={activeSection} />
  </div>;
}

function RoleIdentity({ role }: { role: ParticipantRole }) {
  const Icon = role.key === "walker" ? Footprints : role.key === "viewer" ? Eye : Home;
  return <div className="role-identity"><span><Icon /></span><div><small>Je kijkt als</small><strong>{role.label}</strong></div></div>;
}

function RoleSwitcher({ roles, selected }: { roles: ParticipantRole[]; selected: ParticipantRoleKey }) {
  const router = useRouter();
  return <label className="role-switcher"><span>Wissel rol</span><select value={selected} onChange={(event) => router.push(`/omgeving/${roleSlugs[event.target.value as ParticipantRoleKey]}`)}>
    {roles.map((role) => <option key={role.key} value={role.key}>{role.label}</option>)}
  </select></label>;
}

function ParticipantNavigation({ role, activeSection, desktop = false }: { role: ParticipantRoleKey; activeSection?: string; desktop?: boolean }) {
  return <nav className={desktop ? "participant-nav desktop" : "participant-bottomnav"} aria-label={desktop ? "Omgevingsnavigatie" : "Mobiele omgevingsnavigatie"}>
    {navigation[role].map((item) => {
      const Icon = item.icon;
      return <Link key={item.key} className={activeSection === item.key ? "active" : ""} href={`/omgeving/${roleSlugs[role]}/${item.key}`} aria-current={activeSection === item.key ? "page" : undefined}><Icon /><span>{item.label}</span></Link>;
    })}
  </nav>;
}

type RegistrationSnapshot = {
  event?: { changeDeadline?: string | null; changesOpen: boolean };
  registration?: {
    id: string;
    reference: string;
    status: string;
    priceCents: number;
    togetherCode: string;
    version: number;
    children: Array<{ id: string; firstName: string; ageAtEvent?: number | null; status: string; unitPriceCents: number }>;
    payment?: { status: string; amountCents: number; externalUrl?: string | null; version: number } | null;
  } | null;
};
type GroupSnapshot = {
  group: {
    id: string;
    code: string;
    status: string;
    version: number;
    effectiveOrdinaryStopAt?: string | null;
    expectedFinaleArrivalAt?: string | null;
    start?: { name: string; locationName: string; address?: string; startsAt: string } | null;
  };
  access: { leader: boolean; support: boolean };
  run: null | {
    id: string;
    status: string;
    version: number;
    elapsedSeconds?: number;
    waitingInstruction?: boolean;
    remainingStopCount: number | null;
    currentStop: null | { id: string; sequence: number; kind?: "ordinary" | "finale"; scanAccepted: boolean; portal: { name: string; world: string; address: string; postalCode: string; intensity: number; operationStatus: string } };
    participants: Array<{ id: string; firstName: string; attendance: string; isOwnChild: boolean; status?: string | null }>;
    history: Array<{ sequence: number; outcome: string; completedAt: string; portalName: string; world: string }>;
  };
};

const paymentLabels: Record<string, string> = {
  awaiting_link: "Wacht op Tikkie",
  awaiting_payment: "Wacht op betaling",
  reported: "Betaling wordt gecontroleerd",
  confirmed: "Betaald",
  partial: "Deels betaald",
  refund_due: "Terugbetaling volgt",
  refunded: "Terugbetaald",
  waived: "Geen betaling nodig",
};

function WalkerSection({ context, eventSlug, userId, role, section }: { context: ParticipantContext; eventSlug: string; userId: string; role: ParticipantRole; section?: string }) {
  const [registration, setRegistration] = useState<RegistrationSnapshot | null>(null);
  const [group, setGroup] = useState<GroupSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const [registrationResult, groupResult] = await Promise.all([
      client.schema("api").rpc("registration_snapshot", { _event_slug: eventSlug }),
      role.groupId ? client.schema("api").rpc("group_snapshot", { _group_id: role.groupId }) : Promise.resolve({ data: null, error: null }),
    ]);
    if (!registrationResult.error) setRegistration(registrationResult.data as RegistrationSnapshot);
    if (!groupResult.error && groupResult.data) setGroup(groupResult.data as GroupSnapshot);
    setLoading(false);
  }, [eventSlug, role.groupId]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  if (section === "route" && role.groupId) return <ParticipantPageFrame eyebrow="De route ontvouwt zich stap voor stap" title="Route door Duindorp" compact><GroupExperience groupId={role.groupId} userId={userId} /></ParticipantPageFrame>;
  if (loading) return <ParticipantLoading />;
  if (section === "groep") return <WalkerGroup group={group} registration={registration} groupId={role.groupId ?? undefined} />;
  if (section === "nachtpas") return <NightPass context={context} snapshot={registration} group={group} reload={load} />;
  if (section === "meer" || section === "updates") return <MorePage context={context} eventSlug={eventSlug} role="walker" groupId={role.groupId ?? undefined} />;
  return <WalkerNow context={context} registration={registration} group={group} />;
}

function WalkerNow({ context, registration, group }: { context: ParticipantContext; registration: RegistrationSnapshot | null; group: GroupSnapshot | null }) {
  const run = group?.run;
  const payment = registration?.registration?.payment;
  if (run?.status === "completed") return <ParticipantPageFrame eyebrow="Jullie nacht in Duindorp" title="Wat een avond.">
    <section className="participant-hero-card recap"><div className="hero-glow violet" /><CheckCircle2 /><div><p className="participant-eyebrow">Route voltooid</p><h2>{run.history.length} poorten, één verhaal</h2><p>Jullie hebben samen {run.history.filter((item) => item.outcome === "visited" || item.outcome === "mixed").length} zegels verzameld. De herinneringen blijven; de adressen verdwijnen weer uit beeld.</p></div></section>
    <StampRail history={run.history} />
  </ParticipantPageFrame>;

  if (run && ["live", "paused"].includes(run.status)) {
    const stop = run.currentStop;
    const isFinale = stop?.kind === "finale";
    return <ParticipantPageFrame eyebrow="De tocht is begonnen" title={run.status === "paused" ? "Even stilstaan." : "Dit is jullie volgende poort."}>
      {run.status === "paused" && <div className="participant-alert"><Pause />De groepsleider heeft de route gepauzeerd. Wacht samen op de volgende instructie.</div>}
      {stop && <section className="participant-hero-card live"><img src="/images/pluvierstraat.webp" alt="Nachtelijk verlichte Duindorpse poort" /><div className="participant-hero-overlay"><p className="participant-eyebrow">{isFinale ? "Laatste poort · eindshow" : `Vrijgegeven · ${stop.portal.world}`}</p><h2>{stop.portal.name}</h2><p>{stop.portal.address}, {stop.portal.postalCode}</p><small>{Math.floor((run.elapsedSeconds ?? 0) / 60)} minuten onderweg · {isFinale ? "hierna is de tocht afgerond" : "de volgende poort volgt na bevestiging"}</small><Link className="btn participant-primary-action" href="/omgeving/meeloper/route">{group?.access.leader ? stop.scanAccepted ? isFinale ? "Eindshow afronden" : "Bezoek afronden" : "Poort bevestigen" : "Bekijk route-instructie"}<ChevronRight /></Link></div></section>}
      {!stop && <section className="participant-card calm-card"><Clock3 /><div><h3>Wacht op de volgende veilige opdracht</h3><p>De server beoordeelt opnieuw welke poort en welk aankomstvenster beschikbaar zijn. Er wordt geen adres voorspeld.</p></div></section>}
      <section className="participant-card"><div className="summary-row"><span>Geen nieuwe gewone poorten vanaf</span><strong>{group?.group.effectiveOrdinaryStopAt ? formatTime(group.group.effectiveOrdinaryStopAt) : "Wordt berekend"}</strong></div><div className="summary-row"><span>Verwachte aankomst laatste poort</span><strong>{group?.group.expectedFinaleArrivalAt ? formatTime(group.group.expectedFinaleArrivalAt) : "Wordt berekend"}</strong></div></section>
      <section className="participant-card calm-card"><ShieldCheck /><div><h3>Rustig en samen</h3><p>Blijf als groep bij elkaar. Alleen de vrijgegeven poort is zichtbaar; een volgend adres verschijnt pas na afronding.</p></div></section>
    </ParticipantPageFrame>;
  }

  return <ParticipantPageFrame eyebrow="Voorpret begint hier" title="Klaar voor de nacht?">
    <section className="participant-hero-card countdown-card"><div className="hero-glow amber" /><div><p className="participant-eyebrow">Tot 31 oktober</p><Countdown target={context.event.startsAt} /><p>Jullie tijdslot en startplek verschijnen zodra de groepsindeling definitief is.</p></div></section>
    <div className="participant-stat-grid">
      <StatusCard icon={payment?.status === "confirmed" || payment?.status === "waived" ? CheckCircle2 : Clock3} label="Betaling" value={payment ? paymentLabels[payment.status] ?? payment.status : "Wordt voorbereid"} good={payment?.status === "confirmed" || payment?.status === "waived"} />
      <StatusCard icon={Users} label="Groep" value={group ? `Groep ${group.group.code}` : "Indeling volgt"} />
      <StatusCard icon={Clock3} label="Vertrek" value={group?.group.start ? formatTime(group.group.start.startsAt) : "Tijdslot volgt"} />
    </div>
    <PreparationList paid={payment?.status === "confirmed" || payment?.status === "waived"} grouped={Boolean(group)} />
  </ParticipantPageFrame>;
}

function WalkerGroup({ group, registration, groupId }: { group: GroupSnapshot | null; registration: RegistrationSnapshot | null; groupId?: string }) {
  if (!group) return <ParticipantPageFrame eyebrow="Groepsindeling" title="Jullie groep komt eraan"><section className="participant-card"><Users /><h2>We delen zorgvuldig in</h2><p>Zodra starttijd en groep zijn gepubliceerd, verschijnt hier alleen de informatie die bij jouw inschrijving hoort.</p></section></ParticipantPageFrame>;
  const participants = group.run?.participants ?? [];
  const visibleChildren = participants.length ? participants : (registration?.registration?.children ?? []).map((child) => ({ id: child.id, firstName: child.firstName, attendance: "aangemeld", isOwnChild: true, status: null }));
  return <ParticipantPageFrame eyebrow={`Groep ${group.group.code}`} title={group.access.leader ? "Jij houdt het overzicht." : "Samen op pad."}>
    <section className="participant-card group-summary"><div><p className="participant-eyebrow">Startmoment</p><h2>{group.group.start ? formatDateTime(group.group.start.startsAt) : "Wordt binnenkort gedeeld"}</h2><p>{group.group.start ? `${group.group.start.locationName}${group.group.start.address ? ` · ${group.group.start.address}` : ""}` : "De startplek blijft verborgen tot publicatie."}</p></div><span className="group-code">{group.group.code}</span></section>
    <section className="participant-card"><div className="section-title"><div><p className="participant-eyebrow">Gekoppelde deelnemers</p><h2>{group.access.leader ? "Aanwezigheid en veiligheid" : "Jouw kinderen"}</h2></div><ShieldCheck /></div>
      {visibleChildren.length === 0 && <p>De deelnemerslijst verschijnt zodra de route start.</p>}
      <div className="participant-list">{visibleChildren.map((child) => <div key={child.id}><span className="participant-avatar">{child.firstName.slice(0, 1)}</span><span><strong>{child.firstName}</strong><small>{child.attendance === "present" ? "Aanwezig" : child.attendance === "absent" ? "Afwezig" : "Aangemeld"}</small></span>{child.status && <em>{child.status === "visited" ? "Bezocht" : child.status === "skipped" ? "Overgeslagen" : "Wacht"}</em>}</div>)}</div>
      {group.access.leader ? <div className="participant-alert subtle"><ShieldCheck />Aanwezigheid, scans, pauzeren en veiligheidsacties staan bij Route. Andere volwassenen zien alleen hun eigen gekoppelde kinderen.</div> : <p className="privacy-note"><LockKeyhole /> Om kinderen te beschermen zie je geen namen of gegevens uit andere huishoudens.</p>}
    </section>
    {group.access.leader && groupId && <><ViewerAccessManager groupId={groupId} /><GroupTickets groupId={groupId} /></>}
  </ParticipantPageFrame>;
}

function NightPass({ context, snapshot, group, reload }: { context: ParticipantContext; snapshot: RegistrationSnapshot | null; group: GroupSnapshot | null; reload: () => Promise<void> }) {
  const registration = snapshot?.registration;
  const paid = ["confirmed", "waived"].includes(registration?.payment?.status ?? "");
  async function reportPayment() {
    const client = createClient();
    if (!client || !registration?.payment) return;
    await client.schema("api").rpc("registration_report_payment", { _registration_id: registration.id, _expected_version: registration.payment.version });
    await reload();
  }
  if (!registration) return <ParticipantPageFrame eyebrow="Nachtpas" title="Nog geen inschrijving"><section className="participant-card"><p>Na je definitieve inschrijving verschijnt hier de Nachtpas voor je eigen kinderen.</p><Link className="btn" href="/meelopen">Schrijf je in</Link></section></ParticipantPageFrame>;
  return <ParticipantPageFrame eyebrow="Alles voor deelname" title="Jullie Nachtpas">
    <section className={`night-pass ${paid ? "active" : "locked"}`}><div className="night-pass-top"><span><MoonStar />Duindorp 2026</span><strong>{paid ? "TOEGANG ACTIEF" : "NOG VERGRENDELD"}</strong></div><h2>{registration.reference}</h2><div className="night-pass-grid"><span>Kinderen<strong>{registration.children.filter((child) => child.status === "active").map((child) => child.firstName).join(", ")}</strong></span><span>Tijdslot<strong>{group?.group.start ? formatTime(group.group.start.startsAt) : "Volgt"}</strong></span><span>Groep<strong>{group ? group.group.code : "Volgt"}</strong></span><span>Betaling<strong>{registration.payment ? paymentLabels[registration.payment.status] ?? registration.payment.status : "Wordt voorbereid"}</strong></span></div>{paid ? <div className="night-pass-valid"><ShieldCheck />Toegang bevestigd. Neem deze pagina en de bevestigingsmail mee.</div> : <div className="night-pass-warning"><LockKeyhole /><span><strong>Betaal vóór <time dateTime={context.event.paymentDeadline}>30 oktober</time> om mee te kunnen doen.</strong>Het toegangsbewijs wordt pas zichtbaar nadat de organisatie de betaling heeft bevestigd.</span></div>}</section>
    {!paid && registration.payment?.externalUrl && <a className="btn participant-primary-action" href={registration.payment.externalUrl} target="_blank" rel="noreferrer noopener">Open de Tikkie-link<ChevronRight /></a>}
    {!paid && registration.payment && ["awaiting_link", "awaiting_payment"].includes(registration.payment.status) && <button className="btn outline" onClick={() => void reportPayment()}>Ik heb betaald</button>}
    <section className="participant-card"><p className="participant-eyebrow">Per eigen kind</p><h2>Deelnamestatus</h2><div className="child-pass-list">{registration.children.map((child) => <div key={child.id}><span className="participant-avatar">{child.firstName.slice(0, 1)}</span><span><strong>{child.firstName}</strong><small>{child.status === "active" ? `Aangemeld · € ${(child.unitPriceCents / 100).toFixed(2).replace(".", ",")}` : "Afgezegd"}</small></span><em className={paid && child.status === "active" ? "confirmed" : ""}>{child.status !== "active" ? "Niet actief" : paid ? "Toegang actief" : "Wacht op betaling"}</em></div>)}</div></section>
    <section className="participant-card practical"><p className="participant-eyebrow">Praktisch</p><h2>Zo gebruik je de Nachtpas</h2><ul><li>Meld je met de groepsleider bij de gepubliceerde startplek.</li><li>Kinderen blijven de hele avond bij hun eigen groep en verantwoordelijke volwassene.</li><li>We tonen geen QR-code: er is geen aparte QR-controle nodig naast de bevestigde inschrijving.</li></ul></section>
  </ParticipantPageFrame>;
}

type ViewerSnapshot = { group: { code: string; status: string; start?: { name: string; startsAt: string } | null }; progress: { status: string; completed: number; lastUpdatedAt: string }; history: Array<{ sequence: number; world: string; outcome: string; completedAt: string }> };

function ViewerSection({ context, eventSlug, role, section }: { context: ParticipantContext; eventSlug: string; role: ParticipantRole; section?: string }) {
  const [snapshot, setSnapshot] = useState<ViewerSnapshot | null>(null);
  useEffect(() => {
    const timer = window.setTimeout(async () => {
      const client = createClient(); if (!client || !role.groupId) return;
      const { data } = await client.schema("api").rpc("group_viewer_snapshot", { _group_id: role.groupId });
      if (data) setSnapshot(data as ViewerSnapshot);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [role.groupId]);
  if (section === "updates") return <UpdatesPanel eventSlug={eventSlug} role="viewer" />;
  if (section === "meer") return <MorePage context={context} eventSlug={eventSlug} role="viewer" accessId={role.accessId ?? undefined} />;
  if (!snapshot) return <ParticipantLoading />;
  if (section === "groep") return <ParticipantPageFrame eyebrow="Bewust beperkt" title={`Groep ${snapshot.group.code}`}><section className="participant-card"><ShieldCheck /><h2>Meekijken zonder mee te lopen</h2><p>Je ziet de status, het geplande startmoment en de afgeronde wereldstappen. Kindernamen, live GPS, toekomstige adressen en andere groepen blijven altijd verborgen.</p><div className="summary-row"><span>Startmoment</span><strong>{snapshot.group.start ? formatDateTime(snapshot.group.start.startsAt) : "Volgt"}</strong></div><div className="summary-row"><span>Toegang</span><strong>{role.expiresAt ? `tot ${formatDateTime(role.expiresAt)}` : "tot intrekking"}</strong></div></section></ParticipantPageFrame>;
  return <ParticipantPageFrame eyebrow="Alleen wat je nodig hebt" title={snapshot.progress.status === "completed" ? "De groep is veilig klaar." : snapshot.progress.status === "live" ? "Ze zijn onderweg." : "De avond moet nog beginnen."}>
    <section className="participant-hero-card viewer"><div className="hero-glow cyan" /><Eye /><div><p className="participant-eyebrow">Groep {snapshot.group.code}</p><h2>{snapshot.progress.completed} bevestigde {snapshot.progress.completed === 1 ? "poort" : "poorten"}</h2><p>Het resterende aantal ligt niet vooraf vast.</p><p>Laatst veilig bijgewerkt: {formatDateTime(snapshot.progress.lastUpdatedAt)}</p></div></section>
    <StampRail history={snapshot.history.map((item) => ({ ...item, portalName: item.world }))} hideNames />
    <div className="participant-alert subtle"><LockKeyhole />Dit is bewust geen live locatie. De voortgang ververst na bevestigde poortacties.</div>
  </ParticipantPageFrame>;
}

type PortalSnapshot = { portal: null | { id: string; name: string; operationStatus: "scheduled" | "open" | "paused" | "closed" } } | null;
type ArrivalsSnapshot = { expectedTotal: number; arrivals: Array<{ groupCode: string; plannedArrivalAt: string; plannedDepartureAt: string; expectedChildren: number; state: string }> };

function HomeownerSection({ context, eventSlug, role, section }: { context: ParticipantContext; eventSlug: string; role: ParticipantRole; section?: string }) {
  const [arrivals, setArrivals] = useState<ArrivalsSnapshot | null>(null);
  const [portal, setPortal] = useState<PortalSnapshot>(null);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const portalResult = await client.schema("api").rpc("portal_snapshot", { _event_slug: eventSlug });
    const nextPortal = portalResult.data as PortalSnapshot;
    setPortal(nextPortal);
    const portalId = nextPortal?.portal?.id ?? role.portalId;
    if (portalId) {
      const result = await client.schema("api").rpc("portal_arrivals_snapshot", { _portal_id: portalId });
      if (!result.error) setArrivals(result.data as ArrivalsSnapshot);
    }
  }, [eventSlug, role.portalId]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  if (section === "updates") return <UpdatesPanel eventSlug={eventSlug} role="homeowner" />;
  if (section === "meer") return <MorePage context={context} eventSlug={eventSlug} role="homeowner" />;
  if (section === "verwacht") return <ArrivalsPage arrivals={arrivals} />;
  return <ParticipantPageFrame eyebrow="Avondcockpit" title={portal?.portal ? `${portal.portal.name} is ${portal.portal.operationStatus === "open" ? "open" : portal.portal.operationStatus === "paused" ? "gepauzeerd" : portal.portal.operationStatus === "closed" ? "gesloten" : "ingepland"}.` : "Mijn poort"}>
    <div className="cockpit-metrics"><StatusCard icon={Users} label="Verwacht totaal" value={arrivals ? `${arrivals.expectedTotal} kinderen` : "Wordt berekend"} /><StatusCard icon={Clock3} label="Volgend venster" value={arrivals?.arrivals.find((item) => item.state !== "completed") ? `${formatTime(arrivals.arrivals.find((item) => item.state !== "completed")!.plannedArrivalAt)}–${formatTime(arrivals.arrivals.find((item) => item.state !== "completed")!.plannedDepartureAt)}` : "Geen open venster"} /></div>
    <div className="planned-not-live"><Clock3 /><span><strong>Dit is een geplande aankomst, geen live ETA.</strong>Groepen kunnen eerder of later lopen. Gebruik Pauze zodra ontvangst tijdelijk niet veilig of mogelijk is.</span></div>
    <PortalDashboard eventSlug={eventSlug} />
    <DirectContact context={context} />
  </ParticipantPageFrame>;
}

function ArrivalsPage({ arrivals }: { arrivals: ArrivalsSnapshot | null }) {
  return <ParticipantPageFrame eyebrow="Geplande routevensters" title="Wie kun je verwachten?">
    <section className="participant-card arrivals-card"><div className="section-title"><div><p className="participant-eyebrow">Avondplanning</p><h2>{arrivals?.expectedTotal ?? 0} kinderen verdeeld over {arrivals?.arrivals.length ?? 0} groepen</h2></div><Clock3 /></div>
      <p>De tijden hieronder zijn planning, geen live locatie of aankomstgarantie.</p>
      <div className="arrival-timeline">{arrivals?.arrivals.map((arrival) => <article key={`${arrival.groupCode}-${arrival.plannedArrivalAt}`} className={arrival.state}><time>{formatTime(arrival.plannedArrivalAt)}</time><span /><div><strong>Groep {arrival.groupCode}</strong><p>{arrival.expectedChildren} kinderen · venster tot {formatTime(arrival.plannedDepartureAt)}</p><small>{arrival.state === "completed" ? "Bezoek afgerond" : arrival.state === "active" ? "Vrijgegeven in groepsroute" : "Gepland"}</small></div></article>)}{!arrivals?.arrivals.length && <p>Nog geen gepubliceerde routevensters.</p>}</div>
    </section>
  </ParticipantPageFrame>;
}

type UpdateItem = { id: string; title: string; body: string; priority: string; publishedAt: string; readAt?: string | null };

function UpdatesPanel({ eventSlug, role, embedded = false }: { eventSlug: string; role: ParticipantRoleKey; embedded?: boolean }) {
  const [updates, setUpdates] = useState<UpdateItem[] | null>(null);
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data } = await client.schema("api").rpc("participant_updates_snapshot", { _event_slug: eventSlug, _role: role });
    if (data) setUpdates(data as UpdateItem[]);
  }, [eventSlug, role]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function markRead(id: string) {
    const client = createClient(); if (!client) return;
    await client.schema("api").rpc("participant_update_mark_read", { _update_id: id }); await load();
  }
  const list = <section className="update-list">{updates?.map((update) => <article key={update.id} className={`participant-card update-item ${update.readAt ? "read" : "unread"} ${update.priority}`}><div className="update-icon">{update.priority === "urgent" ? <ShieldCheck /> : <Bell />}</div><div><p className="participant-eyebrow">{formatDateTime(update.publishedAt)} · {update.priority === "urgent" ? "Belangrijk" : "Update"}</p><h2>{update.title}</h2><p>{update.body}</p>{!update.readAt && <button className="text-link" onClick={() => void markRead(update.id)}>Markeer als gelezen <Check /></button>}</div></article>)}{updates && updates.length === 0 && <section className="participant-card empty-update"><CheckCircle2 /><h2>Je bent helemaal bij</h2><p>Nieuwe berichten die bij jouw rol horen verschijnen hier.</p></section>}{!updates && <ParticipantLoading />}</section>;
  if (embedded) return <section className="embedded-updates"><div className="section-title"><div><p className="participant-eyebrow">Van de organisatie</p><h2>Updates</h2></div><Bell /></div>{list}</section>;
  return <ParticipantPageFrame eyebrow="Van de organisatie" title="Updates">{list}</ParticipantPageFrame>;
}

function MorePage({ context, eventSlug, role, groupId, accessId }: { context: ParticipantContext; eventSlug: string; role: ParticipantRoleKey; groupId?: string; accessId?: string }) {
  return <ParticipantPageFrame eyebrow="Instellingen en bereikbaarheid" title="Meer">
    {role === "walker" && <UpdatesPanel eventSlug={eventSlug} role="walker" embedded />}
    {role === "walker" && groupId && <section className="participant-card contact-shortcut"><MessageCircle /><div><h2>Hulp & contact</h2><p>De groepsleider kan in het groepsscherm een privégesprek met de organisatie starten. Beide kanten ontvangen een e-mail bij een nieuw bericht.</p><Link className="text-link" href="/omgeving/meeloper/groep">Naar Hulp & contact <ChevronRight /></Link></div></section>}
    <ProfilePanel eventSlug={eventSlug} />
    {role === "viewer" && accessId && <ViewerSelfRevoke accessId={accessId} />}
    <DirectContact context={context} />
  </ParticipantPageFrame>;
}

type ProfileSnapshot = { displayName?: string | null; email: string; roles: ParticipantRole[]; preferences: { emailUpdates: boolean; reducedMotion: boolean; readableMode: boolean; optionalUpdatesConsent: boolean; version: number } };

function ProfilePanel({ eventSlug }: { eventSlug: string }) {
  const [profile, setProfile] = useState<ProfileSnapshot | null>(null);
  const [name, setName] = useState("");
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => {
    const client = createClient(); if (!client) return;
    const { data } = await client.schema("api").rpc("participant_profile_snapshot", { _event_slug: eventSlug });
    if (data) { const next = data as ProfileSnapshot; setProfile(next); setName(next.displayName ?? ""); document.documentElement.dataset.readable = next.preferences.readableMode ? "true" : "false"; document.documentElement.dataset.reduceMotion = next.preferences.reducedMotion ? "true" : "false"; }
  }, [eventSlug]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function save(patch?: Partial<ProfileSnapshot["preferences"]>) {
    if (!profile) return;
    const next = { ...profile.preferences, ...patch };
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("participant_profile_update", { _event_slug: eventSlug, _display_name: name, _email_updates: next.emailUpdates, _reduced_motion: next.reducedMotion, _readable_mode: next.readableMode, _optional_updates_consent: next.optionalUpdatesConsent, _expected_version: profile.preferences.version });
    setNotice(error ? "Je instellingen waren intussen gewijzigd. De actuele versie wordt opgehaald." : "Instellingen opgeslagen."); await load();
  }
  if (!profile) return <ParticipantLoading />;
  return <section className="participant-card profile-card"><div className="section-title"><div><p className="participant-eyebrow">Profiel en toestemmingen</p><h2>Jouw voorkeuren</h2></div><UserRound /></div><label className="participant-field"><span>Weergavenaam</span><input value={name} maxLength={120} onChange={(event) => setName(event.target.value)} /></label><div className="access-email"><KeyRound /><span><small>Inloggen met</small><strong>{profile.email}</strong></span></div><div className="preference-list"><Preference label="E-mail bij relevante updates" checked={profile.preferences.emailUpdates} onChange={(value) => void save({ emailUpdates: value })} /><Preference label="Optionele niet-operationele updates" checked={profile.preferences.optionalUpdatesConsent} onChange={(value) => void save({ optionalUpdatesConsent: value })} /><Preference label="Verminder beweging" checked={profile.preferences.reducedMotion} onChange={(value) => void save({ reducedMotion: value })} /><Preference label="Leesweergave voor slechte verbinding" checked={profile.preferences.readableMode} onChange={(value) => void save({ readableMode: value })} /></div><button className="btn outline" onClick={() => void save()}>Naam opslaan</button>{notice && <p className="form-notice" role="status">{notice}</p>}<div className="role-access-list"><p className="participant-eyebrow">Actieve toegangen</p>{profile.roles.map((item) => <span key={item.key}><ShieldCheck />{item.label}{item.expiresAt ? <small>tot {formatDateTime(item.expiresAt)}</small> : null}</span>)}</div></section>;
}

function Preference({ label, checked, onChange }: { label: string; checked: boolean; onChange: (value: boolean) => void }) {
  return <label><span>{label}</span><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} /></label>;
}

function ViewerSelfRevoke({ accessId }: { accessId: string }) {
  const router = useRouter();
  const [notice, setNotice] = useState("");
  async function revoke() {
    if (!window.confirm("Meekijktoegang intrekken? Je kunt de groep daarna niet meer volgen zonder een nieuwe uitnodiging.")) return;
    const client = createClient(); if (!client) return;
    const { error } = await client.schema("api").rpc("group_viewer_access_revoke", { _access_id: accessId, _reason: "Door meekijker zelf ingetrokken" });
    if (error) setNotice("Intrekken is niet gelukt."); else { router.push("/omgeving"); router.refresh(); }
  }
  return <section className="participant-card danger-zone"><p className="participant-eyebrow">Toegang</p><h2>Meekijken stoppen</h2><p>Je toegang is persoonlijk, alleen-lezen en op ieder moment intrekbaar.</p><button className="btn outline" onClick={() => void revoke()}><X />Toegang intrekken</button>{notice && <p>{notice}</p>}</section>;
}

type ViewerAccessSnapshot = { pending: Array<{ id: string; email: string; inviteExpiresAt: string; accessExpiresAt?: string | null }>; active: Array<{ id: string; email: string; expiresAt?: string | null; createdAt: string }> };

function ViewerAccessManager({ groupId }: { groupId: string }) {
  const [snapshot, setSnapshot] = useState<ViewerAccessSnapshot | null>(null);
  const [email, setEmail] = useState("");
  const [duration, setDuration] = useState("event");
  const [notice, setNotice] = useState("");
  const load = useCallback(async () => { const client = createClient(); if (!client) return; const { data } = await client.schema("api").rpc("group_viewer_access_snapshot", { _group_id: groupId }); if (data) setSnapshot(data as ViewerAccessSnapshot); }, [groupId]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  async function invite() {
    const client = createClient(); if (!client) return;
    const expiry = duration === "event" ? null : new Date(Date.now() + Number(duration) * 60 * 60 * 1000).toISOString();
    const { error } = await client.schema("api").rpc("group_viewer_invite_create", { _group_id: groupId, _recipient_email: email, _access_expires_at: expiry });
    setNotice(error ? "Uitnodigen is niet gelukt. Controleer het e-mailadres en probeer opnieuw." : "Persoonlijke meekijkuitnodiging per e-mail klaargezet."); if (!error) setEmail(""); await load();
  }
  async function revoke(kind: "access" | "invite", id: string) {
    const client = createClient(); if (!client) return;
    const functionName = kind === "access" ? "group_viewer_access_revoke" : "group_viewer_invite_revoke";
    const args = kind === "access" ? { _access_id: id, _reason: "Door groepsleider ingetrokken" } : { _invite_id: id, _reason: "Door groepsleider ingetrokken" };
    await client.schema("api").rpc(functionName, args); await load();
  }
  return <section className="participant-card viewer-manager"><div className="section-title"><div><p className="participant-eyebrow">Read-only meekijken</p><h2>Nodig een meekijker uit</h2></div><Eye /></div><p>De link is persoonlijk en 48 uur geldig. De toegang toont nooit kindernamen, GPS of toekomstige adressen.</p><div className="invite-grid"><label className="participant-field"><span>E-mailadres</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="naam@voorbeeld.nl" /></label><label className="participant-field"><span>Toegang geldig</span><select value={duration} onChange={(event) => setDuration(event.target.value)}><option value="event">Tot intrekking</option><option value="24">24 uur</option><option value="72">3 dagen</option><option value="168">7 dagen</option></select></label><button className="btn" disabled={!email.includes("@") || !email.includes(".")} onClick={() => void invite()}>Uitnodigen</button></div>{notice && <p className="form-notice" role="status">{notice}</p>}<div className="access-rows">{snapshot?.active.map((access) => <div key={access.id}><span><strong>{access.email}</strong><small>{access.expiresAt ? `tot ${formatDateTime(access.expiresAt)}` : "tot intrekking"}</small></span><button className="text-link" onClick={() => void revoke("access", access.id)}>Intrekken</button></div>)}{snapshot?.pending.map((invite) => <div key={invite.id}><span><strong>{invite.email}</strong><small>uitnodiging wacht op acceptatie</small></span><button className="text-link" onClick={() => void revoke("invite", invite.id)}>Intrekken</button></div>)}</div></section>;
}

function DirectContact({ context }: { context: ParticipantContext }) {
  return <section className="participant-card contact-card"><Contact /><div><p className="participant-eyebrow">Direct contact</p><h2>Organisatie</h2><p>Geen spoed? Mail de organisatie. Bij direct gevaar bel je 112.</p><div className="participant-actions"><a className="btn outline" href={`mailto:${context.event.supportEmail}`}>{context.event.supportEmail}</a>{context.event.supportPhone && <a className="btn outline" href={`tel:${context.event.supportPhone.replace(/\s/g, "")}`}>{context.event.supportPhone}</a>}</div></div></section>;
}

function ParticipantPageFrame({ eyebrow, title, compact = false, children }: { eyebrow: string; title: string; compact?: boolean; children: React.ReactNode }) {
  return <div className={`participant-page page-transition ${compact ? "compact" : ""}`}><header className="participant-page-head"><p className="participant-eyebrow">{eyebrow}</p><h1>{title}</h1></header>{children}</div>;
}

function ParticipantLoading() { return <div className="participant-loading"><RefreshCw className="spin" /><span>Je omgeving wordt veilig geladen…</span></div>; }

function StatusCard({ icon: Icon, label, value, good = false }: { icon: LucideIcon; label: string; value: string; good?: boolean }) {
  return <section className={`participant-card status-card ${good ? "good" : ""}`}><span><Icon /></span><div><small>{label}</small><strong>{value}</strong></div></section>;
}

function Countdown({ target }: { target: string }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const timer = window.setInterval(() => setNow(Date.now()), 60000); return () => window.clearInterval(timer); }, []);
  const parts = useMemo(() => { const remaining = Math.max(0, new Date(target).getTime() - now); const days = Math.floor(remaining / 86400000); const hours = Math.floor((remaining % 86400000) / 3600000); const minutes = Math.floor((remaining % 3600000) / 60000); return { days, hours, minutes }; }, [target, now]);
  return <div className="countdown-grid"><span><strong>{parts.days}</strong>dagen</span><span><strong>{parts.hours}</strong>uur</span><span><strong>{parts.minutes}</strong>min</span></div>;
}

function PreparationList({ paid, grouped }: { paid: boolean; grouped: boolean }) {
  const [personal, setPersonal] = useState<Record<string, boolean>>({ reflective: false, battery: false, clothing: false });
  const rows = [{ key: "paid", label: "Betaling bevestigd", done: paid, fixed: true }, { key: "grouped", label: "Groepsindeling ontvangen", done: grouped, fixed: true }, { key: "reflective", label: "Iets zichtbaars of reflecterends mee", done: personal.reflective }, { key: "battery", label: "Telefoon opgeladen", done: personal.battery }, { key: "clothing", label: "Warme, droge kleding klaar", done: personal.clothing }];
  return <section className="participant-card prep-list"><div className="section-title"><div><p className="participant-eyebrow">Voorbereidingslijst</p><h2>In vijf stappen klaar</h2></div><Sparkles /></div>{rows.map((row) => <button key={row.key} disabled={row.fixed} className={row.done ? "done" : ""} onClick={() => setPersonal((current) => ({ ...current, [row.key]: !current[row.key] }))}><span>{row.done ? <Check /> : null}</span><strong>{row.label}</strong>{row.fixed && <small>automatisch</small>}</button>)}</section>;
}

function StampRail({ history, hideNames = false }: { history: Array<{ sequence: number; outcome: string; completedAt: string; portalName: string; world: string }>; hideNames?: boolean }) {
  if (!history.length) return <section className="participant-card"><p>Nog geen afgeronde wereldstappen.</p></section>;
  return <section className="stamp-rail" aria-label="Verzamelde wereldstempels">{history.map((item, index) => <article key={`${item.sequence}-${item.completedAt}`} style={{ "--stamp-index": index } as React.CSSProperties}><span>{item.outcome === "system_skipped" || item.outcome === "all_skipped" ? <X /> : <Check />}</span><div><small>{formatTime(item.completedAt)}</small><h3>{item.world}</h3><p>{hideNames ? `Wereldstap ${item.sequence}` : item.portalName}</p></div></article>)}</section>;
}

function formatTime(value: string) { return new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" }); }
function formatDateTime(value: string) { return new Date(value).toLocaleString("nl-NL", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }); }
