"use client";

import { useSnapshotRefresh } from "@/lib/realtime/use-snapshot-refresh";
import {useEventDetails} from "@/components/redesign/event-details";
import Link from "next/link";
import type { ParticipantPayment } from "@/components/payments/payment-details";
import { ChildPaymentRows, childPaymentFor, childPaymentState, type PaymentChild } from "@/components/payments/child-payment-rows";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Bell,
  ArrowUpRight,
  CalendarDays,
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
import { ParticipantTogether } from "@/components/registration/participant-together";
import {EarlyDeparture} from "@/components/redesign/early-departure";
import {FamilyPortalThanks} from "@/components/redesign/portal-thanks";
import { GroupExperience } from "@/components/group/group-experience";
import { GroupJourneyPreference } from "@/components/group/group-journey-preference";
import { GroupIdentity } from "@/components/group/group-identity";
import { PortalNews } from "@/components/editorial/portal-news";
import { PortalDashboard } from "@/components/portal/portal-dashboard";
import { SupportWidget } from "@/components/support/support-widget";
import { PwaInstallInvitation, PushNotificationSettings } from "@/components/pwa/pwa-experience";
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
    { key: "nu", label: "Overzicht", icon: MoonStar },
    { key: "route", label: "Route", icon: Route },
    { key: "groep", label: "Mijn groep", icon: Users },
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
    { key: "mijn-poort", label: "Poortkamer", icon: DoorOpen },
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
  const event=useEventDetails();
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
      <PwaInstallInvitation userId={userId} />
      <div className="participant-empty-art" />
      <section className="participant-card participant-empty-copy">
        <p className="participant-eyebrow">Persoonlijke omgeving</p>
        <h1>{inviteNotice || "Nog geen actieve toegang"}</h1>
        <p>Schrijf je in om mee te lopen, meld een huis of bedrijf aan, of open de persoonlijke uitnodiging van een groepsleider.</p>
        <div className="participant-actions"><Link className="btn" href="/meelopen">Inschrijven</Link><Link className="btn outline" href="/huis-aanmelden">Plek aanmelden</Link></div>
      </section>
    </div>;
  }

  const sectionLabel = items.find((item) => item.key === activeSection)?.label || "Overzicht";
  return <div className={`participant-environment modern-participant role-${selectedRole.key}`}>
    <PwaInstallInvitation userId={userId} />
    <aside className="participant-sidebar" aria-label="Persoonlijke navigatie">
      <Link className="participant-brand" href="/"><img src="/images/logo.webp" alt="De Duindorpse Poorten van Halloween" /><span>De Poorten<small>Duindorp · Halloween {event.year}</small></span></Link>
      <RoleIdentity role={selectedRole} />
      <p className="participant-sidebar-caption">Jouw omgeving</p>
      <ParticipantNavigation role={selectedRole.key} activeSection={activeSection} desktop />
      <div className="member-sidebar-event"><CalendarDays aria-hidden="true"/><div><strong>{event.weekday} {event.dateShort}</strong><span>{event.times} · Duindorp</span></div></div>
      <div className="participant-sidebar-foot"><Link className="member-sidebar-link" href="/">Naar de website <ArrowUpRight size={15}/></Link><SignOutButton /></div>
    </aside>
    <div className="participant-main">
      <header className="participant-topbar">
        <div className="participant-topbar-identity"><span className="participant-topbar-mark" aria-hidden="true"><MoonStar /></span><div><p className="participant-eyebrow">Jouw Halloweenavond <ChevronRight size={11}/></p><strong>{sectionLabel}</strong></div></div>
        <div className="member-topbar-actions"><span className="member-event-chip"><span/>{event.dateLong}</span>{context.roles.length > 1 && <RoleSwitcher roles={context.roles} selected={selectedRole.key} />}<Link className="member-profile-shortcut" href={`/omgeving/${roleSlugs[selectedRole.key]}/meer`} aria-label="Profiel en instellingen"><UserRound size={18}/></Link></div>
      </header>
      {inviteNotice && <div className="participant-notice" role="status">{inviteNotice}</div>}
      <main className="participant-content" id="participant-content">
        {selectedRole.key === "walker" && <WalkerSection context={context} eventSlug={eventSlug} userId={userId} role={selectedRole} section={activeSection} />}
        {selectedRole.key === "viewer" && <ViewerSection context={context} eventSlug={eventSlug} userId={userId} role={selectedRole} section={activeSection} />}
        {selectedRole.key === "homeowner" && <HomeownerSection context={context} eventSlug={eventSlug} userId={userId} role={selectedRole} section={activeSection} />}
      </main>
    </div>
    <ParticipantNavigation role={selectedRole.key} activeSection={activeSection} />
    <SupportWidget key={`${selectedRole.key}:${selectedRole.groupId ?? selectedRole.portalId ?? selectedRole.accessId ?? "personal"}`} eventSlug={eventSlug} role={selectedRole.key} groupId={selectedRole.groupId ?? undefined} portalId={selectedRole.portalId ?? undefined} viewerAccessId={selectedRole.accessId ?? undefined} />
  </div>;
}

