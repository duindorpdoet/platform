"use client";
/* eslint-disable @next/next/no-html-link-for-pages -- Private child pages deliberately reload to validate the cookie and discard the previous child snapshot. */
import { useCallback, useEffect, useRef, useState } from "react";
import {
  ArrowDown,
  ArrowRight,
  ArrowUp,
  BookOpen,
  Check,
  ChevronRight,
  DoorOpen,
  Flame,
  Home,
  KeyRound,
  LockKeyhole,
  Moon,
  RefreshCw,
  Shield,
  Sparkles,
  Star,
  Sun,
  Users,
  Volume2,
  VolumeX,
  X,
} from "lucide-react";
import { MotionToggle } from "@/components/poorten-cinematic";
import {
  checklistLabels,
  comingSoon,
  nightsUntil,
  prologue,
  rankedChoices,
  type BookSection,
  type BookSnapshot,
  type Election,
} from "@/lib/poortenboek/model";

const symbols = [Moon, Flame, Star, KeyRound, Sun, Shield];
const statusText = {
  preparing: "Nog voorbereiden",
  ready: "Klaar voor vertrek",
  underway: "Onderweg",
  completed: "Avond voltooid",
};
const sections = [
  ["nu", "Nu", Home, "/poortenboek"],
  ["team", "Team", Users, "/poortenboek/team"],
  ["boek", "Mijn boek", BookOpen, "/poortenboek/boek"],
  ["ik", "Ik", Moon, "/poortenboek/ik"],
] as const;
function Medallion({
  value,
  small = false,
}: {
  value: number;
  small?: boolean;
}) {
  const Icon = symbols[value % symbols.length];
  return (
    <span className={`pb-medallion ${small ? "small" : ""}`} aria-hidden="true">
      <Icon />
    </span>
  );
}
const dateTime = (date: string) =>
  new Intl.DateTimeFormat("nl-NL", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "Europe/Amsterdam",
  }).format(new Date(date));

