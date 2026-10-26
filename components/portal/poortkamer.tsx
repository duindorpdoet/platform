"use client";
import { useEventDetails } from "@/components/redesign/event-details";
import {HousePortalThanks} from "@/components/redesign/portal-thanks";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { PortalNews } from "@/components/editorial/portal-news";
import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  ArrowRight,
  CalendarDays,
  Bell,
  ChevronRight,
  DoorOpen,
  Footprints,
  KeyRound,
  Menu,
  MessageCircle,
  Moon,
  Pause,
  RefreshCw,
  ShieldCheck,
  Users,
  WifiOff,
} from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { SignOutButton } from "@/components/auth/account-actions";
import {
  PwaInstallInvitation,
  PushNotificationSettings,
} from "@/components/pwa/pwa-experience";
import { SupportWidget } from "@/components/support/support-widget";
import { usePrivateBroadcast } from "@/lib/realtime/use-private-broadcast";
import { createClient } from "@/lib/supabase/client";
import {
  canEditPortal,
  canManageTeam,
  notificationLabels,
  portalRoles,
  portalStates,
  portalTime,
  readinessItems,
  roomError,
  roomMetrics,
  type PortalRoom,
} from "@/lib/domain/poortkamer";
import { PoortkamerChat } from "./poortkamer-chat";
import { PoortkamerLiveV2, PoortkamerManagementV2 } from "./poortkamer-v2";
import s from "./poortkamer.module.css";
import { GatePoster } from "@/components/redesign/gate-poster";
import { QrCode } from "lucide-react";

type Tab = "night" | "visits" | "team" | "messages" | "more";
const nav = [
  { key: "night", label: "Nachtwacht", icon: Moon },
  { key: "visits", label: "Bezoeken", icon: Footprints },
  { key: "team", label: "Team", icon: Users },
  { key: "messages", label: "Berichten", icon: MessageCircle },
  { key: "more", label: "Meer", icon: Menu },
] as const;
const inviteLabels = {
  pending: "Wacht op bevestiging",
  accepted: "Aangenomen",
  expired: "Verlopen",
  revoked: "Ingetrokken",
};

