"use client";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { PortalNews } from "@/components/editorial/portal-news";
import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  Bell,
  CheckCircle2,
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
import { shareNightRecap } from "./share-night-recap";
import { PoortkamerChat } from "./poortkamer-chat";
import { PoortkamerLiveV2, PoortkamerManagementV2 } from "./poortkamer-v2";
import s from "./poortkamer.module.css";

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
  const [room, setRoom] = useState<PortalRoom | null>(initial);
  const [portalId, setPortalId] = useState(initial.portal.id);
  const [moreSection, setMoreSection] = useState("preparation");
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
  const [qr, setQr] = useState<{ image: string; code: string } | null>(null);
  const commandPending = useRef(false);
  const version = useRef(0);
  const userId = initial.userId;
  const clearPrivate = useCallback(() => {
    version.current += 1;
    setRoom(null);
    setQr(null);
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
      setOffline(true);
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
  async function rotateQr() {
    if (
      !room ||
      busy ||
      offline ||
      !window.confirm(
        "Een nieuwe QR-code maakt de vorige direct ongeldig. Nieuwe code maken?",
      )
    )
      return;
    const client = createClient();
    if (!client) return;
    setBusy(true);
    try {
      const { data, error } = await client
        .schema("api")
        .rpc("portal_rotate_credential", {
          _portal_id: room.portal.id,
          _expected_portal_version: room.portal.version,
          _reason: "QR-code vernieuwd in De Poortkamer",
        });
      if (error) {
        setNotice(roomError(error.message));
        return;
      }
      const { default: QRCode } = await import("qrcode");
      setQr({
        image: await QRCode.toDataURL(data.credential, {
          width: 640,
          margin: 3,
        }),
        code: data.shortCode,
      });
    } finally {
      setBusy(false);
      await load();
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
    <div className={`${s.room} ${tab === "messages" ? s.chatMode : ""}`}>
      <header className={s.top}>
        <div className={s.brand}>
          <Image
            src="/images/logo.webp"
            width={140}
            height={90}
            alt="De Duindorpse Poorten van Halloween"
          />
          <div>
            <strong>De Poortkamer</strong>
            <small>Jullie plek achter de poort</small>
          </div>
        </div>
        <Link href={admin ? "/admin" : "/omgeving"}>Mijn omgeving</Link>
      </header>
      <div className={`${s.statusbar} ${tab !== "night" ? s.compactStatus : ""}`}>
        <div>
          <strong>
            {room.portal.code} · {portalStates[room.portal.state]}
          </strong>
          <small> · {portalRoles[room.role]}</small>
          {room.portal.pauseUntil && (
            <small> · Hervat rond {portalTime(room.portal.pauseUntil)}</small>
          )}
        </div>
        <div className={s.actions}>
          {canLive && tab === "night" && (
            <>
              <button
                className={s.button}
                aria-pressed={room.portal.state === "open"}
                disabled={disabled}
                onClick={() => void statusAction("open")}
              >
                <DoorOpen size={17} />
                Open
              </button>
              <button
                className={s.button}
                aria-pressed={room.portal.state === "paused"}
                disabled={disabled}
                onClick={() => setDialog("pause")}
              >
                <Pause size={17} />
                Pauze
              </button>
              <button
                className={s.button}
                aria-pressed={room.portal.state === "closed"}
                disabled={disabled}
                onClick={() => setDialog("stop")}
              >
                Gestopt
              </button>
            </>
          )}
        </div>
      </div>
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
                  ? "De nacht wacht op jullie."
                  : "Welkom op de Nachtwacht."}
            </h1>
            <p>{room.portal.name}</p>
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
      <main id="poortkamer-content" className={`${s.content} ${tab === "messages" ? s.chatContent : ""}`}>
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
            <section className={`${s.card} ${s.organizerUpdates}`} aria-label="Updates van de organisatie">
              <div className={s.row}><div><p className={s.eyebrow}>Van de organisatie</p><h2>Kort bijgepraat</h2></div><button type="button" className={s.linkButton} onClick={() => setTab("messages")}>Alle berichten</button></div>
              {(room.announcements ?? []).length ? room.announcements!.map(update => <article key={update.id}><span className={s.updateDot} /><div>{update.urgent && <strong>Belangrijk</strong>}<p>{update.body}</p><time dateTime={update.createdAt}>{new Date(update.createdAt).toLocaleDateString("nl-NL", { day: "numeric", month: "long" })} · {portalTime(update.createdAt)}</time></div></article>) : <p className={s.muted}>Je bent helemaal bij. Nieuwe aanwijzingen van de organisatie verschijnen hier.</p>}
            </section>
            <div className={s.metrics}>
              <Metric
                value={room.visits.recap.groups}
                label="Groepen ontvangen"
              />
              <Metric
                value={room.visits.recap.children}
                label="Kinderen ontvangen"
              />
              <Metric
                value={metrics.remainingGroups}
                label="Groepen nog verwacht"
              />
              <Metric
                value={metrics.remainingChildren}
                label="Kinderen nog verwacht"
              />
            </div>
            {ended ? (
              <NightRecap room={room} />
            ) : (
              <div className={s.grid}>
                <section className={s.card}>
                  <p className={s.eyebrow}>De volgende voetstappen</p>
                  <h2>
                    {metrics.next
                      ? metrics.next.groupCode
                      : "De wijk maakt zich klaar"}
                  </h2>
                  {metrics.next ? (
                    <>
                      <p>
                        <strong>
                          {metrics.next.expectedChildren} kinderen
                        </strong>{" "}
                        ·{" "}
                        {metrics.next.state === "active"
                          ? "Vrijgegeven groep"
                          : "Gepland venster"}
                      </p>
                      <p>
                        {portalTime(metrics.next.plannedArrivalAt)}–
                        {portalTime(metrics.next.plannedDepartureAt)}
                      </p>
                      <p className={s.muted}>
                        Dit is de verwachte aankomsttijd. Een groep kan onderweg
                        wat eerder of later zijn.
                      </p>
                    </>
                  ) : (
                    <p>
                      Er is nog geen volgende groep bekend. Zodra er een groep
                      naar jullie poort komt, zie je die hier.
                    </p>
                  )}
                  <p>
                    {metrics.nextHalfHour} groepen gepland in het komende
                    halfuur.
                  </p>
                  <button className={s.button} onClick={() => setTab("visits")}>
                    Bekijk de bezoeken
                  </button>
                </section>
                <section className={s.card}>
                  <p className={s.eyebrow}>Samen gereed</p>
                  <h2>{metrics.ready} van {readinessItems.length} voorbereid</h2>
                  <p>
                    {room.portal.locationVerified
                      ? "Locatie gecontroleerd"
                      : "Locatie wacht op verificatie"}{" "}
                    ·{" "}
                    {room.portal.opensAt
                      ? `Beschikbaar vanaf ${portalTime(room.portal.opensAt)}`
                      : "Openingstijd nog niet vastgesteld"}
                  </p>
                  <p>
                    Loop samen de voorbereiding na. Klaar voor bezoek? Zet jullie poort bovenaan op Open.
                  </p>
                  <progress
                    aria-label="Gereedheid"
                    max={readinessItems.length}
                    value={metrics.ready}
                  />
                  <p>
                    {
                      room.team.filter(m => m.lastSeenAt && now - Date.parse(m.lastSeenAt) < 90_000).length
                    }{" "}
                    teamleden recent actief
                  </p>
                  <button className={s.button} onClick={() => setTab("more")}>
                    <CheckCircle2 size={17} />
                    Gereed voor de nacht
                  </button>
                </section>
              </div>
            )}
            <PoortkamerLiveV2 room={room} />
          </>
        )}
        {tab === "night" && <PortalNews channel="houses" compact />}
        {tab === "visits" && (
          <section className={s.card}>
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
        {tab === "more" && <nav className={s.tabs} aria-label="Poortkamer instellingen">{[["preparation", "Voorbereiding"], ["presentation", "Presentatie"], ["incident", "Hulpvraag"], ["simulation", "Oefenen"], ["settings", "Instellingen"], ["recap", "Terugblik"]].map(([key, label]) => <button type="button" key={key} className={s.button} aria-pressed={moreSection === key} onClick={() => setMoreSection(key)}>{label}</button>)}</nav>}
        {tab === "more" && (
          <div className={s.moreGrid}>
            <PoortkamerManagementV2
              section={moreSection}
              room={room}
              busy={busy}
              disabled={disabled}
              canEdit={canEdit}
              command={(operation, payload) => command(operation, payload)}
            />
            {moreSection === "preparation" &&             <section className={s.card}>
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
                    onClick={() => void rotateQr()}
                  >
                    QR-code vernieuwen
                  </button>
                </div>
              )}
              {qr && (
                <div>
                  <Image
                    src={qr.image}
                    alt="Nieuwe QR-code voor jullie poort"
                    width={280}
                    height={280}
                    unoptimized
                  />
                  <p>
                    Bezoekcode: <strong>{qr.code}</strong>
                  </p>
                  <a
                    className={s.button}
                    href={qr.image}
                    download="poort-bezoekcode.png"
                  >
                    Download QR
                  </a>
                  <button className={s.button} onClick={() => setQr(null)}>
                    Verwijder van scherm
                  </button>
                  <p>Alleen nu zichtbaar. Bewaar de code veilig.</p>
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
      </main>
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
        <div><span>Digitaal certificaat</span><strong>Officiële Poort van 2026</strong><small>{room.portal.name} · {room.portal.code}</small></div>
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
      <button
        className={s.button}
        onClick={async () => {
          try {
            await shareNightRecap(room);
          } catch {
            window.alert(
              "De kaart kon niet worden gemaakt. Probeer het nogmaals.",
            );
          }
        }}
      >
        Deel ons Nachtverslag
      </button>
    </section>
  );
}