function RoleIdentity({ role }: { role: ParticipantRole }) {
  const Icon = role.key === "walker" ? Footprints : role.key === "viewer" ? Eye : Home;
  return <div className="role-identity"><span><Icon aria-hidden="true" /></span><div><small>Persoonlijke omgeving</small><strong>{role.label}</strong></div><span className="member-role-dot" aria-label="Toegang actief"/></div>;
}

function RoleSwitcher({ roles, selected }: { roles: ParticipantRole[]; selected: ParticipantRoleKey }) {
  const router = useRouter();
  return <label className="role-switcher"><span>Omgeving</span><select value={selected} onChange={(event) => router.push(`/omgeving/${roleSlugs[event.target.value as ParticipantRoleKey]}`)}>
    {roles.map((role) => <option key={role.key} value={role.key}>{role.label}</option>)}
  </select></label>;
}

function ParticipantNavigation({ role, activeSection, desktop = false }: { role: ParticipantRoleKey; activeSection?: string; desktop?: boolean }) {
  return <nav className={desktop ? "participant-nav desktop" : "participant-bottomnav"} aria-label={desktop ? "Omgevingsnavigatie" : "Mobiele omgevingsnavigatie"}>
    {navigation[role].map((item) => {
      const Icon = item.icon;
      return <Link key={item.key} className={activeSection === item.key ? "active" : ""} href={`/omgeving/${roleSlugs[role]}/${item.key}`} aria-current={activeSection === item.key ? "page" : undefined}><Icon /><span>{item.label}</span>{desktop && activeSection === item.key && <span className="member-nav-indicator"/>}</Link>;
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
    children: Array<PaymentChild & { ageAtEvent?: number | null }>;
    payment?: ParticipantPayment | null;
  } | null;
};
type RegistrationPreferences = {
  preferredStartAt?: string | null;
  desiredEndAt?: string | null;
  ordinaryStopAt?: string | null;
  editable?: boolean;
};
type GroupSnapshot = {
  group: {
    id: string;
    code: string;
    systemCode: string;
    displayName?: string | null;
    status: string;
    version: number;
    effectiveOrdinaryStopAt?: string | null;
    expectedFinaleArrivalAt?: string | null;
    start?: { name: string; locationName: string; address?: string; startsAt: string; addressReleased?: boolean; addressReleaseAt?: string } | null;
  };
  access: { leader: boolean; support: boolean };
  run: null | {
    id: string;
    status: string;
    version: number;
    ownEveningFinished?: boolean;
    farewells?: Record<string,{endedAt:string;reason:string}>;
    elapsedSeconds?: number;
    waitingInstruction?: boolean;
    remainingStopCount: number | null;
    currentStop: null | { id: string; sequence: number; kind?: "ordinary" | "finale"; scanAccepted: boolean; portal: { name: string; world: string; address: string; postalCode: string; intensity: number; operationStatus: string } };
    participants: Array<{ id: string; firstName: string; attendance: string; isOwnChild: boolean; status?: string | null }>;
    history: Array<{ sequence: number; outcome: string; completedAt: string; portalName: string; world: string }>;
  };
};

const paymentLabels: Record<string, string> = {
  awaiting_link: "Wacht op betaallink",
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
  const [preferences, setPreferences] = useState<RegistrationPreferences | null>(null);
  const [loading, setLoading] = useState(true);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const [registrationResult, groupResult, preferencesResult] = await Promise.all([
      client.schema("api").rpc("registration_snapshot", { _event_slug: eventSlug }),
      role.groupId ? client.schema("api").rpc("group_snapshot", { _group_id: role.groupId }) : Promise.resolve({ data: null, error: null }),
      client.schema("api").rpc("registration_preferences_snapshot", { _event_slug: eventSlug }),
    ]);
    if (!registrationResult.error) setRegistration(registrationResult.data as RegistrationSnapshot);
    if (!groupResult.error && groupResult.data) setGroup(groupResult.data as GroupSnapshot);
    if (!preferencesResult.error && preferencesResult.data) setPreferences(preferencesResult.data as RegistrationPreferences);
    setLoading(false);
  }, [eventSlug, role.groupId]);
  useSnapshotRefresh(load);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);

  if (section === "route" && role.groupId) return <ParticipantPageFrame eyebrow="De route ontvouwt zich stap voor stap" title="Route door Duindorp" compact><GroupExperience groupId={role.groupId} userId={userId} /></ParticipantPageFrame>;
  if (loading) return <ParticipantLoading />;
  if (section === "groep") return <WalkerGroup group={group} registration={registration} preferences={preferences} groupId={role.groupId ?? undefined} reload={load} />;
  if (section === "nachtpas") return <NightPass snapshot={registration} group={group} reload={load} />;
  if (section === "meer" || section === "updates") return <MorePage context={context} eventSlug={eventSlug} userId={userId} role="walker" />;
  return <><WalkerNow context={context} registration={registration} group={group} reload={load} /><div className="member-news-section"><PortalNews channel="parents" compact /></div></>;
}

