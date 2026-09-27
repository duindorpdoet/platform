"use client";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
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
  stockLabels,
  type PortalRoom,
} from "@/lib/domain/poortkamer";
import { shareNightRecap } from "./share-night-recap";
import { PoortkamerChat } from "./poortkamer-chat";
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
  const [tab, setTab] = useState<Tab>("night");
  const [visitTab, setVisitTab] = useState<"next" | "expected" | "past">(
    "next",
  );
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [offline, setOffline] = useState(false);
  const [live, setLive] = useState(false);
  const [onlineMembers, setOnlineMembers] = useState<string[]>([]);
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
    setOnlineMembers([]);
  }, []);
  const load = useCallback(async () => {
    if (document.hidden) return;
    if (!navigator.onLine) {
      setOffline(true);
      setLive(false);
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
      setLive(false);
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
      setLive(false);
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
  useEffect(() => {
    const client = createClient();
    if (!client || !room) return;
    let disposed = false;
    let channel: ReturnType<typeof client.channel> | null = null;
    let community: ReturnType<typeof client.channel> | null = null;
    void (async () => {
      const { data } = await client.auth.getSession();
      if (disposed || !data.session || data.session.user.id !== userId) return;
      await client.realtime.setAuth(data.session.access_token);
      if (disposed) return;
      channel = client
        .channel(room.portalTopic, {
          config: { private: true, presence: { key: userId } },
        })
        .on("broadcast", { event: "snapshot_changed" }, () => void load())
        .on("presence", { event: "sync" }, () =>
          setOnlineMembers(Object.keys(channel?.presenceState() ?? {})),
        )
        .subscribe((status: string) => {
          if (disposed) return;
          setLive(status === "SUBSCRIBED");
          if (status === "SUBSCRIBED") void channel?.track({ userId });
        });
      community = client
        .channel(room.communityTopic, { config: { private: true } })
        .on("broadcast", { event: "snapshot_changed" }, () => void load())
        .subscribe();
    })();
    return () => {
      disposed = true;
      if (channel) void client.removeChannel(channel);
      if (community) void client.removeChannel(community);
    };
    // Topic changes invalidate old membership channels; snapshot updates alone do not reconnect.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [room?.portalTopic, room?.communityTopic, userId, load]);
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
      setNotice("Opgeslagen. Iedereen in jullie team ziet de actuele stand.");
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
            Je sessie of toegang is gewijzigd. Eerdere privégegevens zijn van
            dit scherm verwijderd.
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
    <div className={s.room}>
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
      <div className={s.statusbar}>
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
          {canLive && (
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
            <span>
              {label}
              {key === "messages" &&
              room.channels.reduce((total, c) => total + c.unread, 0) > 0
                ? ` (${room.channels.reduce((total, c) => total + c.unread, 0)})`
                : ""}
            </span>
          </button>
        ))}
      </nav>
      {tab === "night" && (
        <section className={s.hero}>
          <Image
            className={s.heroImage}
            src="/images/poortkamer/nightwatch-hero-wide.webp"
            fill
            sizes="100vw"
            alt=""
            loading="eager"
          />
          <Image
            className={`${s.heroImage} ${s.mobileImage}`}
            src="/images/poortkamer/nightwatch-hero-mobile.webp"
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
      <main id="poortkamer-content" className={s.content}>
        <div className={s.row}>
          <p>
            <span className={s.liveDot} />
            {offline
              ? "Offline · laatste bevestigde stand"
              : live
                ? "Live"
                : "Verbinden · verversen blijft actief"}
            <small> · Bijgewerkt om {portalTime(room.updatedAt)}</small>
          </p>
          <button className={s.button} onClick={() => void load()}>
            <RefreshCw size={16} />
            Vernieuwen
          </button>
        </div>
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
        {room.urgentAnnouncement && (
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
            <div className={s.metrics}>
              <Metric
                value={room.visits.recap.groups}
                label="Groepen ontvangen"
              />
              <Metric
                value={room.visits.recap.children}
                label="Bevestigde kinderen"
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
                        Aankomst kan verschuiven. Dit is de serverplanning, geen
                        live locatie.
                      </p>
                    </>
                  ) : (
                    <p>
                      Er is nog geen volgende groep toegewezen. Zodra de planner
                      een groep bevestigt, verschijnt die hier.
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
                  <h2>{metrics.ready} van 9 voorbereid</h2>
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
                    De planner gebruikt een goedgekeurde, geverifieerde en
                    beschikbare poort die Open staat. Deze gereedcheck is een
                    hulpmiddel en blokkeert Open niet.
                  </p>
                  <progress
                    aria-label="Gereedheid"
                    max={9}
                    value={metrics.ready}
                  />
                  <p>
                    {
                      onlineMembers.filter((id) =>
                        room.team.some((m) => m.userId === id),
                      ).length
                    }{" "}
                    teamleden nu verbonden
                  </p>
                  <button className={s.button} onClick={() => setTab("more")}>
                    <CheckCircle2 size={17} />
                    Gereed voor de nacht
                  </button>
                </section>
              </div>
            )}
            <section className={s.card}>
              <p className={s.eyebrow}>De snoepmeter</p>
              <h2>{stockLabels[room.portal.stock]}</h2>
              <p>
                {metrics.remainingChildren} kinderen in de huidige
                verwachtingen. Dit aantal kan wijzigen.
              </p>
              <div className={s.actions}>
                {Object.entries(stockLabels).map(([key, label]) => (
                  <button
                    key={key}
                    className={s.button}
                    disabled={disabled || !canLive}
                    aria-pressed={room.portal.stock === key}
                    onClick={() => void command("stock", { stock: key })}
                  >
                    {label}
                  </button>
                ))}
              </div>
              {["low", "empty"].includes(room.portal.stock) && (
                <p className={s.notice}>
                  De organisatie ziet jullie lage voorraad in de cockpit.
                </p>
              )}
              {canLive && (
                <button
                  className={s.linkButton}
                  disabled={disabled}
                  onClick={() => {
                    if (
                      window.confirm(
                        "Een hulpvraag met alleen jullie poortcode op het besloten Poortplein plaatsen?",
                      )
                    )
                      void command("help", { shareCommunity: true });
                  }}
                >
                  Vraag het Poortplein om snoephulp
                </button>
              )}
            </section>
          </>
        )}
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
                        onlineMembers.includes(m.userId) ? s.online : ""
                      }
                    >
                      {onlineMembers.includes(m.userId) ? "Online" : "Offline"}
                      {m.lastSeenAt
                        ? ` · laatst actief ${new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" }).format(new Date(m.lastSeenAt))}`
                        : ""}
                    </small>
                  </div>
                  {manage && (
                    <div className={s.actions}>
                      {m.role !== "owner" && (
                        <>
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
                              {(["viewer", "crew", "coadmin"] as const).map(
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
                            "snoep",
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
        {tab === "more" && (
          <div className={s.moreGrid}>
            <section className={s.card}>
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
            </section>
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
            <NightRecap room={room} />
            <section className={s.card}>
              <ShieldCheck size={24} />
              <h2>Jullie besloten omgeving</h2>
              <p>
                Alleen actieve Poortwachters zien jullie team. Het Poortplein
                toont buiten jullie team alleen voornaam en poortnaam. Chat
                wordt één maand na het evenement verwijderd.
              </p>
              <SignOutButton />
            </section>
          </div>
        )}
        <p className={s.footerNote}>
          Hulp nodig? Gebruik Hulp & contact voor de organisatie. Bij direct
          gevaar bel je 112.
        </p>
      </main>
      {!admin && (
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
                ? "Nieuwe toewijzingen stoppen. De bestaande afspraken voor groepen die al onderweg zijn blijven gelden."
                : dialog === "stop"
                  ? "De planner behandelt nog lopende bezoeken volgens het bestaande stopbeleid. Bevestig alleen als ontvangst niet meer mogelijk is."
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
                    <option value="crew">
                      Crew/acteur · ook live status en voorbereiding
                    </option>
                    <option value="coadmin">
                      Mede-beheerder · ook vaste poortgegevens
                    </option>
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
        src="/images/poortkamer/night-recap.webp"
        width={960}
        height={540}
        sizes="(max-width:650px) 90vw, 960px"
        alt=""
      />
      <p className={s.eyebrow}>Een stukje magie, dankzij jullie</p>
      <h2>Nachtverslag · {room.portal.code}</h2>
      <p>Dank je wel voor jullie licht in de wijk.</p>
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