export function Poortenboek({
  initial,
  section,
}: {
  initial: BookSnapshot;
  section: BookSection;
}) {
  const [snapshot, setSnapshot] = useState<BookSnapshot | null>(initial);
  const [offline, setOffline] = useState(false);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const pending = useRef(false);
  const sequence = useRef(0);
  const load = useCallback(async () => {
    if (document.hidden) return;
    const current = ++sequence.current;
    try {
      const result = await fetch("/api/poortenboek/snapshot", {
        cache: "no-store",
      });
      if (current !== sequence.current) return;
      if (result.status === 401) {
        setSnapshot(null);
        window.location.replace("/poortenboek/inloggen");
        return;
      }
      if (!result.ok) throw new Error("offline");
      const data = (await result.json()) as BookSnapshot;
      if (current !== sequence.current) return;
      setSnapshot(data);
      setOffline(false);
      document.documentElement.removeAttribute("data-pb-hidden");
    } catch {
      if (current === sequence.current) {
        setSnapshot(null);
        setOffline(true);
        document.documentElement.removeAttribute("data-pb-hidden");
      }
    }
  }, []);
  useEffect(() => {
    const hide = () => {
      sequence.current++;
      document.documentElement.dataset.pbHidden = "true";
      setSnapshot(null);
    };
    const visible = () => {
      if (document.hidden) hide();
      else void load();
    };
    const lost = () => {
      sequence.current++;
      setSnapshot(null);
      setOffline(true);
      document.documentElement.removeAttribute("data-pb-hidden");
    };
    const refresh = () => void load();
    window.addEventListener("pagehide", hide);
    window.addEventListener("pageshow", refresh);
    window.addEventListener("online", refresh);
    window.addEventListener("offline", lost);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", visible);
    const timer = window.setInterval(() => {
      setNow(Date.now());
      if (section === "team" && !document.hidden) void load();
    }, 12_000);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("pagehide", hide);
      window.removeEventListener("pageshow", refresh);
      window.removeEventListener("online", refresh);
      window.removeEventListener("offline", lost);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", visible);
      document.documentElement.removeAttribute("data-pb-hidden");
    };
  }, [load, section]);
  useEffect(() => {
    if (!offline) return;
    // The browser can announce "online" just before its worker reconnects.
    // Keep the neutral screen until a fresh, authorized response succeeds.
    const retry = window.setInterval(() => {
      if (navigator.onLine) void load();
    }, 1500);
    return () => window.clearInterval(retry);
  }, [offline, load]);
  useEffect(() => {
    if (!snapshot) return;
    const timer = window.setTimeout(
      () => {
        setSnapshot(null);
        window.location.replace("/poortenboek/inloggen");
      },
      Math.max(0, new Date(snapshot.expiresAt).getTime() - Date.now()),
    );
    return () => window.clearTimeout(timer);
  }, [snapshot]);
  const act = useCallback(
    async (action: string, payload: Record<string, unknown> = {}) => {
      if (pending.current) return;
      pending.current = true;
      setBusy(true);
      setNotice("");
      const current = ++sequence.current;
      if (action === "checklist")
        setSnapshot((current) =>
          current
            ? { ...current, checklist: payload.values as boolean[] }
            : null,
        );
      try {
        const result = await fetch(`/api/poortenboek/${action}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          cache: "no-store",
          body: JSON.stringify(payload),
        });
        const data = await result.json();
        if (current !== sequence.current || document.hidden) {
          if (!document.hidden && navigator.onLine) await load();
          return;
        }
        if (result.status === 401) {
          setSnapshot(null);
          window.location.replace("/poortenboek/inloggen");
          return;
        }
        if (!result.ok) {
          setNotice(data.error ?? "Dat lukte even niet.");
          await load();
          return;
        }
        if (action === "logout") {
          setSnapshot(null);
          window.location.replace("/poortenboek/inloggen");
          return;
        }
        setSnapshot(data as BookSnapshot);
        setOffline(false);
      } catch {
        if (current === sequence.current && !document.hidden) {
          setSnapshot(null);
          setOffline(true);
        }
      } finally {
        pending.current = false;
        setBusy(false);
      }
    },
    [load],
  );
  if (!snapshot)
    return (
      <main id="poortenboek-content" className="pb-neutral">
        <Moon />
        <h1>
          {offline ? "De verbinding rust even" : "Jouw Poortenboek ophalen…"}
        </h1>
        <p>
          {offline
            ? "Maak verbinding om veilig verder te gaan. Je avontuur blijft bewaard."
            : "Een ogenblik geduld."}
        </p>
        <button className="pb-button" onClick={() => void load()}>
          <RefreshCw />
          Opnieuw proberen
        </button>
      </main>
    );
  if (snapshot.welcomeRequired)
    return (
      <Welcome
        snapshot={snapshot}
        busy={busy}
        open={() => void act("welcome")}
      />
    );
  const ready = snapshot.checklist.filter(Boolean).length;
  return (
    <div className="pb-app">
      <header className="pb-header">
        <a href="/poortenboek" aria-label="Het Poortenboek, naar Nu">
          <img
            src="/images/logo.webp"
            alt="De Duindorpse Poorten van Halloween"
            width="124"
            height="54"
          />
          <span>Het Poortenboek</span>
        </a>
        <nav aria-label="Poortenboek desktop">
          {sections.map(([key, label, Icon, href]) => (
            <a
              key={key}
              href={href}
              aria-current={section === key ? "page" : undefined}
            >
              <Icon size={17} />
              {label}
            </a>
          ))}
        </nav>
        {snapshot.demo && (
          <span className="pb-demo-badge">
            <Sparkles size={13} />
            Demomodus
          </span>
        )}
      </header>
      <main id="poortenboek-content" className="pb-content">
        {notice && (
          <p role="status" className="pb-error">
            {notice}
          </p>
        )}
        {section === "nu" && (
          <>
            <section className="pb-hero">
              <picture>
                <source
                  media="(max-width: 600px)"
                  srcSet="/images/poortenboek/dashboard-night-mobile.webp"
                />
                <img src="/images/poortenboek/dashboard-night.webp" alt="" />
              </picture>
              <div className="pb-hero-copy">
                <p className="pb-eyebrow">Welkom terug, {snapshot.firstName}</p>
                <h1>
                  {["live", "paused"].includes(snapshot.eventPhase)
                    ? "De poorten zijn wakker"
                    : snapshot.eventPhase === "completed"
                      ? "Een nacht om te bewaren"
                      : "De wijk wordt wakker"}
                </h1>
                <p>Jouw verhaal wacht achter de poorten.</p>
                <div className="pb-countdown">
                  <Moon />
                  <span>
                    Nog <strong>{nightsUntil(snapshot.eventDate, now)}</strong>{" "}
                    nachten
                  </span>
                  <small>tot 31 oktober 2026</small>
                </div>
                <a
                  className="pb-button"
                  href={
                    snapshot.election.winner
                      ? "#voorbereiding"
                      : "/poortenboek/team"
                  }
                >
                  {snapshot.election.winner
                    ? "Bereid je voor op de poorten"
                    : "Kies jouw favoriete teamnamen"}
                  <ArrowRight size={18} />
                </a>
              </div>
              <span className="pb-hero-caption">
                Duindorp · Eén nacht, jouw avontuur
              </span>
            </section>
            <div className="pb-dashboard-grid">
              <section className="pb-panel">
                <div className="pb-section-heading">
                  <div>
                    <p className="pb-eyebrow">Jullie avontuur</p>
                    <h2>Jouw reisgenootjes</h2>
                  </div>
                  <a
                    href="/poortenboek/team"
                    aria-label="Bekijk al jouw reisgenootjes"
                  >
                    <ArrowRight />
                  </a>
                </div>
                <p>Jullie trekken samen door de poorten van Duindorp.</p>
                <Companions companions={snapshot.companions} compact />
                <p className="pb-team-progress">
                  {snapshot.election.winner
                    ? `Jullie zijn ${snapshot.election.winner}!`
                    : `${snapshot.election.votedCount} van de ${snapshot.election.eligibleCount} reisgenootjes hebben gekozen`}
                </p>
              </section>
              <section className="pb-panel pb-start">
                <span className="pb-medallion small">
                  <DoorOpen />
                </span>
                <p className="pb-eyebrow">De eerste stap</p>
                <h2>
                  {snapshot.start
                    ? "Jouw startafspraak"
                    : "Waar begint de tocht?"}
                </h2>
                {snapshot.start ? (
                  <>
                    <strong>{snapshot.start.name}</strong>
                    <p>{dateTime(snapshot.start.startsAt)}</p>
                  </>
                ) : (
                  <p>
                    De organisatie legt jullie startafspraak klaar. Zodra die
                    bekendgemaakt is, vind je hem hier.
                  </p>
                )}
                <span className="pb-chip">
                  {snapshot.start ? "Gepubliceerd" : "Nog even geheim"}
                </span>
              </section>
            </div>
            <section className="pb-preparation pb-panel" id="voorbereiding">
              <div className="pb-preparation-art">
                <img
                  src="/images/poortenboek/preparation-chamber.webp"
                  alt="Een lantaarn en tas liggen klaar voor het avontuur"
                  loading="lazy"
                />
              </div>
              <div>
                <p className="pb-eyebrow">
                  Voorbereidingskamer · {ready} van 6 klaar
                </p>
                <h2>Klaar voor de nacht?</h2>
                <p>
                  Leg je spullen klaar. Een klein beetje voorbereiding maakt
                  ruimte voor een groot avontuur.
                </p>
                <progress
                  aria-label="Jouw voorbereiding"
                  value={ready}
                  max={6}
                />
                <div className="pb-checklist">
                  {checklistLabels.map((label, index) => (
                    <label key={label}>
                      <input
                        type="checkbox"
                        checked={snapshot.checklist[index]}
                        disabled={busy}
                        onChange={(event) =>
                          void act("checklist", {
                            values: snapshot.checklist.map((value, i) =>
                              index === i ? event.target.checked : value,
                            ),
                          })
                        }
                      />
                      <span>{label}</span>
                    </label>
                  ))}
                </div>
                {ready === 6 && (
                  <p className="pb-success" role="status">
                    <Check />
                    Je bent klaar om de poorten tegemoet te gaan.
                  </p>
                )}
                <p className="pb-small">
                  Dit is jouw persoonlijke voorbereiding. Je groepsleider
                  controleert tijdens de avond wie er aanwezig is. Deze lijst
                  verandert je deelname, betaling of route niet.
                </p>
              </div>
            </section>
            <section className="pb-prologue pb-panel">
              <p className="pb-eyebrow">Proloog · de nacht die op jou wacht</p>
              <h2>Er beweegt iets achter de poorten…</h2>
              <p>{prologue}</p>
              <a className="pb-text-link" href="/poortenboek/boek">
                Open jouw boek <ArrowRight size={17} />
              </a>
            </section>
            <a className="pb-book-invitation" href="/poortenboek/boek">
              <img
                src="/images/poortenboek/book-cover.webp"
                alt=""
                loading="lazy"
              />
              <div>
                <p className="pb-eyebrow">Alleen van jou</p>
                <h2>
                  Het Poortenboek
                  <br />
                  van {snapshot.firstName}
                </h2>
                <p>
                  De eerste bladzijden wachten. De rest wordt tijdens jouw tocht
                  wakker.
                </p>
                <span className="pb-text-link">
                  Bekijk mijn boek <ArrowRight size={17} />
                </span>
              </div>
            </a>
            <Teasers />
          </>
        )}
        {section === "team" && (
          <>
            <section className="pb-team-hero">
              <img src="/images/poortenboek/team-chamber.webp" alt="" />
              <div>
                <p className="pb-eyebrow">De teamkamer</p>
                <h1>
                  Een nacht.
                  <br />
                  <em>Jullie naam.</em>
                </h1>
                <p>
                  Iedere reisgenoot heeft een vonk. Samen geven jullie het
                  avontuur een naam.
                </p>
              </div>
            </section>
            <section className="pb-panel">
              <p className="pb-eyebrow">Samen door Duindorp</p>
              <h2>Jouw reisgenootjes</h2>
              <p>Jullie trekken samen door de poorten van Duindorp.</p>
              <Companions companions={snapshot.companions} />
              <p className="pb-small">
                {
                  snapshot.companions.filter(
                    (member) => member.status === "preparing",
                  ).length
                }{" "}
                reisgenootjes bereiden hun Poortenboek nog voor.
              </p>
            </section>
            <ElectionCard
              key={`${snapshot.election.id}-${snapshot.election.phase}`}
              election={snapshot.election}
              busy={busy}
              vote={(choices, requestId) =>
                void act("vote", {
                  choices,
                  requestId,
                  electionId: snapshot.election.id,
                  round: snapshot.election.phase,
                })
              }
            />
            <Teasers />
          </>
        )}
        {section === "boek" && (
          <>
            <div className="pb-page-title">
              <p className="pb-eyebrow">Bewaar het ongewone</p>
              <h1>Mijn Poortenboek</h1>
              <p>Deze bladzijden worden tijdens jouw tocht wakker.</p>
            </div>
            <div className="pb-book-spread">
              <div className="pb-book-cover">
                <img
                  src="/images/poortenboek/book-cover.webp"
                  alt="Een gebonden boek met metalen hoeken en een lichtgevende poort"
                />
                <div>
                  <span>Het Poortenboek</span>
                  <h2>{snapshot.firstName}</h2>
                  {snapshot.election.winner && (
                    <p>{snapshot.election.winner}</p>
                  )}
                  <small>Duindorp · Halloween 2026</small>
                </div>
              </div>
              <section className="pb-parchment">
                <span>✦</span>
                <p className="pb-eyebrow">Het begin van jouw verhaal</p>
                <h2>
                  Als Duindorp
                  <br />
                  wakker wordt
                </h2>
                <p>{prologue}</p>
                <p className="pb-handwritten">
                  De volgende bladzijde is voor jou.
                </p>
              </section>
            </div>
            <section className="pb-panel pb-seals">
              <p className="pb-eyebrow">Sporen van jouw tocht</p>
              <h2>Jouw poortzegels</h2>
              {snapshot.unlocks.length ? (
                <ul>
                  {snapshot.unlocks.map((unlock, index) => (
                    <li key={index}>
                      <Sparkles />
                      {unlock.world ?? "Een herinnering aan de nacht"}
                    </li>
                  ))}
                </ul>
              ) : (
                <p>
                  Iedere bezochte poort kan een herinnering achterlaten. Hier
                  ontstaat tijdens jouw avontuur vanzelf ruimte voor jouw
                  zegels.
                </p>
              )}
            </section>
            <Worlds snapshot={snapshot} />
            <Teasers />
          </>
        )}
        {section === "ik" && (
          <>
            <div className="pb-page-title">
              <p className="pb-eyebrow">Jouw plek in het verhaal</p>
              <h1>Ik ben {snapshot.firstName}</h1>
            </div>
            <section className="pb-panel pb-profile">
              <Medallion value={snapshot.medallion} />
              <h2>{snapshot.firstName}</h2>
              <p>
                {snapshot.election.winner ??
                  "Jullie teamnaam wordt nog gekozen"}
              </p>
              <div className="pb-settings">
                <div>
                  <strong>Beweging</strong>
                  <p>
                    Jouw apparaatvoorkeur voor minder beweging gaat altijd voor.
                  </p>
                  <MotionToggle inline />
                </div>
                <div>
                  <strong>Geluid</strong>
                  <p>
                    Geluid staat standaard uit. Je mist geen informatie als het
                    uit staat.
                  </p>
                  <button
                    className="pb-button secondary"
                    aria-pressed={snapshot.soundEnabled}
                    disabled={busy}
                    onClick={() =>
                      void act("sound", { enabled: !snapshot.soundEnabled })
                    }
                  >
                    {snapshot.soundEnabled ? <Volume2 /> : <VolumeX />}
                    {snapshot.soundEnabled ? "Geluid aan" : "Geluid uit"}
                  </button>
                </div>
              </div>
              <div className="pb-session">
                <LockKeyhole />
                <div>
                  <strong>Je bent ingelogd in jouw Poortenboek.</strong>
                  <p>
                    Jouw boek blijft open tot {dateTime(snapshot.expiresAt)}.
                    Daarna kun je opnieuw je code gebruiken.
                  </p>
                </div>
              </div>
              <button
                className="pb-button secondary"
                disabled={busy}
                onClick={() => void act("logout")}
              >
                <DoorOpen />
                Poortenboek sluiten
              </button>
              <p className="pb-small">
                Je Poortenboek laat alleen jouw avontuur en je bevestigde
                reisgenootjes zien.
              </p>
            </section>
          </>
        )}
        <p className="pb-updated">
          Bijgewerkt om{" "}
          {new Intl.DateTimeFormat("nl-NL", {
            hour: "2-digit",
            minute: "2-digit",
            timeZone: "Europe/Amsterdam",
          }).format(new Date(snapshot.updatedAt))}
        </p>
        {snapshot.demo && (
          <details className="pb-demo-panel">
            <summary>
              <Sparkles size={15} />
              Demobediening · fictieve gegevens
            </summary>
            <div>
              {(
                [
                  ["empty", "Nog niemand gestemd"],
                  ["three", "Drie van de vijf gestemd"],
                  ["all", "Allemaal gestemd"],
                  ["finalists", "Finalisten bekend"],
                  ["winner", "Definitieve teamnaam bekend"],
                  ["prepared", "Voorbereiding voltooid"],
                ] as const
              ).map(([phase, label]) => (
                <button
                  type="button"
                  disabled={busy}
                  key={phase}
                  onClick={() => void act("demo-phase", { phase })}
                >
                  {label}
                </button>
              ))}
            </div>
            <p>
              Deze bediening verandert uitsluitend deze demo. Er worden geen
              echte inschrijvingen, stemmen of kindersessies opgeslagen.
            </p>
          </details>
        )}
      </main>
      <nav className="pb-bottomnav" aria-label="Poortenboek navigatie">
        {sections.map(([key, label, Icon, href]) => (
          <a
            key={key}
            href={href}
            aria-current={section === key ? "page" : undefined}
          >
            <Icon size={21} />
            <span>{label}</span>
          </a>
        ))}
      </nav>
    </div>
  );
}

function Welcome({
  snapshot,
  open,
  busy,
}: {
  snapshot: BookSnapshot;
  open: () => void;
  busy: boolean;
}) {
  const openRef = useRef(open);
  useEffect(() => {
    openRef.current = open;
  }, [open]);
  useEffect(() => {
    const timer = window.setTimeout(() => openRef.current(), 4500);
    return () => window.clearTimeout(timer);
  }, []);
  return (
    <main id="poortenboek-content" className="pb-welcome">
      <img src="/images/poortenboek/welcome-gate.webp" alt="" />
      <div className="pb-opening-doors" aria-hidden="true">
        <i />
        <i />
      </div>
      {snapshot.demo && <span className="pb-demo-badge">Demomodus</span>}
      <div className="pb-welcome-copy">
        <p className="pb-eyebrow">Een boek. Een naam. Een avontuur.</p>
        <h1>Welkom, {snapshot.firstName}!</h1>
        <p>
          Jouw Poortenboek is gevonden. De wijk slaapt nog, maar achter de
          eerste poorten begint al iets te bewegen…
        </p>
        <button className="pb-button" disabled={busy} onClick={open}>
          Open mijn boek <ArrowRight size={18} />
        </button>
        <MotionToggle inline />
      </div>
    </main>
  );
}
function Companions({
  companions,
  compact = false,
}: {
  companions: BookSnapshot["companions"];
  compact?: boolean;
}) {
  return (
    <ul className={`pb-companions ${compact ? "compact" : ""}`}>
      {companions.map((member, index) => (
        <li key={`${member.firstName}-${index}`}>
          <Medallion value={member.medallion} small />
          <strong>{member.firstName}</strong>
          <span>{statusText[member.status]}</span>
        </li>
      ))}
    </ul>
  );
}
function ElectionCard({
  election,
  busy,
  vote,
}: {
  election: Election;
  busy: boolean;
  vote: (choices: string[], requestId: string) => void;
}) {
  const [choices, setChoices] = useState(election.ownChoices);
  const attempt = useRef({ body: "", key: "" });
  const required = election.phase === "round_one" ? 3 : 1;
  if (election.winner)
    return (
      <section className="pb-panel pb-winner">
        <span className="pb-medallion">
          <Sparkles />
        </span>
        {election.magicTiebreak && (
          <p className="pb-eyebrow">De Magische Poort kiest…</p>
        )}
        <h2>
          Jullie zijn
          <br />
          <em>{election.winner}!</em>
        </h2>
        <p>Neem jullie naam mee. De nacht wacht op jullie.</p>
        <a className="pb-button" href="/poortenboek/boek">
          Bekijk jullie naam op mijn boek <BookOpen size={18} />
        </a>
      </section>
    );
  function choose(id: string) {
    setChoices((current) =>
      current.includes(id)
        ? current.filter((value) => value !== id)
        : required === 1
          ? [id]
          : current.length < 3
            ? [...current, id]
            : current,
    );
  }
  function move(index: number, direction: number) {
    setChoices((current) => {
      const next = [...current];
      [next[index], next[index + direction]] = [
        next[index + direction],
        next[index],
      ];
      return next;
    });
  }
  return (
    <section
      className={`pb-panel pb-election ${election.phase === "round_two" ? "finalists" : ""}`}
    >
      <p className="pb-eyebrow">
        {election.phase === "direct"
          ? "Jouw naam voor de nacht"
          : election.phase === "round_one"
            ? "Ronde één · drie stemvonken"
            : "Ronde twee · de laatste drie"}
      </p>
      <h2>
        {election.phase === "round_two"
          ? "Drie namen hebben de poort bereikt…"
          : election.phase === "direct"
            ? "Welke naam neem jij mee?"
            : "Geef jullie naam een vonk"}
      </h2>
      <p>
        {required === 3
          ? "Kies drie verschillende namen. Jouw eerste keuze krijgt 3 vonken, de tweede 2 en de derde 1. Je kunt nog veranderen zolang deze ronde open is."
          : "Kies de naam die het beste bij jullie avontuur past."}
      </p>
      <p className="pb-team-progress">
        {election.votedCount} van de {election.eligibleCount} reisgenootjes
        hebben gekozen
      </p>
      <progress
        value={election.votedCount}
        max={election.eligibleCount}
        aria-label="Voortgang teamnaamverkiezing"
      />
      {!election.open ? (
        <p role="status">
          Er zijn nog niet genoeg stemmen voor een teamnaam. De ronde is
          gesloten; je ouder kan de organisatie om hulp vragen.
        </p>
      ) : (
        <>
          <div className="pb-name-options">
            {election.options.map((option) => {
              const rank = choices.indexOf(option.id);
              return (
                <button
                  type="button"
                  key={option.id}
                  aria-pressed={rank >= 0}
                  disabled={
                    busy ||
                    (rank < 0 && choices.length === required && required > 1)
                  }
                  onClick={() => choose(option.id)}
                >
                  <span>{rank >= 0 ? rank + 1 : <Flame size={17} />}</span>
                  {option.label}
                  {rank >= 0 && <Check size={17} />}
                </button>
              );
            })}
          </div>
          {choices.length > 0 && (
            <div className="pb-own-choices">
              <h3>Jouw {required === 3 ? "stemvonken" : "keuze"}</h3>
              <ol>
                {rankedChoices(choices).map(({ id, sparks }, index) => (
                  <li key={id}>
                    <span>
                      <strong>
                        {
                          election.options.find((option) => option.id === id)
                            ?.label
                        }
                      </strong>
                      {required === 3 && (
                        <small>
                          {sparks} {sparks === 1 ? "vonk" : "vonken"}
                        </small>
                      )}
                    </span>
                    {required === 3 && (
                      <>
                        <button
                          disabled={busy || index === 0}
                          aria-label={`Keuze ${index + 1} omhoog`}
                          onClick={() => move(index, -1)}
                        >
                          <ArrowUp size={17} />
                        </button>
                        <button
                          disabled={busy || index === choices.length - 1}
                          aria-label={`Keuze ${index + 1} omlaag`}
                          onClick={() => move(index, 1)}
                        >
                          <ArrowDown size={17} />
                        </button>
                      </>
                    )}
                    <button
                      disabled={busy}
                      aria-label={`Verwijder keuze ${index + 1}`}
                      onClick={() => choose(id)}
                    >
                      <X size={17} />
                    </button>
                  </li>
                ))}
              </ol>
            </div>
          )}
          <button
            className="pb-button"
            disabled={busy || choices.length !== required}
            onClick={() => {
              const body = choices.join(",");
              if (attempt.current.body !== body || !attempt.current.key)
                attempt.current = { body, key: crypto.randomUUID() };
              vote(choices, attempt.current.key);
            }}
          >
            {election.ownChoices.length
              ? "Mijn keuze aanpassen"
              : required === 3
                ? "Verstuur mijn drie vonken"
                : "Verstuur mijn keuze"}
            <Sparkles size={18} />
          </button>
          {election.ownChoices.length > 0 && (
            <p className="pb-success" role="status">
              <Check />
              Jouw keuze is bewaard. Alleen jij kunt jouw stemkeuzes zien.
            </p>
          )}
        </>
      )}
      <p className="pb-small">
        Deze ronde sluit zodra iedereen heeft gekozen, of op{" "}
        {dateTime(election.deadline)}.
      </p>
    </section>
  );
}
function Teasers() {
  return (
    <section className="pb-teasers">
      <div className="pb-section-heading">
        <div>
          <p className="pb-eyebrow">Er komt meer achter de poorten</p>
          <h2>Het avontuur groeit</h2>
        </div>
        <Sparkles />
      </div>
      <div>
        {comingSoon.map((feature) => (
          <article
            className="pb-teaser"
            key={feature.id}
            data-feature-status={feature.status}
          >
            <img
              src={`/images/poortenboek/${feature.image}.webp`}
              alt=""
              loading="lazy"
            />
            <div>
              <span className="pb-chip">
                <LockKeyhole size={13} />
                Binnenkort beschikbaar
              </span>
              <h3>{feature.title}</h3>
              <p>{feature.text}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}
function Worlds({ snapshot }: { snapshot: BookSnapshot }) {
  return (
    <section className="pb-worlds">
      <div className="pb-section-heading">
        <div>
          <p className="pb-eyebrow">Hoofdstukken achter gesloten deuren</p>
          <h2>Werelden die op je wachten</h2>
        </div>
        <LockKeyhole />
      </div>
      <div className="pb-world-art">
        <img
          src="/images/poortenboek/locked-worlds.webp"
          alt="Verschillende lichtgevende poorten boven een opengeslagen boek"
          loading="lazy"
        />
        <p>Elke wereld bewaart een ander verhaal.</p>
      </div>
      <div className="pb-world-grid">
        {snapshot.worlds.map((world) => (
          <article className="pb-panel" key={world.slug}>
            <LockKeyhole size={19} />
            <h3>{world.name}</h3>
            <p>{world.story}</p>
            <span className="pb-small">
              Dit hoofdstuk slaapt nog <ChevronRight size={12} />
            </span>
          </article>
        ))}
      </div>
    </section>
  );
}