function WalkerNow({ context, registration, group, reload }: { context: ParticipantContext; registration: RegistrationSnapshot | null; group: GroupSnapshot | null; reload: () => Promise<void> }) {
  const event=useEventDetails();
  const run = group?.run;
  const record = registration?.registration;
  const payment = record?.payment;
  const activeChildren = record?.children.filter((child) => child.status === "active") ?? [];
  const paidCount = activeChildren.filter((child) => childPaymentState(child, childPaymentFor(child, record?.children ?? [], payment)).paid).length;
  const allPaid = activeChildren.length > 0 && paidCount === activeChildren.length;
  const groupName = group?.group.displayName || (group ? `Groep ${group.group.code}` : "Jullie groep");
  const completed = run?.history.length ?? 0;
  const completedVisits = run?.history.filter((item) => ["visited", "mixed", "all_skipped"].includes(item.outcome)).length ?? 0;
  if(run?.ownEveningFinished)return <ParticipantPageFrame eyebrow="Jullie avontuur" title="Een nacht om te bewaren."><EarlyDeparture run={run} disabled={false} onSaved={reload}/><StampRail history={run.history}/><FamilyPortalThanks key={run.version}/></ParticipantPageFrame>;
  if (run?.status === "completed") return <ParticipantPageFrame eyebrow="Jullie avontuur" title="Een avond om te bewaren.">
    <section className="member-recap-hero"><img src="/images/04-home-iets-lekkers-steeg.webp" alt="Een verlichte Halloweenavond in Duindorp"/><div><span className="member-state-pill"><CheckCircle2 size={14}/>Route afgerond</span><h2>Samen door de nacht.</h2><p>Jullie bezochten {completed} poorten en verzamelden {completedVisits} wereldzegels. Tijd om nog even na te genieten.</p><Link href="/poortenboek" className="btn">Open het Poortenboek <ArrowUpRight size={17}/></Link></div></section>
    <div className="participant-stat-grid"><StatusCard icon={DoorOpen} label="Afgeronde poorten" value={String(completed)} good/><StatusCard icon={Sparkles} label="Verzamelde zegels" value={String(completedVisits)} good/><StatusCard icon={Users} label="Jullie groep" value={groupName}/></div>
    <StampRail history={run.history} />
    <Link href="/deel-de-magie" className="participant-card member-action-card"><span className="member-icon-tile violet"><Sparkles/></span><div><p className="participant-eyebrow">Jullie herinnering</p><h2>Maak een terugblikkaart</h2><p>Een mooie kaart om te bewaren of te delen.</p></div><ArrowUpRight/></Link>
  </ParticipantPageFrame>;

  if (run && ["live", "paused"].includes(run.status)) {
    const stop = run.currentStop;
    const isFinale = stop?.kind === "finale";
    const currentAction = group?.access.leader ? stop?.scanAccepted ? isFinale ? "Laatste poort afronden" : "Bezoek afronden" : "Open bezoek & scan" : "Bekijk de route";
    return <ParticipantPageFrame eyebrow="Jullie avond is begonnen" title={run.status === "paused" ? "Even samen op adem komen." : "Jullie volgende avontuur."}>
      {run.status === "paused" && <div className="participant-alert"><Pause/>De groepsleider heeft de route gepauzeerd. Blijf samen en wacht op de volgende instructie.</div>}
      <div className="member-live-grid">
        {stop ? <section className="member-destination"><img src="/images/pluvierstraat.webp" alt="Nachtelijk verlichte Duindorpse poort"/><div className="member-destination-overlay"/><div className="member-destination-copy"><span className="member-state-pill"><span/>{isFinale ? "Laatste poort" : `Poort ${stop.sequence} · ${stop.portal.world}`}</span><h2>{stop.portal.name}</h2><p><Home size={16}/>{stop.portal.address}, {stop.portal.postalCode}</p><div className="member-destination-meta"><span><ShieldCheck size={15}/>Spanning {stop.portal.intensity}/4</span><span><Footprints size={15}/>{Math.floor((run.elapsedSeconds ?? 0) / 60)} minuten onderweg</span></div><Link className="btn member-destination-action" href="/omgeving/meeloper/route">{currentAction}<ChevronRight size={18}/></Link></div></section> : <section className="participant-card member-waiting"><Clock3/><h2>Een nieuwe poort komt eraan</h2><p>Blijf samen. Hier verschijnt waar jullie verder mogen zodra de volgende bestemming is bevestigd.</p></section>}
        <aside className="member-evening-aside"><section className="participant-card member-journey-summary"><div className="section-title"><div><p className="participant-eyebrow">Jullie groep</p><h2>{groupName}</h2></div><span className="member-group-chip">{group?.group.code}</span></div><div className="member-mini-metrics"><div><strong>{run.participants.length}</strong><span>kinderen</span></div><div><strong>{completed}</strong><span>poorten klaar</span></div><div><strong>{completedVisits}</strong><span>zegels</span></div></div><Link href="/omgeving/meeloper/groep" className="member-inline-link">Bekijk de groep<ChevronRight size={16}/></Link></section><section className="participant-card member-times"><p className="participant-eyebrow">De avond in het kort</p><div className="member-time-row"><span className="member-time-icon"><Clock3 size={17}/></span><div><small>Stoppen met gewone poorten</small><strong>{group?.group.effectiveOrdinaryStopAt ? formatTime(group.group.effectiveOrdinaryStopAt) : "Wordt berekend"}</strong></div></div><div className="member-time-row"><span className="member-time-icon violet"><MoonStar size={17}/></span><div><small>Verwachte aankomst finale</small><strong>{group?.group.expectedFinaleArrivalAt ? formatTime(group.group.expectedFinaleArrivalAt) : "Wordt berekend"}</strong></div></div><p className="member-soft-note">De finale volgt na jullie laatste gewone poort.</p></section></aside>
      </div>
      <div className="member-safety-strip"><span><ShieldCheck size={18}/><strong>Blijf gezellig bij elkaar.</strong> Een te spannende poort mag je overslaan.</span><Link href="/omgeving/meeloper/route">Naar de route <ArrowUpRight size={15}/></Link></div>
      <section className="member-shortcuts" aria-label="Snel naar"><Link href="/omgeving/meeloper/nachtpas"><TicketCheck/><span><strong>Jullie Nachtpas</strong><small>Deelname & betaling</small></span><ChevronRight/></Link><Link href="/poortenboek"><Sparkles/><span><strong>Poortenboek</strong><small>Jouw zegels & verhalen</small></span><ChevronRight/></Link><Link href="/omgeving/meeloper/groep"><Users/><span><strong>Mijn groep</strong><small>Wie loopt er mee?</small></span><ChevronRight/></Link></section>
    </ParticipantPageFrame>;
  }

  return <ParticipantPageFrame eyebrow="De voorpret begint hier" title="Alles voor jullie Halloweenavond.">
    <div className="member-prepare-hero"><div><span className="member-state-pill"><MoonStar size={14}/>{event.weekday} {event.dateShort}</span><h2>De wijk wacht op jullie.</h2><p>Een avond vol bijzondere deuren en kleine avonturen. Hier regel je rustig alles voor jullie vertrek.</p><Countdown target={group?.group.start?.startsAt??context.event.startsAt}/></div><img src="/images/05-meelopen-samen-op-pad.webp" alt="Samen op pad door Duindorp"/></div>
    <div className="participant-stat-grid"><StatusCard icon={allPaid ? CheckCircle2 : Clock3} label="Betaling" value={activeChildren.length ? `${paidCount} van ${activeChildren.length} kinderen betaald` : "Wordt voorbereid"} good={allPaid}/><StatusCard icon={Users} label="Jullie groep" value={group ? groupName : "Indeling volgt"}/><StatusCard icon={Clock3} label="Startmoment" value={group?.group.start ? formatTime(group.group.start.startsAt) : "Tijdslot volgt"}/></div>
    {!allPaid && record && <Link className="member-attention-card" href="/omgeving/meeloper/nachtpas"><span className="member-icon-tile"><WalletIcon/></span><div><strong>Controleer jullie betaalstatus</strong><p>{Math.max(0, activeChildren.length-paidCount)} {activeChildren.length-paidCount === 1 ? "kind wacht" : "kinderen wachten"} nog op bevestiging. Alles staat bij elkaar in de Nachtpas.</p></div><ArrowUpRight/></Link>}
    {group?.group.start && <section className="participant-card member-start-appointment"><span className="member-icon-tile violet"><CalendarDays/></span><div><p className="participant-eyebrow">Jullie starttijd staat vast</p><h2>{formatDateTime(group.group.start.startsAt)}</h2><StartLocation start={group.group.start}/></div><Link className="btn outline" href="/omgeving/meeloper/groep">Bekijk afspraak<ChevronRight size={16}/></Link></section>}
    <div className="participant-preparation-grid">{record && <section className="participant-card participant-children-card"><div className="section-title"><div><p className="participant-eyebrow">Jullie inschrijving</p><h2>Deelnemende kinderen</h2></div><TicketCheck aria-hidden="true"/></div><ChildPaymentRows items={record.children} registrationId={record.id} legacyPayment={payment} reload={reload}/></section>}<PreparationList paid={allPaid} grouped={Boolean(group)}/></div>
    <section className="member-shortcuts" aria-label="Snel naar"><Link href="/poortenboek"><Sparkles/><span><strong>De voorpret gaat verder</strong><small>Open het Poortenboek</small></span><ChevronRight/></Link><Link href="/omgeving/meeloper/groep"><Users/><span><strong>Samen op pad</strong><small>Groep & samenlopen</small></span><ChevronRight/></Link><Link href="/deel-de-magie"><ArrowUpRight/><span><strong>Deel de magie</strong><small>Maak jullie deelkaart</small></span><ChevronRight/></Link></section>
  </ParticipantPageFrame>;
}