export function Poortkamer({
  eventSlug,
  initial,
  admin = false,
}: {
  eventSlug: string;
  initial: PortalRoom;
  admin?: boolean;
}) {
  const event = useEventDetails();
  const [room, setRoom] = useState<PortalRoom | null>(initial);
  const [portalId, setPortalId] = useState(initial.portal.id);
  const [moreSection, setMoreSection] = useState("preparation");
  const [preparationSection, setPreparationSection] = useState("checklist");
  const [tab, setTab] = useState<Tab>("night");
  const [visitTab, setVisitTab] = useState<"next" | "expected" | "past">(
    "next",
  );
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [offline, setOffline] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const [dialog, setDialog] = useState<
    "invite" | "pause" | "stop" | "details" | null
  >(null);
  const contentRef = useRef<HTMLElement>(null);
  const commandPending = useRef(false);
  const version = useRef(0);
  const userId = initial.userId;
  const clearPrivate = useCallback(() => {
    version.current += 1;
    setRoom(null);
  }, []);
  const load = useCallback(async () => {
    if (document.hidden) return;
    if (!navigator.onLine) {
      setOffline(true);
      return;
    }
    const client = createClient();
    if (!client) return;
    const request = ++version.current;
    try {
      const { data, error } = await client
        .schema("api")
        .rpc("portal_room_snapshot", {
          _event_slug: eventSlug,
          _portal_id: portalId,
        });
      if (request !== version.current) return;
      if (!navigator.onLine) { setOffline(true); return; }
      if (error) {
        if (error.code === "42501" || error.code === "PGRST301") clearPrivate();
        setNotice(roomError(error.message));
        return;
      }
      if (!data || (data as PortalRoom).userId !== userId) {
        clearPrivate();
        return;
      }
      setRoom(data as PortalRoom);
      setOffline(false);
    } catch {
      if(request === version.current)setOffline(true);
    }
  }, [eventSlug, portalId, userId, clearPrivate]);
  useEffect(() => {
    const client = createClient();
    if (!client) return;
    const { data: listener } = client.auth.onAuthStateChange(
      (event: AuthChangeEvent, session: Session | null) => {
        if (event === "SIGNED_OUT" || !session || session.user.id !== userId)
          clearPrivate();
      },
    );
    const poll = window.setInterval(() => void load(), 20_000);
    const timer = window.setInterval(() => setNow(Date.now()), 30_000);
    const refresh = () => void load();
    const disconnected = () => {
      version.current += 1;
      setOffline(true);
    };
    window.addEventListener("pagehide", clearPrivate);
    window.addEventListener("beforeunload", clearPrivate);
    window.addEventListener("online", refresh);
    window.addEventListener("offline", disconnected);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      listener.subscription.unsubscribe();
      clearInterval(poll);
      clearInterval(timer);
      window.removeEventListener("pagehide", clearPrivate);
      window.removeEventListener("beforeunload", clearPrivate);
      window.removeEventListener("online", refresh);
      window.removeEventListener("offline", disconnected);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [load, clearPrivate, userId]);
  const live = usePrivateBroadcast(room?.portalTopic, () => void load());
  usePrivateBroadcast(room?.communityTopic, () => void load());
  useEffect(() => {
    if (!offline) return;
    const timeout = window.setTimeout(clearPrivate, 5 * 60_000);
    return () => clearTimeout(timeout);
  }, [offline, clearPrivate]);
  useEffect(() => {
    if (contentRef.current) contentRef.current.scrollTop = 0;
  }, [tab, moreSection]);
  useEffect(() => {
    const open = (event: Event) => {
      const detail = (event as CustomEvent).detail || {};
      if (detail.tab) setTab(detail.tab);
      if (detail.moreSection) setMoreSection(detail.moreSection);
      if (detail.preparationSection) setPreparationSection(detail.preparationSection);
    };
    window.addEventListener("poorten-guide-navigate", open);
    return () => window.removeEventListener("poorten-guide-navigate", open);
  }, []);
  async function command(
    operation: string,
    payload: Record<string, unknown>,
    team = false,
  ) {
    if (commandPending.current || offline || !navigator.onLine || !room) {
      setNotice(
        "Geen verbinding. Er is niets opgeslagen. Probeer opnieuw wanneer je online bent.",
      );
      return false;
    }
    const client = createClient();
    if (!client) return false;
    commandPending.current = true;
    setBusy(true);
    setNotice("");
    try {
      const { error } = await client
        .schema("api")
        .rpc(team ? "portal_team_command" : "portal_room_update", {
          _portal_id: room.portal.id,
          _operation: operation,
          _payload: payload,
          _key: crypto.randomUUID(),
        });
      if (error) {
        setNotice(roomError(error.message));
        await load();
        return false;
      }
      setNotice("Opgeslagen. Jullie team is weer bijgepraat.");
      setDialog(null);
      await load();
      return true;
    } catch {
      setNotice(
        "Niet bevestigd. Vernieuw de stand voordat je opnieuw bevestigt.",
      );
      return false;
    } finally {
      commandPending.current = false;
      setBusy(false);
    }
  }
  if (!room)
    return (
      <div className={s.room}>
        <div className={s.errorPage}>
          <h1>Open je Poortkamer opnieuw</h1>
          <p>
            Log opnieuw in om verder te gaan naar jullie Poortkamer.
          </p>
          <Link className={s.button} href="/mijn-huis">
            Opnieuw openen
          </Link>
          <Link className={s.button} href="/omgeving">
            Mijn omgeving
          </Link>
        </div>
      </div>
    );
  const metrics = roomMetrics(room, now);
  const canLive = room.role !== "viewer";
  const manage = canManageTeam(room.role);
  const canEdit = canEditPortal(room.role);
  const days = Math.max(
    0,
    Math.ceil(
      (Date.parse(`${room.eventDate}T17:00:00+01:00`) - now) / 86_400_000,
    ),
  );
  const unreadMessages = room.channels.reduce((total, channel) => total + channel.unread, 0);
  const ended = Date.parse(`${room.eventDate}T23:59:59+01:00`) < now;
  const disabled = offline || busy;
  const statusAction = (
    state: "open" | "paused" | "closed",
    minutes?: number,
    reason = "Poort gereed voor ontvangst",
  ) =>
    command("status", {
      state,
      minutes: minutes ?? null,
      version: room.portal.version,
      reason,
    });
  return (
    <div className={`${s.room} ${tab === "messages" ? s.chatMode : ""}`} data-workspace="poortkamer" data-current-tab={tab}>
      <div className={s.shell} data-poortkamer-shell>
        <aside className={s.sidebar} aria-label="Poortkamer menu">
          <Link className={s.brand} href="/">
            <Image
              src="/images/logo.webp"
              width={140}
              height={90}
              alt="De Duindorpse Poorten van Halloween"
              priority
            />
            <div>
              <strong>De Poortkamer</strong>
              <small>Duindorp · {event.dateLong}</small>
            </div>
          </Link>
          <div className={s.gateIdentity}><span className={s.gateIcon}><DoorOpen size={22} /></span><div><small>{room.portal.code} · {room.portal.world}</small><strong>{room.portal.name}</strong><span className={s.gateStatus} data-state={room.portal.state}><i />{portalStates[room.portal.state]}</span></div></div>
          <p className={s.sidebarLabel}>Jullie werkruimte</p>
          <nav className={s.nav} aria-label="Poortkamer navigatie">
            {nav.map(({ key, label, icon: Icon }) => (
              <button
                key={key}
                aria-current={tab === key ? "page" : undefined}
                onClick={() => {
                  setTab(key);
                  setNotice("");
                }}
              >
                <Icon size={20} />
                <span>{label}</span>
                {key === "messages" && unreadMessages > 0 && <b className={s.navBadge} aria-label={`${unreadMessages} ongelezen`}>{unreadMessages > 99 ? "99+" : unreadMessages}</b>}
              </button>
            ))}
          </nav>
          <div className={s.sidebarFoot}><span className={s.sidebarDate}><CalendarDays size={16} />{event.dateShort} · {event.times}</span><Link className={s.sidebarReturn} href={admin ? "/admin" : "/omgeving"}>Mijn omgeving <ArrowRight size={15} /></Link></div>
        </aside>
        <div className={s.workspace}>
          <header className={s.top}>
            <div className={s.topIdentity}>
              <span>Poortteam / {nav.find(item => item.key === tab)?.label}</span>
              <strong>
                {room.portal.name}
              </strong>
              <small>{portalRoles[room.role]}{room.portal.pauseUntil ? ` · Hervat rond ${portalTime(room.portal.pauseUntil)}` : ""}</small>
            </div>
            <div className={`${s.actions} ${s.receptionControls}`} aria-label="Ontvangststatus" data-guide="house-status">
              {canLive && (
                <>
                  <button
                    className={s.button}
                    data-state="open"
                    aria-pressed={room.portal.state === "open"}
                    disabled={disabled}
                    onClick={() => void statusAction("open")}
                  >
                    <DoorOpen size={17} />
                    Open
                  </button>
                  <button
                    className={s.button}
                    data-state="paused"
                    aria-pressed={room.portal.state === "paused"}
                    disabled={disabled}
                    onClick={() => setDialog("pause")}
                  >
                    <Pause size={17} />
                    Pauze
                  </button>
                  <button
                    className={s.button}
                    data-state="closed"
                    aria-pressed={room.portal.state === "closed"}
                    disabled={disabled}
                    onClick={() => setDialog("stop")}
                  >
                    Gestopt
                  </button>
                </>
              )}
            </div>
            <Link className={s.headerReturn} href={admin ? "/admin" : "/omgeving"}>Mijn omgeving</Link>
          </header>
          <main
            ref={contentRef}
            id="poortkamer-content"
            className={`${s.scrollPane} ${tab === "messages" ? s.chatScroll : ""}`}
            tabIndex={-1}
          >
      {tab === "night" && (
        <section className={s.hero}>
          <Image
            className={s.heroImage}
            src="/images/poortkamer-v2/nightwatch-live-hero-wide.webp"
            fill
            sizes="100vw"
            alt=""
            loading="eager"
          />
          <Image
            className={`${s.heroImage} ${s.mobileImage}`}
            src="/images/poortkamer-v2/nightwatch-live-hero-wide.webp"
            fill
            sizes="100vw"
            alt=""
          />
          <div className={s.heroText}>
            <p className={s.eyebrow}>
              {room.portal.world} · {room.portal.code}
            </p>
            <h1>
              {ended
                ? "De nacht leeft voort."
                : days > 0
                  ? "Samen klaar voor de nacht."
                  : "Welkom op de Nachtwacht."}
            </h1>
            <p>De voorbereiding, jullie team en de volgende bezoekers. Alles voor een fijne avond, op één plek.</p>
            <span className={s.badge}>
              {ended
                ? "Dank je wel, Poortwachters"
                : days > 0
                  ? `Nog ${days} nachten tot Halloween`
                  : "De poorten ontwaken vanavond"}
            </span>
          </div>
        </section>
      )}
      <div className={`${s.content} ${tab === "messages" ? s.chatContent : ""}`}>
        {(tab === "messages" || tab === "more") && <h1 className="sr-only">{tab === "messages" ? "Berichten" : "Meer in jullie Poortkamer"}</h1>}
        {tab !== "messages" && <div className={s.pageTools}>
          <p>
            <span className={s.liveDot} />
            {offline
              ? "Offline · laatste bevestigde stand"
              : live
                ? "Live"
                : "Verbinding herstellen…"}
            <small> · Bijgewerkt om {portalTime(room.updatedAt)}</small>
          </p>
          <button className={s.button} aria-label="Vernieuwen" title="Vernieuwen" onClick={() => void load()}>
            <RefreshCw size={16} />
          </button>
        </div>}
        {offline && (
          <p className={`${s.notice} ${s.offline}`} role="alert">
            <WifiOff size={18} /> Je ziet tijdelijk de laatste stand. Er kunnen
            geen wijzigingen worden opgeslagen.
          </p>
        )}
        {room.portals.length > 1 && (
          <label className={`${s.field} ${s.selectPortal}`}>
            Jouw poort
            <select
              value={portalId}
              onChange={(e) => {
                window.location.assign(
                  new URL(
                    `/mijn-huis?poort=${encodeURIComponent(e.target.value)}`,
                    window.location.origin,
                  ).toString(),
                );
                setPortalId(e.target.value);
              }}
            >
              {room.portals.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.code} · {p.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {room.urgentAnnouncement && tab !== "night" && (
          <aside className={s.notice}>
            <strong>De Omroeper · belangrijk</strong>
            <p>{room.urgentAnnouncement.body}</p>
            <button className={s.linkButton} onClick={() => setTab("messages")}>
              Lees mededelingen
            </button>
          </aside>
        )}
        {notice && (
          <p className={s.notice} role="status">
            {notice}
          </p>
        )}
        {tab === "night" && (
          <>
            <div className={s.metrics} data-guide="house-overview" aria-label="De avond in cijfers">
              <Metric value={room.visits.recap.groups} label="Groepen ontvangen" />
              <Metric value={room.visits.recap.children} label="Kinderen ontvangen" />
              <Metric value={metrics.remainingGroups} label="Groepen verwacht" />
              <Metric value={metrics.remainingChildren} label="Kinderen verwacht" />
            </div>
            {ended ? <NightRecap room={room} /> : <div className={s.nightGrid}>
              <section className={`${s.card} ${s.nextArrival}`}>
                <div className={s.sectionTop}><div><p className={s.eyebrow}>De volgende bezoekers</p><h2>{metrics.next ? "Er komt een groep aan" : "Nog even rustig"}</h2></div><span className={s.smallIcon}><Footprints size={21} /></span></div>
                {metrics.next ? <><div className={s.arrivalIdentity}><span className={s.groupCode}>{metrics.next.groupCode}</span><div><strong>{metrics.next.expectedChildren} kinderen</strong><small>{metrics.next.state === "confirmed_start" ? "Bevestigde startgroep" : metrics.next.state === "active" ? "Bestemming vrijgegeven" : "Verwachte groep"}</small></div><span className={s.arrivalTime}>{portalTime(metrics.next.plannedArrivalAt)}<small>tot {portalTime(metrics.next.plannedDepartureAt)}</small></span></div><p className={s.muted}>Dit is een gepland aankomstvenster. Onderweg kan de groep wat eerder of later zijn.</p></> : <p>Er is nog geen volgende groep toegewezen. Zodra jullie bezoekers onderweg zijn, verschijnt hun groep hier.</p>}
                <div className={s.cardAction}><span>{metrics.nextHalfHour} groepen in het komende halfuur</span><button className={`${s.button} ${s.primary}`} onClick={() => setTab("visits")}>Alle bezoeken <ArrowRight size={16} /></button></div>
              </section>
              <section className={`${s.card} ${s.readinessCard}`}>
                <div className={s.sectionTop}><div><p className={s.eyebrow}>Goed voorbereid</p><h2>Jullie zijn al goed op weg</h2></div><span className={s.smallIcon}><ShieldCheck size={21} /></span></div>
                <div className={s.readinessValue}><strong>{metrics.ready}<small>/{readinessItems.length}</small></strong><span>punten afgerond</span></div>
                <progress aria-label="Gereedheid" max={readinessItems.length} value={metrics.ready} />
                <p className={s.muted}>{room.portal.locationVerified ? "Locatie gecontroleerd" : "Locatie wacht op controle"} · {room.portal.opensAt ? `Ontvangst vanaf ${portalTime(room.portal.opensAt)}` : "Openingstijd volgt"}</p>
                <button className={s.linkButton} onClick={() => {setMoreSection("preparation");setPreparationSection("checklist");setTab("more");}}>Bekijk de voorbereiding <ArrowRight size={16} /></button>
              </section>
            </div>}
            <section className="gate-poster-shortcut" data-guide="house-qr-shortcut"><QrCode size={30}/><div><strong>Hang jullie QR-code bij de deur.</strong><p>Download de A4-poster in zwart-wit of kleur. Zo bevestigen groepen hun aankomst en krijgen ze hun volgende bestemming.</p></div><button className="btn" onClick={() => {setMoreSection("qr");setTab("more");}}>QR-code & printen <ArrowRight size={16}/></button></section>
            <nav className={s.quickActions} aria-label="Snel geregeld">
              <button onClick={() => setTab("team")}><span><Users size={21} /></span><strong>Jullie team<small>Rollen en taken verdelen</small></strong><ArrowRight size={17} /></button>
              <button onClick={() => setTab("messages")}><span><MessageCircle size={21} /></span><strong>Berichten<small>{unreadMessages ? `${unreadMessages} ongelezen berichten` : "Spreek elkaar even bij"}</small></strong><ArrowRight size={17} /></button>
              <button onClick={() => {setMoreSection("incident");setTab("more");}}><span><ShieldCheck size={21} /></span><strong>Hulp nodig?<small>Bereik de organisatie</small></strong><ArrowRight size={17} /></button>
            </nav>
            <section className={`${s.card} ${s.organizerUpdates}`} aria-label="Updates van de organisatie">
              <div className={s.sectionTop}><div><p className={s.eyebrow}>Van de organisatie</p><h2>Goed om te weten</h2></div><button type="button" className={s.linkButton} onClick={() => setTab("messages")}>Alle berichten <ArrowRight size={15} /></button></div>
              {(room.announcements ?? []).length ? room.announcements!.map(update => <article key={update.id}><span className={s.updateDot} /><div>{update.urgent && <strong>Belangrijk</strong>}<p>{update.body}</p><time dateTime={update.createdAt}>{new Date(update.createdAt).toLocaleDateString("nl-NL", { day: "numeric", month: "long" })} · {portalTime(update.createdAt)}</time></div></article>) : <p className={s.muted}>Je bent helemaal bij. Nieuwe aanwijzingen van de organisatie verschijnen hier.</p>}
            </section>
            <details className={`${s.card} ${s.liveDetails}`}><summary><span><Footprints size={19} />Bezoeklog en verwachte instroom</span><ChevronRight size={18} /></summary><PoortkamerLiveV2 room={room} /></details>
            <section className={s.shareStrip}><div><p className={s.eyebrow}>Deel de magie</p><strong>Laat jullie poort stralen.</strong><p>Een mooie deelkaart, zonder adres of contactgegevens.</p></div><Link className={s.button} href="/deel-de-magie?from=poortkamer">Maak een deelkaart <ArrowRight size={16} /></Link></section>
          </>
        )}
        {tab === "night" && <><HousePortalThanks key={room.portal.id} portalId={room.portal.id}/><PortalNews channel="houses" compact /></>}
        {tab === "visits" && (
          <section className={s.card} data-guide="house-visits">
            <p className={s.eyebrow}>Voetstappen door jullie poort</p>
            <h1>Bezoeken</h1>
            <p>
              Aankomsttijden zijn geplande vensters. Alleen bevestigde scans
              tellen als ontvangen bezoek.
            </p>
            <div className={s.tabs}>
              {(
                [
                  ["next", "Volgende"],
                  ["expected", "Verwacht"],
                  ["past", "Geweest"],
                ] as const
              ).map(([key, label]) => (
                <button
                  className={s.button}
                  key={key}
                  aria-pressed={visitTab === key}
                  onClick={() => setVisitTab(key)}
                >
                  {label}
                </button>
              ))}
            </div>
            {visitTab === "past" ? (
              room.visits.visits.length ? (
                room.visits.visits.map((v, i) => (
                  <article className={s.row} key={`${v.groupCode}-${i}`}>
                    <div>
                      <h3>{v.groupCode}</h3>
                      <p>{v.children} bevestigde kinderen</p>
                    </div>
                    <time>{portalTime(v.visitedAt)} · Gescand</time>
                  </article>
                ))
              ) : (
                <p className={s.empty}>Er zijn nog geen bevestigde bezoeken.</p>
              )
            ) : (visitTab === "next"
                ? room.visits.arrivals.slice(0, 1)
                : room.visits.arrivals
              ).length ? (
              (visitTab === "next"
                ? room.visits.arrivals.slice(0, 1)
                : room.visits.arrivals
              ).map((a) => (
                <article
                  className={s.row}
                  key={`${a.groupCode}-${a.plannedArrivalAt}`}
                >
                  <div>
                    <h3>{a.groupCode}</h3>
                    <p>
                      {a.expectedChildren} kinderen ·{" "}
                      {a.classification === "forecast"
                        ? "Verwachting"
                        : "Toegewezen"}
                    </p>
                  </div>
                  <time>
                    {portalTime(a.plannedArrivalAt)}–
                    {portalTime(a.plannedDepartureAt)}
                  </time>
                </article>
              ))
            ) : (
              <p className={s.empty}>
                Er is nog geen groep toegewezen. Je hoeft niets te doen.
              </p>
            )}
          </section>
        )}
        {tab === "team" && (
          <>
            <section className={s.card}>
              <Image
                className={s.cardImage}
                src="/images/poortkamer/share-a-key.webp"
                width={720}
                height={540}
                sizes="(max-width:650px) 90vw, 720px"
                alt=""
              />
              <p className={s.eyebrow}>De sleutels tot jullie nacht</p>
              <h1>Jullie Poortwachters</h1>
              <p>
                Eén hoofdpoortwachter, samen verantwoordelijk voor jullie poort.
              </p>
              {manage && (
                <button
                  className={`${s.button} ${s.primary}`}
                  disabled={disabled}
                  onClick={() => setDialog("invite")}
                >
                  <KeyRound size={18} />
                  Deel een sleutel
                </button>
              )}
              {room.team.map((m) => (
                <article className={s.row} key={m.userId}>
                  <div>
                    <h3>
                      {m.name}
                      {m.userId === room.userId ? " (jij)" : ""}
                    </h3>
                    <p>
                      {portalRoles[m.role]}
                      {m.task ? ` · ${m.task}` : ""}
                    </p>
                    <small
                      className={
                        Boolean(m.lastSeenAt && now - Date.parse(m.lastSeenAt) < 90_000) ? s.online : ""
                      }
                    >
                      {Boolean(m.lastSeenAt && now - Date.parse(m.lastSeenAt) < 90_000) ? "Recent actief" : ""}
                      {m.lastSeenAt
                        ? ` · laatst actief ${new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" }).format(new Date(m.lastSeenAt))}`
                        : ""}
                      {m.suspendedAt ? " · tijdelijk gedeactiveerd" : ""}
                    </small>
                  </div>
                  {manage && (
                    <div className={s.actions}>
                      {m.role !== "owner" && (
                        <>
                          <label className={s.field}>
                            Toegangsniveau voor {m.name}
                            <select
                              aria-label={`Toegangsniveau voor ${m.name}`}
                              value={m.accessLevel}
                              disabled={disabled || Boolean(m.suspendedAt)}
                              onChange={(e) =>
                                void command(
                                  "access",
                                  { userId: m.userId, accessLevel: e.target.value },
                                  true,
                                )
                              }
                            >
                              <option value="read">Alleen lezen en chatten</option>
                              <option value="live">Live bediening en voorbereiding</option>
                              <option value="manage">Ook vaste poortgegevens beheren</option>
                            </select>
                          </label>
                          <label className={s.check}>
                            <input type="checkbox" aria-label={`Moderatorrechten voor ${m.name}`} checked={m.chatModerator ?? false} disabled={disabled || Boolean(m.suspendedAt)} onChange={e => void command("chat_moderator", { userId: m.userId, enabled: e.target.checked }, true)} />
                            Moderator in jullie teamchat
                          </label>
                          <button
                            className={s.button}
                            disabled={disabled}
                            onClick={() =>
                              void command(
                                m.suspendedAt ? "reactivate" : "suspend",
                                { userId: m.userId },
                                true,
                              )
                            }
                          >
                            {m.suspendedAt ? "Toegang activeren" : "Tijdelijk deactiveren"}
                          </button>
                          <label className={s.field}>
                            Rol voor {m.name}
                            <select
                              aria-label={`Rol voor ${m.name}`}
                              value={m.role}
                              disabled={disabled}
                              onChange={(e) => {
                                if (
                                  window.confirm(
                                    `Rol van ${m.name} wijzigen naar ${portalRoles[e.target.value as keyof typeof portalRoles]}?`,
                                  )
                                )
                                  void command(
                                    "role",
                                    { userId: m.userId, role: e.target.value },
                                    true,
                                  );
                              }}
                            >
                              {(
                                [
                                  "viewer",
                                  "actor",
                                  "reception",
                                  "tech",
                                  "portal_manager",
                                ] as const
                              ).map(
                                (role) => (
                                  <option value={role} key={role}>
                                    {portalRoles[role]}
                                  </option>
                                ),
                              )}
                            </select>
                          </label>
                          <button
                            className={s.button}
                            disabled={disabled}
                            onClick={() => {
                              if (
                                window.confirm(
                                  `Hoofdpoortwachterschap overdragen aan ${m.name}? De huidige hoofdpoortwachter wordt Mede-beheerder.`,
                                )
                              )
                                void command(
                                  "transfer",
                                  { userId: m.userId },
                                  true,
                                );
                            }}
                          >
                            Overdragen
                          </button>
                          <button
                            className={s.button}
                            disabled={disabled}
                            onClick={() => {
                              if (
                                window.confirm(
                                  `Toegang van ${m.name} direct intrekken?`,
                                )
                              )
                                void command(
                                  "revoke",
                                  { userId: m.userId },
                                  true,
                                );
                            }}
                          >
                            Toegang intrekken
                          </button>
                        </>
                      )}
                      <label className={s.field}>
                        Taak voor {m.name}
                        <select
                          value={m.task ?? ""}
                          disabled={disabled}
                          onChange={(e) =>
                            void command(
                              "task",
                              { userId: m.userId, task: e.target.value },
                              true,
                            )
                          }
                        >
                          <option value="">Geen taak</option>
                          {[
                            "ontvangst",
                            "acteur",
                            "rij/veiligheid",
                            "techniek",
                          ].map((task) => (
                            <option value={task} key={task}>
                              {task}
                            </option>
                          ))}
                        </select>
                      </label>
                    </div>
                  )}
                </article>
              ))}
            </section>
            {manage && (
              <section className={s.card}>
                <h2>Gedeelde sleutels</h2>
                {room.invites.length === 0 ? (
                  <p>Er zijn nog geen uitnodigingen verstuurd.</p>
                ) : (
                  room.invites.map((i) => (
                    <article className={s.row} key={i.id}>
                      <div>
                        <strong>{i.name}</strong>
                        <p>{i.email}</p>
                        <small>
                          {portalRoles[i.role]} · {inviteLabels[i.status]}
                        </small>
                      </div>
                      {["pending", "expired"].includes(i.status) && (
                        <div className={s.actions}>
                          <button
                            className={s.button}
                            disabled={disabled}
                            onClick={() =>
                              void command("resend", { inviteId: i.id }, true)
                            }
                          >
                            Opnieuw versturen
                          </button>
                          <button
                            className={s.button}
                            disabled={disabled}
                            onClick={() =>
                              void command(
                                "revoke_invite",
                                { inviteId: i.id },
                                true,
                              )
                            }
                          >
                            Intrekken
                          </button>
                        </div>
                      )}
                    </article>
                  ))
                )}
              </section>
            )}
            {manage && (
              <section className={s.card}>
                <h2>Toegangsgeschiedenis</h2>
                {room.v2.teamHistory.length === 0 ? (
                  <p>Er zijn nog geen wijzigingen in het huisteam vastgelegd.</p>
                ) : (
                  room.v2.teamHistory.map((entry, index) => (
                    <article className={s.row} key={`${entry.action}-${entry.at}-${index}`}>
                      <div>
                        <strong>{({ invite: "Teamlid uitgenodigd", role: "Rol aangepast", revoke: "Toegang ingetrokken", transfer: "Hoofdpoortwachter gewijzigd", task: "Taak verdeeld", access: "Toegangsniveau aangepast", suspend: "Toegang gepauzeerd", reactivate: "Toegang hersteld", resend: "Uitnodiging opnieuw verstuurd", revoke_invite: "Uitnodiging ingetrokken", chat_moderator: "Chatrechten aangepast" } as Record<string, string>)[entry.action.replace("portal.team.", "")] ?? "Teamgegevens bijgewerkt"}</strong>
                        <small>
                          {new Intl.DateTimeFormat("nl-NL", {
                            dateStyle: "medium",
                            timeStyle: "short",
                          }).format(new Date(entry.at))}
                        </small>
                      </div>
                    </article>
                  ))
                )}
              </section>
            )}
          </>
        )}
        {tab === "messages" && (
          <PoortkamerChat
            room={room}
            disabled={disabled}
            refresh={load}
            admin={admin}
          />
        )}
        {tab === "more" && <nav className={`${s.tabs} ${s.moreTabs}`} aria-label="Meer in De Poortkamer">{[["preparation", "Voorbereiden"], ["qr", "QR & printen"], ["incident", "Hulp & contact"], ["settings", "Instellingen"], ["recap", "Terugblik"]].map(([key, label]) => <button type="button" key={key} className={s.button} aria-pressed={moreSection === key} onClick={() => setMoreSection(key)}>{label}</button>)}</nav>}
        {tab === "more" && (
          <div className={s.moreGrid} data-guide="house-more">
            {moreSection === "qr" && <GatePoster key={room.portal.id} portal={room.portal} canRotate={canEdit} disabled={disabled} onRefresh={load}/> }
            {moreSection === "preparation" && <nav className={`${s.tabs} ${s.subTabs}`} aria-label="Voorbereiden">{[["checklist", "Checklist"], ["presentation", "Presentatie"], ["simulation", "Oefenen"]].map(([key, label]) => <button type="button" key={key} className={s.button} aria-pressed={preparationSection === key} onClick={() => setPreparationSection(key)}>{label}</button>)}</nav>}
            {moreSection !== "qr" && <PoortkamerManagementV2
              section={moreSection === "preparation" ? preparationSection : moreSection}
              room={room}
              busy={busy}
              disabled={disabled}
              canEdit={canEdit}
              command={(operation, payload) => command(operation, payload)}
            />}
            {moreSection === "preparation" && preparationSection === "checklist" &&             <section className={s.card}>
              <Image
                className={s.cardImage}
                src="/images/poortkamer/ready-for-the-night.webp"
                width={720}
                height={540}
                sizes="(max-width:650px) 90vw, 720px"
                alt=""
              />
              <p className={s.eyebrow}>Gedeelde voorbereiding</p>
              <h1>Gereed voor de nacht</h1>
              <div className={s.checks}>
                {readinessItems.map(([key, label]) => {
                  const entry = room.checklist.find((c) => c.item === key);
                  return (
                    <label className={s.check} key={key}>
                      <input
                        type="checkbox"
                        checked={entry?.done ?? false}
                        disabled={disabled || !canLive}
                        onChange={(e) =>
                          void command("checklist", {
                            item: key,
                            done: e.target.checked,
                          })
                        }
                      />
                      <span>
                        {label}
                        {entry && (
                          <small>
                            {entry.changedBy} · {portalTime(entry.changedAt)}
                          </small>
                        )}
                      </span>
                    </label>
                  );
                })}
              </div>
            </section>}
            {moreSection === "settings" && <>
            <Link className={s.button} href="/omgeving/communicatie">Nachtpost en communicatievoorkeuren →</Link>
            <section className={s.card}>
              <h2>
                <Bell size={22} /> Meldingen en app
              </h2>
              <PushNotificationSettings />
              <PwaInstallInvitation userId={room.userId} />
              <button
                className={s.button}
                disabled={disabled}
                onClick={async () => {
                  try {
                    const response = await fetch("/api/poortkamer/push-test", {
                      method: "POST",
                      headers: { "Content-Type": "application/json" },
                      body: JSON.stringify({ portalId: room.portal.id }),
                    });
                    setNotice(
                      response.ok
                        ? "Testmelding verstuurd. Bevestig de gereedcheck wanneer je hem ontvangt."
                        : "Testmelding kon niet worden verstuurd. Zet meldingen eerst aan op dit apparaat.",
                    );
                  } catch {
                    setNotice(
                      "Testmelding niet bevestigd. Controleer je verbinding.",
                    );
                  }
                }}
              >
                <Bell size={16} />
                Test mijn meldingen
              </button>
              {Object.entries(notificationLabels).map(([key, label]) => (
                <label className={s.check} key={key}>
                  <input
                    type="checkbox"
                    checked={
                      room.preferences[key as keyof typeof notificationLabels]
                    }
                    disabled={disabled}
                    onChange={async (e) => {
                      const client = createClient();
                      if (!client) return;
                      const { error } = await client
                        .schema("api")
                        .rpc("portal_notification_preferences_set", {
                          _preferences: {
                            ...room.preferences,
                            [key]: e.target.checked,
                          },
                        });
                      if (error) setNotice(roomError(error.message));
                      await load();
                    }}
                  />
                  {label}
                </label>
              ))}
              <p className={s.muted}>
                Push hangt af van je apparaat, toestemming en netwerk. De
                actuele stand staat altijd in De Poortkamer.
              </p>
            </section>
            <section className={s.card}>
              <h2>Jullie poort</h2>
              <p>{room.portal.name}</p>
              <p>{room.portal.description}</p>
              {canEdit && (
                <div className={s.actions}>
                  <Link className={s.button} href="/deel-de-magie?from=poortprofiel">Deel de magie</Link>
                  <button
                    className={s.button}
                    disabled={disabled}
                    onClick={() => setDialog("details")}
                  >
                    Poortgegevens wijzigen
                  </button>
                  <button
                    className={s.button}
                    disabled={disabled}
                    onClick={() => {setMoreSection("qr");setTab("more");}}
                  >
                    QR-code & printen
                  </button>
                </div>
              )}

            </section>

            <section className={s.card}>
              <ShieldCheck size={24} />
              <h2>Je account</h2>
              <p>
                Alleen actieve Poortwachters zien jullie team. De Praatkamer
                toont buiten jullie team alleen voornaam en poortnaam. Chat
                wordt één maand na het evenement verwijderd.
              </p>
              <SignOutButton />
            </section>
            </>}
            {moreSection === "recap" && <NightRecap room={room} />}
          </div>
        )}
        <p className={s.footerNote}>
          Hulp nodig? Gebruik Hulp & contact voor de organisatie. Bij direct
          gevaar bel je 112.
        </p>
      </div>
          </main>
        </div>
      </div>
      {!admin && tab !== "messages" && (
        <SupportWidget
          eventSlug={eventSlug}
          role="homeowner"
          portalId={room.portal.id}
        />
      )}
      <Dialog
        open={dialog !== null}
        onOpenChange={(open) => {
          if (!open && !busy) setDialog(null);
        }}
      >
        <DialogContent className={s.dialog}>
          <DialogTitle>
            {dialog === "invite"
              ? "Deel een sleutel"
              : dialog === "pause"
                ? "Even op adem komen"
                : dialog === "stop"
                  ? "Poort stoppen"
                  : "Jullie poortgegevens"}
          </DialogTitle>
          <DialogDescription>
            {dialog === "invite"
              ? "Alleen dit geverifieerde e-mailadres kan de sleutel aannemen."
              : dialog === "pause"
                ? "Er vertrekken even geen nieuwe groepen naar jullie poort. Groepen die al onderweg zijn, blijven jullie verwachten."
                : dialog === "stop"
                  ? "De organisatie ziet dat jullie geen nieuwe groepen kunnen ontvangen. Stop alleen als verder ontvangen niet meer mogelijk is."
                  : "Deze wijziging wordt voor jullie poort opgeslagen."}
          </DialogDescription>
          <form
            key={dialog}
            onSubmit={(event) => {
              event.preventDefault();
              const values = new FormData(event.currentTarget);
              if (dialog === "invite")
                void command("invite", Object.fromEntries(values), true);
              else if (dialog === "details")
                void command("details", {
                  ...Object.fromEntries(values),
                  version: room.portal.version,
                });
              else
                void statusAction(
                  dialog === "pause" ? "paused" : "closed",
                  values.get("minutes")
                    ? Number(values.get("minutes"))
                    : undefined,
                  String(values.get("reason")),
                );
            }}
          >
            {dialog === "invite" ? (
              <>
                <label>
                  Voornaam
                  <input
                    name="firstName"
                    required
                    maxLength={80}
                    autoComplete="given-name"
                  />
                </label>
                <label>
                  Achternaam
                  <input
                    name="lastName"
                    required
                    maxLength={100}
                    autoComplete="family-name"
                  />
                </label>
                <label>
                  E-mailadres
                  <input
                    name="email"
                    type="email"
                    required
                    maxLength={254}
                    autoComplete="email"
                  />
                </label>
                <label>
                  Rol
                  <select name="role" aria-label="Rol" defaultValue="viewer">
                    <option value="viewer">Meekijker · lezen en chatten</option>
                    <option value="actor">Acteur · live stand en voorbereiding</option>
                    <option value="reception">Ontvangst · live stand en voorbereiding</option>
                    <option value="tech">Techniek · live stand en voorbereiding</option>
                    <option value="portal_manager">Poortbeheerder · ook vaste poortgegevens</option>
                  </select>
                </label>
                <label>
                  Toegangsniveau
                  <select name="accessLevel" aria-label="Toegangsniveau" defaultValue="read">
                    <option value="read">Alleen lezen en chatten</option>
                    <option value="live">Live bediening en voorbereiding</option>
                    <option value="manage">Ook vaste poortgegevens beheren</option>
                  </select>
                </label>
              </>
            ) : dialog === "details" ? (
              <>
                <label>
                  Poortnaam
                  <input
                    name="name"
                    required
                    minLength={2}
                    maxLength={160}
                    defaultValue={room.portal.name}
                  />
                </label>
                <label>
                  Beschrijving
                  <textarea
                    name="description"
                    maxLength={2000}
                    defaultValue={room.portal.description}
                  />
                </label>
              </>
            ) : (
              <>
                {dialog === "pause" && (
                  <label>
                    Hervatten
                    <select name="minutes" defaultValue="10">
                      {[5, 10, 15, 20, 30].map((minutes) => (
                        <option value={minutes} key={minutes}>
                          Na {minutes} minuten
                        </option>
                      ))}
                      <option value="">Ik hervat handmatig</option>
                    </select>
                  </label>
                )}
                <label>
                  Reden
                  <textarea
                    name="reason"
                    required
                    minLength={5}
                    maxLength={500}
                    defaultValue={
                      dialog === "pause"
                        ? "Even pauze voor ons team"
                        : "Ontvangst is niet meer mogelijk"
                    }
                  />
                </label>
              </>
            )}
            {notice && <p role="alert">{notice}</p>}
            <div className={s.actions}>
              <button
                type="button"
                className={s.button}
                disabled={busy}
                onClick={() => setDialog(null)}
              >
                Annuleren
              </button>
              <button
                type="submit"
                className={`${s.button} ${s.primary}`}
                disabled={disabled}
              >
                {busy
                  ? "Opslaan…"
                  : dialog === "invite"
                    ? "Sleutel versturen"
                    : "Bevestigen"}
              </button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
function Metric({ value, label }: { value: number | string; label: string }) {
  return (
    <div className={s.metric}>
      <strong>{value}</strong>
      <span>{label}</span>
    </div>
  );
}
function NightRecap({ room }: { room: PortalRoom }) {
  const event = useEventDetails();
  const recap = room.visits.recap;
  return (
    <section className={`${s.card} ${s.recap}`}>
      <Image
        className={s.cardImage}
        src="/images/poortkamer-v2/recap-hero-wide.webp"
        width={960}
        height={540}
        sizes="(max-width:650px) 90vw, 960px"
        alt=""
      />
      <p className={s.eyebrow}>Een stukje magie, dankzij jullie</p>
      <h2>Nachtverslag · {room.portal.code}</h2>
      <p>Dank je wel voor jullie licht in de wijk.</p>
      <div className={s.certificate}>
        <img src="/images/poortkamer-v2/certificates/gate-certificate-background.webp" alt="" />
        <div><span>Digitaal certificaat</span><strong>Officiële Poort van {event.year}</strong><small>{room.portal.name} · {room.portal.code}</small></div>
      </div>
      <div className={s.metrics}>
        <Metric value={recap.groups} label="Groepen ontvangen" />
        <Metric value={recap.children} label="Kinderen ontvangen" />
        <Metric value={recap.pauses} label="Pauzes" />
        <Metric value={recap.pauseMinutes} label="Minuten pauze" />
      </div>
      <p>
        Eerste bezoek: {portalTime(recap.firstVisit)} · laatste:{" "}
        {portalTime(recap.lastVisit)}
      </p>
      <p>
        Drukste halfuur: {portalTime(recap.busiestHalfHour)} · gemiddeld{" "}
        {recap.averageGapMinutes ?? "—"} minuten tussen groepen
      </p>
      <Link className={s.button} href="/deel-de-magie?from=poortkamer-terugblik">Deel ons Nachtverslag</Link>
    </section>
  );
}
