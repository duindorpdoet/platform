"use client";

import { useId, useMemo, useRef, useState } from "react";
import Link from "next/link";
import {
  BookOpen,
  Check,
  Download,
  Flame,
  KeyRound,
  LockKeyhole,
  Shield,
  Sparkles,
} from "lucide-react";
import type { BookSnapshot } from "@/lib/poortenboek/model";
import {
  avatarOptions,
  bannerOptionLabels,
  lanternColors,
  lanternShapes,
  storyChapters,
  type BannerCategory,
  type BannerChoices,
} from "@/lib/poortenboek/v2";

type Act = (action: string, payload?: Record<string, unknown>) => void;

const avatarImage = (id: string) =>
  `/images/poortenboek-v2/avatars/${id}.webp`;

export function TeamIdentityWorkshop({
  snapshot,
  busy,
  act,
}: {
  snapshot: BookSnapshot;
  busy: boolean;
  act: Act;
}) {
  const [avatarId, setAvatarId] = useState(snapshot.identity.avatarId);
  const [lanternShape, setLanternShape] = useState(
    snapshot.identity.lanternShape,
  );
  const [lanternColor, setLanternColor] = useState(
    snapshot.identity.lanternColor,
  );
  const changed =
    avatarId !== snapshot.identity.avatarId ||
    lanternShape !== snapshot.identity.lanternShape ||
    lanternColor !== snapshot.identity.lanternColor;
  return (
    <section className="pb-v2-workshop pb-panel">
      <div className="pb-v2-art">
        <img
          src="/images/poortenboek-v2/identity-workshop-wide.webp"
          alt="Een magische werkplaats met maskers en lantaarns"
          loading="lazy"
        />
      </div>
      <div className="pb-v2-workshop-body">
        <p className="pb-eyebrow">Jouw verschijning</p>
        <h2>Kies wie jij bent in de nacht</h2>
        <p>
          Deze keuze is alleen van jou. Reisgenootjes zien je voornaam en jouw
          medaillon, nooit een foto of privégegevens.
        </p>
        <fieldset className="pb-v2-choice-grid">
          <legend>Avonturenrol</legend>
          {avatarOptions.map((avatar) => (
            <button
              type="button"
              key={avatar.id}
              aria-pressed={avatarId === avatar.id}
              onClick={() => setAvatarId(avatar.id)}
              disabled={busy}
            >
              <img src={avatarImage(avatar.id)} alt="" loading="lazy" />
              <span>{avatar.label}</span>
            </button>
          ))}
        </fieldset>
      <div className="pb-v2-selects">
          <label>
            Vorm van jouw lantaarn
            <select
              value={lanternShape}
              disabled={busy}
              onChange={(event) => setLanternShape(event.target.value)}
            >
              {lanternShapes.map((item) => (
                <option value={item.id} key={item.id}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Kleur van jouw licht
            <select
              value={lanternColor}
              disabled={busy}
              onChange={(event) => setLanternColor(event.target.value)}
            >
              {lanternColors.map((item) => (
                <option value={item.id} key={item.id}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
        </div>
        <img className="pb-lantern-preview" src="/images/poortenboek-v2/lanterns/lantern-base.webp" alt="Jouw gekozen magische lantaarn" />
        <button
          className="pb-button"
          type="button"
          disabled={busy || !changed}
          onClick={() =>
            act("identity", {
              avatarId,
              lanternShape,
              lanternColor,
              requestId: crypto.randomUUID(),
            })
          }
        >
          <Sparkles /> Bewaar mijn verschijning
        </button>
      </div>
    </section>
  );
}

function defaultBanner(snapshot: BookSnapshot): BannerChoices {
  const vote = snapshot.banner.ownVote;
  return {
    shape: vote.shape ?? "shield",
    color: vote.color ?? "amber",
    secondaryColor: vote.secondaryColor ?? "cyan",
    border: vote.border ?? "metal",
    symbol: vote.symbol ?? "gate",
    lantern: vote.lantern ?? "classic",
    glow: vote.glow ?? "warm",
  };
}

export function TeamBannerWorkshop({
  snapshot,
  busy,
  act,
}: {
  snapshot: BookSnapshot;
  busy: boolean;
  act: Act;
}) {
  const [choices, setChoices] = useState(() => defaultBanner(snapshot));
  const result = snapshot.banner.result as BannerChoices | null;
  const shown = result ?? choices;
  const update = (category: BannerCategory, value: string) =>
    setChoices((current) => ({ ...current, [category]: value }));
  return (
    <section className="pb-v2-banner pb-panel">
      <div>
        <p className="pb-eyebrow">Het gezamenlijke vaandel</p>
        <h2>{result ? "Jullie vaandel is gekozen" : "Geef het vaandel jouw vonk"}</h2>
        <p>
          Ieder reisgenootje kiest onderdelen. Alleen de aantallen worden
          geteld; individuele keuzes blijven verborgen.
        </p>
        <TeamBanner choices={shown} level={snapshot.journey.upgradeLevel} />
        <p className="pb-team-progress">
          {snapshot.banner.votedCount} van de {snapshot.banner.eligibleCount}{" "}
          reisgenootjes hebben gekozen
        </p>
      </div>
      {!result && (
        <div className="pb-v2-banner-controls">
          {(Object.keys(bannerOptionLabels) as BannerCategory[]).map(
            (category) => (
              <label key={category}>
                {category === "shape"
                  ? "Vorm"
                    : category === "color"
                      ? "Kleur"
                      : category === "secondaryColor"
                        ? "Tweede kleur"
                    : category === "border"
                      ? "Rand"
                      : category === "symbol"
                        ? "Symbool"
                        : category === "lantern"
                          ? "Lantaarn"
                          : "Gloed"}
                <select
                  value={choices[category]}
                  disabled={busy || snapshot.banner.locked}
                  onChange={(event) => update(category, event.target.value)}
                >
                  {Object.entries(bannerOptionLabels[category]).map(
                    ([value, label]) => (
                      <option value={value} key={value}>
                        {label}
                      </option>
                    ),
                  )}
                </select>
              </label>
            ),
          )}
          <button
            type="button"
            className="pb-button"
            disabled={busy || snapshot.banner.locked}
            onClick={() =>
              act("banner_vote", {
                choices,
                requestId: crypto.randomUUID(),
              })
            }
          >
            <Flame /> Geef mijn vaandelstem
          </button>
          {snapshot.banner.locked && (
            <p className="pb-small">Het vaandel is bij de start van de avond vergrendeld.</p>
          )}
        </div>
      )}
    </section>
  );
}

export function TeamBanner({
  choices,
  level,
}: {
  choices: Partial<BannerChoices>;
  level: number;
}) {
  const textureId = useId();
  const glowId = useId();
  const color = {
    amber: "#d98335",
    cyan: "#29b6c8",
    violet: "#7653bd",
    emerald: "#3d9b72",
    crimson: "#a53e4e",
    moonlight: "#aabbd7",
  }[choices.color ?? "amber"];
  const secondary = {
    amber: "#f1bd75",
    cyan: "#72d9e4",
    violet: "#a88ae7",
    emerald: "#75c99e",
    crimson: "#d57380",
    moonlight: "#e2ebfa",
  }[choices.secondaryColor ?? "cyan"];
  const path =
    choices.shape === "round"
      ? "M28 18H172V103Q100 157 28 103Z"
      : choices.shape === "split"
        ? "M28 18H172V126L136 105L100 139L64 105L28 126Z"
        : choices.shape === "swallowtail"
          ? "M28 18H172V132L100 101L28 132Z"
          : "M28 18H172V101Q100 151 28 101Z";
  const symbol = {
    gate: "⌑",
    moon: "☾",
    flame: "♨",
    ghost: "◉",
    key: "⚿",
    star: "✦",
    bat: "⌁",
    pumpkin: "◍",
  }[choices.symbol ?? "gate"];
  return (
    <div
      className={`pb-banner-svg level-${level} glow-${choices.glow ?? "warm"}`}
      role="img"
      aria-label={`Teamvaandel, magieniveau ${level} van 4`}
    >
      <svg viewBox="0 0 200 170" aria-hidden="true">
        <defs>
          <filter id={glowId}>
            <feGaussianBlur stdDeviation={level > 1 ? 4 : 2} />
          </filter>
          <pattern id={textureId} width="200" height="170" patternUnits="userSpaceOnUse">
            <image
              href="/images/poortenboek-v2/banner/banner-fabric-texture.webp"
              width="200"
              height="170"
              preserveAspectRatio="xMidYMid slice"
            />
          </pattern>
        </defs>
        <path d={path} fill={color} opacity=".28" filter={`url(#${glowId})`} />
        <path d={path} fill={color} stroke={secondary} strokeWidth="3" />
        <path d={path} fill={`url(#${textureId})`} opacity=".18" />
        <text x="100" y="86" textAnchor="middle" className="pb-banner-symbol">
          {symbol}
        </text>
        {level >= 2 && <path d="M48 115Q100 91 152 115" fill="none" stroke="#fff2c5" opacity=".65" />}
        {level >= 3 && <text x="100" y="42" textAnchor="middle" className="pb-banner-stars">✦ · ✦</text>}
        {level >= 4 && <circle cx="100" cy="82" r="53" fill="none" stroke="#b8f7ff" strokeDasharray="3 8" />}
      </svg>
    </div>
  );
}

export function PracticeGate({
  completed,
  busy,
  act,
}: {
  completed: boolean;
  busy: boolean;
  act: Act;
}) {
  const [holding, setHolding] = useState(false);
  const started = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const begin = () => {
    if (busy || completed || timer.current) return;
    started.current = performance.now();
    setHolding(true);
    timer.current = setTimeout(() => {
      timer.current = null;
      setHolding(false);
      act("practice", { heldMs: 1400, requestId: crypto.randomUUID() });
    }, 1400);
  };
  const cancel = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    setHolding(false);
  };
  return (
    <section className={`pb-practice pb-panel ${completed ? "complete" : ""}`}>
      <div className="pb-practice-art">
        <img
          src={`/images/poortenboek-v2/practice-gate-${completed ? "open" : "closed"}.webp`}
          alt={completed ? "De oefenpoort staat open" : "Een gesloten magische oefenpoort"}
        />
      </div>
      <div>
        <p className="pb-eyebrow">Oefenpoort · geen echt bezoek</p>
        <h2>{completed ? "Jij kent het geheim" : "Laat de oefenpoort ontwaken"}</h2>
        <p>
          Houd de knop even vast. Deze oefening geeft één oefenzegel en telt
          nooit mee als poortbezoek, routeactie of avondstatistiek.
        </p>
        <button
          type="button"
          className={`pb-button pb-hold-button ${holding ? "holding" : ""}`}
          disabled={busy || completed}
          onPointerDown={begin}
          onPointerUp={cancel}
          onPointerLeave={cancel}
          onPointerCancel={cancel}
          onKeyDown={(event) => {
            if (event.key === " " || event.key === "Enter") {
              event.preventDefault();
              begin();
            }
          }}
          onKeyUp={(event) => {
            if (event.key === " " || event.key === "Enter") cancel();
          }}
        >
          {completed ? <Check /> : <KeyRound />}
          {completed ? "Oefenzegel verdiend" : holding ? "Blijf vasthouden…" : "Houd vast om te openen"}
        </button>
        {completed && <img className="pb-practice-seal" src="/images/poortenboek-v2/seals/practice-seal.webp" alt="Verdiend oefenzegel" />}
      </div>
    </section>
  );
}

export function JourneyBook({ snapshot }: { snapshot: BookSnapshot }) {
  const chapters = new Set(snapshot.journey.chapters.map((item) => item.chapter));
  const result = snapshot.banner.result ?? defaultBanner(snapshot);
  const chronologicalSeals = [...snapshot.journey.seals].sort(
    (a, b) => new Date(a.earnedAt).getTime() - new Date(b.earnedAt).getTime(),
  );
  const firstVisit = chronologicalSeals.at(0)?.earnedAt;
  const lastVisit = chronologicalSeals.at(-1)?.earnedAt;
  const visitTime = (value: string | undefined) =>
    value
      ? new Intl.DateTimeFormat("nl-NL", {
          dateStyle: "medium",
          timeStyle: "short",
          timeZone: "Europe/Amsterdam",
        }).format(new Date(value))
      : "Nog niet bekend";
  return (
    <>
      <section className="pb-v2-passport pb-panel">
        <div className="pb-section-heading">
          <div>
            <p className="pb-eyebrow">Live Poortenpaspoort</p>
            <h2>{snapshot.journey.visitedCount} poorten in jouw verhaal</h2>
          </div>
          <Shield />
        </div>
        <progress
          value={snapshot.journey.visitedCount}
          max={Math.max(snapshot.journey.assignedCount, 1)}
          aria-label="Voortgang van jouw tocht"
        />
        {snapshot.journey.seals.length ? (
          <div className="pb-v2-seals">
            {snapshot.journey.seals.map((seal) => (
              <article key={`${seal.portalId}-${seal.earnedAt}`}>
                <img
                  className="pb-earned-seal"
                  src={seal.finale ? "/images/poortenboek-v2/seals/final-gate-seal.webp" : `/images/poortenboek-v2/seals/${sealArtwork(seal.presentation.worldSlug)}`}
                  alt=""
                />
                <p className="pb-eyebrow">{seal.finale ? "Finalezegel" : "Poortzegel"}</p>
                <h3>{seal.presentation.publicName}</h3>
                <small>{seal.presentation.portalCode} · {seal.presentation.world}</small>
                <p>{seal.presentation.shortDescription}</p>
                <time>
                  {new Intl.DateTimeFormat("nl-NL", {
                    hour: "2-digit",
                    minute: "2-digit",
                    timeZone: "Europe/Amsterdam",
                  }).format(new Date(seal.earnedAt))}
                </time>
              </article>
            ))}
          </div>
        ) : (
          <p>
            Na een bevestigd bezoek verschijnt hier precies één zegel. De
            Poortkamer kan dit niet zelf toevoegen.
          </p>
        )}
      </section>
      <section className="pb-story-grid">
        {storyChapters.map((chapter) => {
          const unlocked = chapters.has(chapter.chapter);
          return (
            <article className={`pb-story-card ${unlocked ? "unlocked" : ""}`} key={chapter.chapter}>
              <img src={`/images/poortenboek-v2/${chapter.image}`} alt="" loading="lazy" />
              <div>
                <span>{unlocked ? <BookOpen /> : <LockKeyhole />}</span>
                <p>Hoofdstuk {chapter.chapter}</p>
                <h3>{chapter.title}</h3>
                <small>{unlocked ? "Ontwaakt" : "Slaapt nog"}</small>
              </div>
            </article>
          );
        })}
      </section>
      {snapshot.journey.complete && (
        <section className="pb-v2-recap pb-panel">
          <img src="/images/poortenboek-v2/recap-hero-wide.webp" alt="" />
          <div>
            <p className="pb-eyebrow">Jouw nacht in Duindorp</p>
            <h2>Een verhaal om te bewaren</h2>
            <p>
              {snapshot.firstName}, jij en je reisgenootjes bezochten {snapshot.journey.visitedCount}{" "}
              poorten. Jouw zegels, hoofdstukken, lantaarn en teamvaandel zijn compleet.
            </p>
            <div className="pb-recap-facts">
              <div>
                <img src={avatarImage(snapshot.identity.avatarId)} alt="" />
                <span>Jouw verschijning</span>
                <strong>{avatarOptions.find((item) => item.id === snapshot.identity.avatarId)?.label}</strong>
              </div>
              <div>
                <span>Eerste bezoek</span>
                <strong>{visitTime(firstVisit)}</strong>
                <span>Laatste bezoek</span>
                <strong>{visitTime(lastVisit)}</strong>
              </div>
            </div>
            <p>
              <strong>Reisgenootjes:</strong>{" "}
              {snapshot.companions.map((companion) => companion.firstName).join(", ")}.
            </p>
            <p>
              <strong>Bezochte werelden:</strong>{" "}
              {[...new Set(snapshot.journey.seals.map((seal) => seal.presentation.world))].join(", ")}.
            </p>
            <TeamBanner choices={result} level={4} />
            <div className="pb-child-certificate">
              <img src="/images/poortenboek-v2/certificates/child-certificate-background.webp" alt="" />
              <div>
                <span>Deelnamecertificaat</span>
                <strong>{snapshot.firstName}</strong>
                <small>{snapshot.election.winner ?? "Avonturier van de Duindorpse Poorten"}</small>
              </div>
            </div>
            <button className="pb-button" type="button" onClick={() => window.print()}>
              <Download /> Bewaarkaart afdrukken
            </button>
          </div>
        </section>
      )}
    </>
  );
}

function sealArtwork(slug: string) {
  return ({
    heksenrijk: "witch-realm.webp",
    dodenrijk: "realm-of-the-dead.webp",
    circuswereld: "circus-realm.webp",
    "besmette-zone": "contaminated-zone.webp",
    geestenwereld: "ghost-realm.webp",
    vampierrijk: "vampire-realm.webp",
  } as Record<string, string>)[slug] ?? "seal-base.webp";
}

export function JourneyStatus({ snapshot }: { snapshot: BookSnapshot }) {
  const label = useMemo(() => {
    if (snapshot.journey.complete) return "Jouw Poortenboek is compleet";
    if (snapshot.journey.visitedCount)
      return `${snapshot.journey.visitedCount} poorten hebben een zegel achtergelaten`;
    if (snapshot.practice.completed) return "De oefenpoort is geopend";
    return "Open eerst de oefenpoort";
  }, [snapshot]);
  return (
    <section className="pb-v2-journey-status pb-panel">
      <img src="/images/poortenboek-v2/passport-cover.webp" alt="" />
      <div>
        <p className="pb-eyebrow">Jouw boek groeit mee</p>
        <h2>{label}</h2>
        <p>
          {snapshot.journey.visitedCount} van {snapshot.journey.assignedCount || "de"} toegewezen poorten bevestigd.
        </p>
        <Link className="pb-button" href="/poortenboek/boek">
          Bekijk mijn paspoort <BookOpen />
        </Link>
      </div>
    </section>
  );
}