function WalletIcon(){return <TicketCheck/>;}
function StartLocation({start}:{start:NonNullable<GroupSnapshot["group"]["start"]>}) {
  if (start.addressReleased===false) return <p className="member-soft-note"><LockKeyhole size={14}/> Jullie eerste adres verschijnt {start.addressReleaseAt?`op ${formatDateTime(start.addressReleaseAt)}`:"één uur voor jullie start"}. Dat is één uur voor vertrek. Jullie starttijd staat alvast vast.</p>;
  return <p>{start.locationName}{start.address?` · ${start.address}`:""}</p>;
}

function WalkerGroup({ group, registration, preferences, groupId, reload }: { group: GroupSnapshot | null; registration: RegistrationSnapshot | null; preferences: RegistrationPreferences | null; groupId?: string; reload: () => Promise<void> }) {
  if (!group) return <ParticipantPageFrame eyebrow="Groepsindeling" title="Jullie groep komt eraan"><section className="participant-card"><Users /><h2>We delen zorgvuldig in</h2><p>Zodra jullie groep en startafspraak bekend zijn, vind je ze hier.</p></section>{registration?.registration && <ParticipantTogether registrationId={registration.registration.id} />}</ParticipantPageFrame>;
  const participants = group.run?.participants ?? [];
  const visibleChildren = participants.length ? participants : (registration?.registration?.children ?? []).map((child) => ({ id: child.id, firstName: child.firstName, attendance: "aangemeld", isOwnChild: true, status: null }));
  return <ParticipantPageFrame eyebrow={`Groep ${group.group.code}`} title={group.access.leader ? "Jij houdt het overzicht." : "Samen op pad."}>
    {registration?.registration && <ParticipantTogether registrationId={registration.registration.id} />}
    {groupId && <div className="participant-group-grid"><GroupIdentity groupId={groupId} systemCode={group.group.systemCode} displayName={group.group.displayName} version={group.group.version} canEdit={group.access.leader} onSaved={reload} /><GroupJourneyPreference groupId={groupId} onSaved={reload} /></div>}
    <div className="participant-stat-grid group-preference-stats">
      <StatusCard icon={Clock3} label="Voorkeur start" value={preferences?.preferredStartAt ? formatTime(preferences.preferredStartAt) : "Geen voorkeur"} />
      <StatusCard icon={MoonStar} label="Gewenste laatste poort" value={preferences?.desiredEndAt ? formatTime(preferences.desiredEndAt) : "Geen voorkeur"} />
      <StatusCard icon={Route} label="Voortgang" value={group.run ? `${group.run.history.length} bevestigd` : "Nog niet gestart"} />
    </div>
    <section className="participant-card group-summary"><span className="group-summary-icon" aria-hidden="true"><Footprints /></span><div><p className="participant-eyebrow">Startmoment</p><h2>{group.group.start ? formatDateTime(group.group.start.startsAt) : "Wordt binnenkort gedeeld"}</h2>{group.group.start?<StartLocation start={group.group.start}/>:<p>Jullie startplek wordt binnenkort bekendgemaakt.</p>}</div><span className="group-code">{group.group.code}</span></section>
    <section className="participant-card"><div className="section-title"><div><p className="participant-eyebrow">Gekoppelde deelnemers</p><h2>{group.access.leader ? "Aanwezigheid en veiligheid" : "Jouw kinderen"}</h2></div><ShieldCheck /></div>
      {visibleChildren.length === 0 && <p>De deelnemerslijst verschijnt zodra de route start.</p>}
      <div className="participant-list">{visibleChildren.map((child) => <div key={child.id}><span className="participant-avatar">{child.firstName.slice(0, 1)}</span><span><strong>{child.firstName}</strong><small>{child.attendance === "present" ? "Aanwezig" : child.attendance === "absent" ? "Afwezig" : "Aangemeld"}</small></span>{child.status && <em>{child.status === "visited" ? "Bezocht" : child.status === "skipped" ? "Overgeslagen" : "Wacht"}</em>}</div>)}</div>
      {group.access.leader ? <div className="participant-alert subtle"><ShieldCheck />Open Route om de aanwezigheid te controleren, een poort te scannen of de tocht te pauzeren.</div> : <p className="privacy-note"><LockKeyhole /> Hier houd je de deelname van jouw kinderen bij.</p>}
    </section>
    <section className="participant-card group-passport"><div className="section-title"><div><p className="participant-eyebrow">Poortenpaspoort</p><h2>Een spoor door de nacht</h2></div><MoonStar /></div>
      <p>{group.run ? "Na ieder bevestigd bezoek verschijnt hier een stempel. Jullie volgende bestemming wordt onderweg bekendgemaakt." : "De stempels verschijnen tijdens de tocht. Welke poorten jullie bezoeken, blijft nog even een verrassing."}</p>
      {group.run?.history.length ? <StampRail history={group.run.history} /> : <div className="passport-placeholders" aria-label="Nog geen bevestigde poorten">{Array.from({ length: 6 }, (_, index) => <span key={index}><MoonStar /><small>Nog verborgen</small></span>)}</div>}
    </section>
    {group.access.leader && groupId && <ViewerAccessManager groupId={groupId} />}
  </ParticipantPageFrame>;
}

function NightPass({ snapshot, group, reload }: { snapshot: RegistrationSnapshot | null; group: GroupSnapshot | null; reload: () => Promise<void> }) {
  const event=useEventDetails();
  const registration = snapshot?.registration;
  if (!registration) return <ParticipantPageFrame eyebrow="Nachtpas" title="Nog geen inschrijving"><section className="participant-card"><p>Na je definitieve inschrijving verschijnt hier de Nachtpas voor je eigen kinderen.</p><Link className="btn" href="/meelopen">Schrijf je in</Link></section></ParticipantPageFrame>;
  const activeChildren = registration.children.filter((child) => child.status === "active");
  const participating = registration.status === "submitted" && activeChildren.length > 0;
  const paid = activeChildren.length > 0 && activeChildren.every((child) => childPaymentState(child, childPaymentFor(child, registration.children, registration.payment)).paid);
  return <ParticipantPageFrame eyebrow="Alles voor deelname" title="Jullie Nachtpas">
    <section className={`night-pass ${participating ? "active" : "locked"}`}>
      <div className="night-pass-top"><span><MoonStar />Duindorp {event.year}</span><strong>{participating ? "TOEGANG ACTIEF" : "DEELNAME NIET ACTIEF"}</strong></div>
      <h2>{registration.reference}</h2>
      <div className="night-pass-grid"><span>Kinderen<strong>{activeChildren.map((child) => child.firstName).join(", ")}</strong></span><span>Tijdslot<strong>{group?.group.start ? formatTime(group.group.start.startsAt) : "Volgt"}</strong></span><span>Groep<strong>{group ? group.group.code : "Volgt"}</strong></span><span>Betaling<strong>{registration.payment ? paymentLabels[registration.payment.status] ?? registration.payment.status : "Wordt voorbereid"}</strong></span></div>
      {participating ? <div className="night-pass-valid"><ShieldCheck />Toegang bevestigd. Neem deze pagina en de bevestigingsmail mee.</div> : <div className="night-pass-warning"><ShieldCheck /><span>Deze inschrijving heeft geen actieve deelname. Neem contact op met de organisatie als dit niet klopt.</span></div>}
      {!paid && <p className="night-pass-warning"><Clock3 /><span>De betaling is nog niet volledig bevestigd. Controleer hieronder de betaalstatus per kind. Dit blokkeert jullie deelname niet.</span></p>}
    </section>
    <section className="participant-card participant-children-card"><div className="section-title"><div><p className="participant-eyebrow">Per eigen kind</p><h2>Deelnamestatus</h2></div><TicketCheck aria-hidden="true" /></div>
      <ChildPaymentRows items={registration.children} registrationId={registration.id} legacyPayment={registration.payment} reload={reload} />
    </section>
    <section className="participant-card practical"><p className="participant-eyebrow">Praktisch</p><h2>Zo gebruik je de Nachtpas</h2><ul><li>Meld je met de groepsleider bij de gepubliceerde startplek.</li><li>Kinderen blijven de hele avond bij hun eigen groep en verantwoordelijke volwassene.</li><li>Laat deze Nachtpas zien als de organisatie daarom vraagt.</li></ul></section>
  </ParticipantPageFrame>;
}

type ViewerSnapshot = { group: { code: string; status: string; start?: { name: string; startsAt: string; addressReleased?: boolean; addressReleaseAt?: string } | null }; progress: { status: string; completed: number; lastUpdatedAt: string }; history: Array<{ sequence: number; world: string; outcome: string; completedAt: string }> };

function ViewerSection({ context, eventSlug, userId, role, section }: { context: ParticipantContext; eventSlug: string; userId: string; role: ParticipantRole; section?: string }) {
  const [snapshot, setSnapshot] = useState<ViewerSnapshot | null>(null);
  const load=useCallback(async()=>{
    const client=createClient();if (!client||!role.groupId)return;
    const {data,error}=await client.schema("api").rpc("group_viewer_snapshot",{_group_id:role.groupId});
    if (!error&&data)setSnapshot(data as ViewerSnapshot);
  },[role.groupId]);
  useSnapshotRefresh(load);
  useEffect(()=>{const timer=window.setTimeout(()=>void load(),0);return()=>window.clearTimeout(timer);},[load]);
  if (section === "updates") return <UpdatesPanel eventSlug={eventSlug} role="viewer" />;
  if (section === "meer") return <MorePage context={context} eventSlug={eventSlug} userId={userId} role="viewer" accessId={role.accessId ?? undefined} />;
  if (!snapshot) return <ParticipantLoading />;
  if (section === "groep") return <ParticipantPageFrame eyebrow="Bewust beperkt" title={`Groep ${snapshot.group.code}`}><section className="participant-card"><ShieldCheck /><h2>Meekijken zonder mee te lopen</h2><p>Volg wanneer de groep vertrekt en welke werelden ze al hebben bezocht.</p><div className="summary-row"><span>Startmoment</span><strong>{snapshot.group.start ? formatDateTime(snapshot.group.start.startsAt) : "Volgt"}</strong></div><div className="summary-row"><span>Toegang</span><strong>{role.expiresAt ? `tot ${formatDateTime(role.expiresAt)}` : "tot intrekking"}</strong></div></section></ParticipantPageFrame>;
  return <ParticipantPageFrame eyebrow="Dichtbij, ook van een afstand" title={snapshot.progress.status === "completed" ? "De groep is veilig klaar." : snapshot.progress.status === "live" ? "Volg hun avontuur." : "De voorpret is begonnen."}>
    <section className="member-viewer-hero"><div><span className="member-state-pill"><Eye size={14}/>Meekijken · {snapshot.group.code}</span><h2>{snapshot.progress.status === "completed" ? "De laatste poort is bezocht." : snapshot.progress.status === "live" ? "Samen door de nacht." : "Binnenkort gaan de poorten open."}</h2><p>Volg de wereldstappen van de groep. Je krijgt voortgang te zien, zonder persoonlijke kindgegevens of verborgen bestemmingen.</p><div className="member-viewer-progress"><strong>{snapshot.progress.completed}</strong><span>bevestigde {snapshot.progress.completed === 1 ? "poort" : "poorten"}<small>Bijgewerkt {formatDateTime(snapshot.progress.lastUpdatedAt)}</small></span></div></div><img src="/images/02-home-de-avond-straat.webp" alt="Verlichte Halloweenstraat in Duindorp"/></section>
    <div className="member-section-heading"><div><p className="participant-eyebrow">Stap voor stap</p><h2>Hun reis door de werelden</h2></div><span className="member-state-pill subtle"><LockKeyhole size={13}/>Beperkte voortgang</span></div>
    <StampRail history={snapshot.history.map((item) => ({ ...item, portalName: item.world }))} hideNames />
    <div className="member-safety-strip"><span><ShieldCheck size={18}/>Na ieder afgerond bezoek wordt de voortgang bijgewerkt.</span><Link href="/omgeving/meekijker/updates">Organisatie-updates<ArrowUpRight size={15}/></Link></div>
  </ParticipantPageFrame>;
}

type PortalSnapshot = { portal: null | { id: string; name: string; operationStatus: "scheduled" | "open" | "paused" | "closed" } } | null;
type ArrivalsSnapshot = { expectedTotal: number; arrivals: Array<{ groupCode: string; plannedArrivalAt: string; plannedDepartureAt: string; expectedChildren: number; state: string }> };

function HomeownerSection({ context, eventSlug, userId, role, section }: { context: ParticipantContext; eventSlug: string; userId: string; role: ParticipantRole; section?: string }) {
  const event=useEventDetails();
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
  useSnapshotRefresh(load);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  if (section === "updates") return <UpdatesPanel eventSlug={eventSlug} role="homeowner" />;
  if (section === "meer") return <MorePage context={context} eventSlug={eventSlug} userId={userId} role="homeowner" />;
  if (role.portalId || portal?.portal) return <ParticipantPageFrame eyebrow="Jullie plek achter de poort" title="Een fijne avond begint bij jullie."><section className="member-gate-entry"><div><span className="member-state-pill"><DoorOpen size={14}/>Jullie Poortkamer</span><h2>{portal?.portal?.name || "Alles voor jullie poortteam."}</h2><p>Ontvang de groepen, bereid jullie poort voor en houd contact met het team. In de Poortkamer komt alles samen.</p><Link className="btn" href="/mijn-huis">Open De Poortkamer <ArrowUpRight size={17}/></Link></div><img src="/images/06-huis-aanmelden-jouw-deur.webp" alt="Een warm verlichte Halloweenpoort"/></section><div className="participant-stat-grid"><StatusCard icon={DoorOpen} label="Ontvangst" value={portal?.portal?.operationStatus === "open" ? "Jullie poort is open" : portal?.portal?.operationStatus === "paused" ? "Tijdelijk gepauzeerd" : portal?.portal?.operationStatus === "closed" ? "Poort gesloten" : "Voorbereiding"} good={portal?.portal?.operationStatus === "open"}/><StatusCard icon={Users} label="Verwacht totaal" value={arrivals ? `${arrivals.expectedTotal} kinderen` : "Wordt berekend"}/><StatusCard icon={CalendarDays} label="Evenement" value={`${event.dateShort} · ${event.times}`}/></div><div className="member-shortcuts"><Link href="/mijn-huis"><Users/><span><strong>Jullie poortteam</strong><small>Rollen & voorbereiding</small></span><ChevronRight/></Link><Link href="/omgeving/huiseigenaar/updates"><Bell/><span><strong>Organisatie-updates</strong><small>Alles wat je moet weten</small></span><ChevronRight/></Link><Link href="/deel-de-magie"><Sparkles/><span><strong>Laat jullie poort stralen</strong><small>Maak een deelkaart</small></span><ChevronRight/></Link></div></ParticipantPageFrame>;
  return <ParticipantPageFrame eyebrow="Mijn huis · jullie plek in de nacht" title={portal?.portal?.name || "Mijn poort"}>
    <div className="cockpit-metrics owner-summary-metrics"><StatusCard icon={Users} label="Verwacht totaal" value={arrivals ? `${arrivals.expectedTotal} kinderen` : "Wordt berekend"} /><StatusCard icon={Clock3} label="Volgend venster" value={arrivals?.arrivals.find((item) => item.state !== "completed") ? `${formatTime(arrivals.arrivals.find((item) => item.state !== "completed")!.plannedArrivalAt)}–${formatTime(arrivals.arrivals.find((item) => item.state !== "completed")!.plannedDepartureAt)}` : "Geen open venster"} /></div>
    <div className="planned-not-live owner-arrival-note"><Clock3 /><span><strong>Dit is de verwachte aankomsttijd.</strong>Groepen kunnen eerder of later lopen. Gebruik Pauze zodra ontvangst tijdelijk niet veilig of mogelijk is.</span></div>
    <PortalDashboard eventSlug={eventSlug} /><PortalNews channel="houses" compact />
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

function MorePage({ context, eventSlug, userId, role, accessId }: { context: ParticipantContext; eventSlug: string; userId: string; role: ParticipantRoleKey; accessId?: string }) {
  return <ParticipantPageFrame eyebrow="Instellingen en bereikbaarheid" title="Jouw instellingen">
    {role === "walker" && <UpdatesPanel eventSlug={eventSlug} role="walker" embedded />}
    {role !== "viewer" && <Link href="/deel-de-magie" className="participant-card"><Sparkles /><div><h2>Deel de magie</h2><p>Maak een veilige deelkaart voor jouw deelname of Poort.</p></div><ChevronRight /></Link>}
    <section className="participant-card participant-contact-compact"><Contact /><div><strong>Contact bij storing of spoed</strong><div className="participant-actions"><a href={"mailto:" + context.event.supportEmail}>E-mail</a>{context.event.supportPhone && <a href={"tel:" + context.event.supportPhone.replace(/\s/g, "")}>Bel organisatie</a>}</div></div></section>
    <Link href="/omgeving/communicatie" className="participant-card">Nachtpost en communicatievoorkeuren →</Link>
    <PortalNews channel={role === "homeowner" ? "houses" : "parents"} compact />
    <ProfilePanel eventSlug={eventSlug} />
    <PushNotificationSettings key={userId} />
    <section className="participant-card participant-account"><div><h2>Uitloggen</h2><p>Klaar op dit apparaat? Sluit je persoonlijke omgeving veilig af.</p></div><SignOutButton /></section>
    {role === "viewer" && accessId && <ViewerSelfRevoke accessId={accessId} />}
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
    if (data) { const next = data as ProfileSnapshot; setProfile(next); setName(next.displayName ?? ""); document.documentElement.dataset.readable = next.preferences.readableMode ? "true" : "false"; document.documentElement.dataset.reduceMotion = next.preferences.reducedMotion ? "true" : "false"; localStorage.setItem("poorten-motion", next.preferences.reducedMotion ? "off" : "on"); window.dispatchEvent(new Event("poorten-motion")); }
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
  return <section className="participant-card viewer-manager"><div className="section-title"><div><p className="participant-eyebrow">Read-only meekijken</p><h2>Nodig een meekijker uit</h2></div><Eye /></div><p>De uitnodiging is 48 uur geldig. Een meekijker volgt de voortgang van jullie groep zonder kindgegevens te zien.</p><div className="invite-grid"><label className="participant-field"><span>E-mailadres</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="naam@voorbeeld.nl" /></label><label className="participant-field"><span>Toegang geldig</span><select value={duration} onChange={(event) => setDuration(event.target.value)}><option value="event">Tot intrekking</option><option value="24">24 uur</option><option value="72">3 dagen</option><option value="168">7 dagen</option></select></label><button className="btn" disabled={!email.includes("@") || !email.includes(".")} onClick={() => void invite()}>Uitnodigen</button></div>{notice && <p className="form-notice" role="status">{notice}</p>}<div className="access-rows">{snapshot?.active.map((access) => <div key={access.id}><span><strong>{access.email}</strong><small>{access.expiresAt ? `tot ${formatDateTime(access.expiresAt)}` : "tot intrekking"}</small></span><button className="text-link" onClick={() => void revoke("access", access.id)}>Intrekken</button></div>)}{snapshot?.pending.map((invite) => <div key={invite.id}><span><strong>{invite.email}</strong><small>uitnodiging wacht op acceptatie</small></span><button className="text-link" onClick={() => void revoke("invite", invite.id)}>Intrekken</button></div>)}</div></section>;
}


function ParticipantPageFrame({ eyebrow, title, compact = false, children }: { eyebrow: string; title: string; compact?: boolean; children: React.ReactNode }) {
  return <div className={`participant-page page-transition ${compact ? "compact" : ""}`}><header className="participant-page-head"><div><p className="participant-eyebrow">{eyebrow}</p><h1>{title}</h1></div></header>{children}</div>;
}

function ParticipantLoading() { return <div className="participant-loading"><RefreshCw className="spin" /><span>Je omgeving wordt veilig geladen…</span></div>; }

function StatusCard({ icon: Icon, label, value, good = false }: { icon: LucideIcon; label: string; value: string; good?: boolean }) {
  return <section className={`participant-card status-card ${good ? "good" : ""}`}><span><Icon aria-hidden="true" /></span><div><small>{label}</small><strong>{value}</strong></div></section>;
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

function formatTime(value: string) { return new Date(value).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }); }
function formatDateTime(value: string) { return new Date(value).toLocaleString("nl-NL", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }); }
