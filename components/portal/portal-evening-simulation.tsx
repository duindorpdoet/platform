"use client";

import { useEffect, useId, useReducer, useRef, useState } from "react";
import {
  ArrowRight,
  Check,
  CheckCheck,
  ChevronRight,
  DoorClosed,
  DoorOpen,
  Flag,
  FlaskConical,
  Footprints,
  HelpCircle,
  Lightbulb,
  MessageCircle,
  MoonStar,
  Pause,
  Play,
  RotateCcw,
  Send,
  ShieldCheck,
  Sparkles,
  TicketCheck,
  Users,
  Volume2,
  X,
} from "lucide-react";
import {
  nextSimulationStep,
  simulationReducer,
  simulationSteps,
} from "@/lib/domain/portal-evening-model";
import type { SimulationState } from "@/lib/domain/portal-evening-model";
import {
  readPractice,
  rememberPractice,
} from "@/lib/domain/portal-evening-memory";
import "./portal-evening-simulation.css";

const clock = (value: number) =>
  `${String(Math.floor(value / 60) % 24).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}`;
const groupLabel = {
  waiting: "Wacht op vertrek",
  approaching: "Onderweg",
  arrived: "Bij jullie poort",
  inside: "Wordt ontvangen",
  done: "Weer op pad",
};
const stepLabel: Record<string, string> = {
  open: "Openen",
  approaching: "Onderweg",
  arrived: "Aankomst",
  seal: "Oefenzegel",
  crowd: "Drukte",
  pause: "Pauze",
  message: "Regie",
  resume: "Hervatten",
  finish: "Afsluiten",
};

/** This rehearsal deliberately has no command, client, fetch, push or passport connection. */
export function PortalEveningSimulation({
  portalName,
  portalCode,
  scope,
}: {
  portalName: string;
  portalCode: string;
  scope: string;
}) {
  const [state, dispatch] = useReducer(simulationReducer, scope, readPractice);
  useEffect(() => {
    rememberPractice(scope, state);
  }, [scope, state]);
  const [message, setMessage] = useState("");
  const [composer, setComposer] = useState(false);
  const [reset, setReset] = useState(false);
  const resetDialog = useRef<HTMLElement>(null);
  const id = useId();
  const next = nextSimulationStep(state);
  const arrival = state.groups.find((group) => group.status === "arrived");
  const inside = state.groups.find((group) => group.status === "inside");
  const moving = state.groups.some((group) => group.status === "approaching");
  const queue = state.groups.filter((group) =>
    ["waiting", "approaching", "arrived"].includes(group.status),
  );
  const finished = state.completed.length >= simulationSteps.length;
  const controlsDisabled = !state.started || (finished && state.mode === "guided");
  const lastSealed = state.groups.filter((group) => group.sealed).at(-1);
  useEffect(() => {
    if (
      !state.started ||
      !state.running ||
      (finished && state.mode === "guided")
    )
      return;
    const timer = window.setInterval(() => dispatch({ type: "TICK" }), 1150);
    return () => window.clearInterval(timer);
  }, [state.started, state.running, state.speed, state.mode, finished]);
  useEffect(() => {
    if (!reset || !resetDialog.current) return;
    const panel = resetDialog.current;
    const rehearsal = panel.closest<HTMLElement>(".pes");
    const previous =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;
    panel.querySelector<HTMLButtonElement>("[data-reset-cancel]")?.focus();
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setReset(false);
        return;
      }
      if (event.key !== "Tab") return;
      const controls = Array.from(
        panel.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      );
      const first = controls[0];
      const last = controls.at(-1);
      if (!first) {
        event.preventDefault();
        panel.focus();
        return;
      }
      if (!panel.contains(document.activeElement)) {
        event.preventDefault();
        first.focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", keydown, true);
    return () => {
      document.removeEventListener("keydown", keydown, true);
      if (previous?.isConnected && !previous.matches(":disabled"))
        previous.focus();
      else
        rehearsal
          ?.querySelector<HTMLButtonElement>(".pes-welcome button")
          ?.focus();
    };
  }, [reset]);

  function recommended() {
    if (!state.started) return dispatch({ type: "START" });
    switch (next?.id) {
      case "open":
        dispatch({ type: "OPEN" });
        break;
      case "approaching":
        dispatch({ type: "SEND_GROUP" });
        break;
      case "arrived":
        if (arrival) dispatch({ type: "CONFIRM_ARRIVAL", groupId: arrival.id });
        else if (!moving && !inside) dispatch({ type: "SEND_GROUP" });
        else dispatch({ type: "TICK" });
        break;
      case "seal":
        if (inside) dispatch({ type: "FINISH_VISIT", groupId: inside.id });
        break;
      case "crowd":
        dispatch({ type: "CROWD" });
        break;
      case "pause":
        dispatch({ type: "PAUSE" });
        break;
      case "message":
        setComposer(true);
        break;
      case "resume":
        dispatch({ type: "RESUME" });
        break;
      case "finish":
        if (state.gate === "paused") dispatch({ type: "RESUME" });
        else if (inside) dispatch({ type: "FINISH_VISIT", groupId: inside.id });
        else if (arrival)
          dispatch({ type: "CONFIRM_ARRIVAL", groupId: arrival.id });
        else if (moving) dispatch({ type: "TICK" });
        else if (state.groups.some((group) => group.status === "waiting"))
          dispatch({ type: "SEND_GROUP" });
        else dispatch({ type: "CLOSE" });
        break;
    }
  }
  const actionLabel = !state.started
    ? "Start de oefenavond"
    : next?.id === "arrived"
      ? arrival
        ? "Bevestig oefenaankomst"
        : "Laat de groep dichterbij komen"
      : next?.id === "finish"
        ? inside
          ? "Rond huidig oefenbezoek af"
          : arrival
            ? "Ontvang de laatste oefengroep"
            : moving
              ? "Laat de laatste groep aankomen"
              : "Sluit de oefenpoort"
        : (next?.actionLabel ?? "Oefening afgerond");

  return (
    <section className="pes" aria-labelledby={`${id}-title`}>
      <header className="pes-hero">
        <img
          src="/images/poortkamer-v2/simulation-hero-wide.webp"
          alt="Een sfeervol verlichte poort in Duindorp bij avond"
        />
        <div className="pes-hero-shade" />
        <div className="pes-hero-copy">
          <span className="pes-kicker">
            <FlaskConical size={13} /> DE GENERALE REPETITIE
          </span>
          <h2 id={`${id}-title`}>
            De nacht begint.
            <br />
            <em>Jullie zijn er klaar voor.</em>
          </h2>
          <p>
            Ontvang je eerste oefengroep, houd het gezellig bij de poort en
            ontdek wat je kunt doen als het even druk wordt.
          </p>
          <div className="pes-hero-tags">
            <span>
              <MoonStar size={13} /> Een mini-avond in Duindorp
            </span>
            <span>
              <ShieldCheck size={13} /> Helemaal fictief
            </span>
          </div>
        </div>
        <div className="pes-hero-time">
          <span>ZATERDAG</span>
          <strong>
            31<small> / 10</small>
          </strong>
          <span>OEFEN ALLES ALVAST</span>
        </div>
      </header>

      <div className="pes-body">
        <div className="pes-intro-line">
          <span className="pes-demo-badge">
            <i /> Oefenstand — fictieve groepen
          </span>
          <span>
            Jullie poort: <strong>{portalName}</strong>
          </span>
          <span className="pes-local-label">Alleen in dit tabblad</span>
        </div>

        {!state.started && (
          <div className="pes-welcome">
            <div className="pes-welcome-icon">
              <Sparkles size={26} />
            </div>
            <div>
              <h3>Even proberen. Straks vertrouwd.</h3>
              <p>
                Neem de situaties rustig door. Jij bedient de poort; de fictieve
                oefengroepen bewegen vanzelf.
              </p>
            </div>
            <button
              type="button"
              className="pes-button pes-primary"
              onClick={() => dispatch({ type: "START" })}
            >
              <Play size={15} fill="currentColor" /> Start de oefenavond
            </button>
          </div>
        )}

        <div className="pes-progress-heading">
          <span>
            {finished
              ? "Mooi gedaan. Jullie hebben de avond in de vingers."
              : state.started
                ? "Jullie oefenroute"
                : "Dit gaan jullie samen oefenen"}
          </span>
          <strong>
            {state.completed.length}
            <small> / {simulationSteps.length}</small>
          </strong>
        </div>
        <ol className="pes-steps" aria-label="Voortgang van de oefening">
          {simulationSteps.map((step, index) => (
            <li
              key={step.id}
              className={`${state.completed.includes(step.id) ? "is-done" : ""} ${state.started && next?.id === step.id ? "is-current" : ""}`}
              aria-current={
                state.started && next?.id === step.id ? "step" : undefined
              }
            >
              <span>
                {state.completed.includes(step.id) ? (
                  <Check size={12} />
                ) : (
                  String(index + 1).padStart(2, "0")
                )}
              </span>
              <small>{stepLabel[step.id]}</small>
            </li>
          ))}
        </ol>

        {state.started && (
          <div className="pes-mode-switch">
            <span>Jij bepaalt het ritme van de avond.</span>
            <div aria-label="Oefenvorm">
              <button
                type="button"
                aria-pressed={state.mode === "guided"}
                onClick={() => dispatch({ type: "MODE", mode: "guided" })}
              >
                <Lightbulb size={12} /> Met de coach
              </button>
              <button
                type="button"
                aria-pressed={state.mode === "free"}
                onClick={() => dispatch({ type: "MODE", mode: "free" })}
              >
                <Sparkles size={12} /> Vrij oefenen
              </button>
            </div>
          </div>
        )}
        <div className={`pes-workspace ${!state.started ? "is-preview" : ""}`}>
          <div className="pes-theatre">
            <div className="pes-scene-top">
              <div>
                <span className="pes-overline">
                  EEN FICTIEF STUKJE DUINDORP
                </span>
                <strong>Welkom in jullie oefenstraat.</strong>
              </div>
              <span className="pes-clock">
                <MoonStar size={14} /> {clock(state.clock)}
                <small>oefentijd</small>
              </span>
            </div>
            <VillageScene state={state} portalCode={portalCode} />
            <div className="pes-scene-bottom">
              <span>
                <i className={`pes-status-dot ${state.gate}`} />
                {state.gate === "open"
                  ? "Oefenpoort open"
                  : state.gate === "paused"
                    ? "Even op adem komen"
                    : "Oefenpoort gesloten"}
              </span>
              <span>
                <Users size={13} /> 1 groep tegelijk
              </span>
              <span>Fictieve kaart</span>
            </div>
            <div className="pes-playback">
              <button
                type="button"
                className="pes-icon-button"
                disabled={
                  !state.started || (finished && state.mode === "guided")
                }
                onClick={() =>
                  dispatch({ type: "PLAY", running: !state.running })
                }
                aria-label={
                  state.running
                    ? "Oefenbeweging pauzeren"
                    : "Oefenbeweging afspelen"
                }
              >
                {state.running ? <Pause size={15} /> : <Play size={15} />}
              </button>
              <span>Oefenbeweging</span>
              <div className="pes-speed" aria-label="Oefensnelheid">
                {([1, 2, 4] as const).map((speed) => (
                  <button
                    type="button"
                    key={speed}
                    disabled={!state.started}
                    aria-pressed={state.speed === speed}
                    onClick={() => dispatch({ type: "SPEED", speed })}
                  >
                    {speed}×
                  </button>
                ))}
              </div>
              <button
                type="button"
                className="pes-text-button"
                disabled={!state.started}
                onClick={() => setReset(true)}
              >
                <RotateCcw size={13} /> Opnieuw
              </button>
            </div>
          </div>

          <aside
            className="pes-control"
            aria-label="Bediening van de oefenpoort"
          >
            <div className="pes-control-heading">
              <span className="pes-gate-icon">
                <DoorOpen size={22} />
              </span>
              <div>
                <span className="pes-overline">JIJ BENT DE POORTWACHTER</span>
                <h3>{portalName}</h3>
                <small>{portalCode} · fictieve ontvangst</small>
              </div>
            </div>
            <div className={`pes-gate-state ${state.gate}`}>
              <span>
                <i />
                {state.gate === "open"
                  ? "Kom maar binnen!"
                  : state.gate === "paused"
                    ? "Pauze voor nieuwe groepen"
                    : state.completed.includes("open")
                      ? "De oefenpoort is gesloten"
                      : "De deur is nog dicht"}
              </span>
              <small>
                {state.gate === "paused"
                  ? "Een huidige groep mag het bezoek afmaken."
                  : state.gate === "open"
                    ? "Er kan één oefengroep worden ontvangen."
                    : "Open de oefenpoort om een rondje te proberen."}
              </small>
            </div>
            <div className="pes-gate-buttons">
              <button
                type="button"
                disabled={controlsDisabled || state.gate === "open"}
                className={state.gate === "open" ? "is-active" : ""}
                onClick={() =>
                  dispatch({
                    type: state.gate === "paused" ? "RESUME" : "OPEN",
                  })
                }
              >
                <DoorOpen size={14} />{" "}
                {state.gate === "paused" ? "Hervat" : "Open"}
              </button>
              <button
                type="button"
                disabled={controlsDisabled || state.gate !== "open"}
                className={state.gate === "paused" ? "is-active" : ""}
                onClick={() => dispatch({ type: "PAUSE" })}
              >
                <Pause size={14} /> Pauze
              </button>
              <button
                type="button"
                disabled={
                  !state.started ||
                  state.gate === "closed" ||
                  !!inside ||
                  !!arrival ||
                  moving
                }
                onClick={() => dispatch({ type: "CLOSE" })}
              >
                <DoorClosed size={14} /> Sluiten
              </button>
            </div>
            <div className="pes-current-visit">
              <span className="pes-overline">
                {inside
                  ? "NU BIJ JULLIE"
                  : arrival
                    ? "AANGEKOMEN BIJ DE POORT"
                    : "DE VOLGENDE ONTMOETING"}
              </span>
              {inside || arrival ? (
                <>
                  <div className="pes-arrival-name">
                    <span
                      className="pes-group-emblem"
                      style={{
                        background: `${(inside || arrival)!.color}22`,
                        color: (inside || arrival)!.color,
                      }}
                    >
                      <Footprints size={20} />
                    </span>
                    <div>
                      <h4>{(inside || arrival)!.name}</h4>
                      <p>
                        {(inside || arrival)!.children} fictieve kinderen ·
                        oefengroep
                      </p>
                    </div>
                  </div>
                  <button
                    type="button"
                    className="pes-button pes-primary"
                    onClick={(event) => {
                      if (event.detail < 2)
                        dispatch(
                          inside
                            ? { type: "FINISH_VISIT", groupId: inside.id }
                            : { type: "CONFIRM_ARRIVAL", groupId: arrival!.id },
                        );
                    }}
                  >
                    {inside ? (
                      <>
                        <TicketCheck size={16} /> Bezoek afronden & oefenzegel
                      </>
                    ) : (
                      <>
                        <CheckCheck size={16} /> Bevestig oefenaankomst
                      </>
                    )}
                  </button>
                  <p className="pes-mini-hint">
                    {inside
                      ? "Ook een kind dat buiten bleef, hoort bij deze fictieve aankomst."
                      : "Eerst de aankomst bevestigen; daarna kun je het bezoek afronden."}
                  </p>
                </>
              ) : (
                <>
                  {lastSealed && (
                    <div className="pes-stamp">
                      <TicketCheck size={28} />
                      <div>
                        <strong>Een oefenzegel voor iedereen!</strong>
                        <small>
                          {lastSealed.name} · {lastSealed.children} fictieve
                          kinderboeken
                        </small>
                      </div>
                    </div>
                  )}
                  <div className="pes-empty-visit">
                    <MoonStar size={23} />
                    <p>
                      {moving
                        ? "De voetstappen komen dichterbij…"
                        : state.gate === "paused"
                          ? "Geen nieuwe groep vertrekt tijdens deze pauze."
                          : "De eerste glimlach komt eraan."}
                    </p>
                  </div>
                </>
              )}
            </div>
            <div className="pes-metrics">
              <div>
                <strong>{state.visits}</strong>
                <span>ontvangen groepen</span>
              </div>
              <div>
                <strong>{state.children}</strong>
                <span>oefenkinderen</span>
              </div>
              <div>
                <strong>{state.seals}</strong>
                <span>oefenzegels</span>
              </div>
            </div>
          </aside>
        </div>

        {state.started && (
          <>
            {state.log.at(-1) && (
              <p className="pes-moment" role="status">
                <span>{state.log.at(-1)!.time}</span>
                {state.log.at(-1)!.text}
              </p>
            )}
            {state.mode === "guided" ? (
              <div
                className={`pes-coach ${finished ? "is-finished" : ""}`}
                aria-live="polite"
              >
                <span className="pes-coach-icon">
                  {finished ? <Flag size={22} /> : <Lightbulb size={22} />}
                </span>
                <div>
                  <span className="pes-overline">
                    {finished
                      ? "OEFENAVOND AFGEROND"
                      : `JULLIE COACH · STAP ${Math.min(simulationSteps.findIndex((step) => step.id === next?.id) + 1, simulationSteps.length)} VAN ${simulationSteps.length}`}
                  </span>
                  <h3>
                    {finished
                      ? "Een fijne nacht begint bij een ontspannen poortteam."
                      : next?.title}
                  </h3>
                  <p>
                    {finished
                      ? "Jullie openden de poort, ontvingen groepen en hielden overzicht. Kies Vrij oefenen om nog een rondje te proberen."
                      : next?.hint}
                  </p>
                </div>
                {!finished && (
                  <button
                    type="button"
                    className="pes-button pes-primary"
                    onClick={(event) => {
                      if (event.detail < 2) recommended();
                    }}
                  >
                    {actionLabel}
                    <ArrowRight size={16} />
                  </button>
                )}
              </div>
            ) : (
              <div className="pes-free-hint">
                <Sparkles size={22} />
                <p>
                  <strong>De straat is aan jullie.</strong> Open de poort, voeg
                  oefengroepen toe en probeer een druk moment of een pauze. Na
                  een afgerond bezoek vertrekt de eerstvolgende wachtende groep
                  vanzelf, zolang de poort open is. Met de coach kun je altijd
                  terug naar de volgende oefenstap.
                </p>
              </div>
            )}

            <div className="pes-lower-grid">
              <section className="pes-panel">
                <div className="pes-panel-heading">
                  <div>
                    <span className="pes-overline">
                      KLEINE VOETSTAPPEN, GROOT AVONTUUR
                    </span>
                    <h3>Wie komt er aan?</h3>
                  </div>
                  <span className="pes-counter">{queue.length}</span>
                </div>
                <div className="pes-queue">
                  {state.groups
                    .filter((group) => group.status !== "done")
                    .map((group) => (
                      <article key={group.id}>
                        <span
                          className="pes-group-dot"
                          style={{ color: group.color }}
                        >
                          <Users size={17} />
                        </span>
                        <div>
                          <strong>{group.name}</strong>
                          <span>
                            {group.children} kinderen ·{" "}
                            {groupLabel[group.status]}
                          </span>
                        </div>
                        <span className={`pes-group-state ${group.status}`}>
                          {group.status === "approaching" ? (
                            <Footprints size={13} />
                          ) : group.status === "inside" ? (
                            <DoorOpen size={13} />
                          ) : (
                            <span>•</span>
                          )}
                          {group.status === "approaching"
                            ? `${Math.max(1, Math.ceil((100 - group.progress) / 20))} stapjes`
                            : group.status === "inside"
                              ? "Welkom"
                              : group.status === "arrived"
                                ? "Aangekomen"
                                : "Wachten"}
                        </span>
                      </article>
                    ))}
                  {!state.groups.some((group) => group.status !== "done") && (
                    <p className="pes-empty-copy">
                      Nog even rustig in de straat. Zet een oefengroep op pad.
                    </p>
                  )}
                </div>
                <p className="pes-mini-hint">
                  {state.gate === "paused"
                    ? "Tijdens de poortpauze blijven nieuwe groepen wachten. Na Hervat loopt de wachtrij vanzelf door."
                    : state.gate === "open"
                      ? "Na een afgerond bezoek vertrekt de eerste wachtende groep automatisch. Er komt één groep tegelijk."
                      : "Open de oefenpoort om de wachtrij te laten doorlopen."}
                </p>
                <div className="pes-panel-actions">
                  <button
                    type="button"
                    className="pes-button pes-secondary"
                    disabled={
                      state.gate !== "open" ||
                      state.groups.filter((group) => group.status !== "done")
                        .length >= 3
                    }
                    onClick={() => dispatch({ type: "SEND_GROUP" })}
                  >
                    <Footprints size={14} /> Een groep op pad
                  </button>
                  <button
                    type="button"
                    className="pes-button pes-secondary"
                    disabled={controlsDisabled || state.gate !== "open"}
                    onClick={() => dispatch({ type: "CROWD" })}
                  >
                    <Users size={14} /> Even lekker druk
                  </button>
                </div>
              </section>

              <section className="pes-panel">
                <div className="pes-panel-heading">
                  <div>
                    <span className="pes-overline">
                      SAMEN HOUD JE HET GEZELLIG
                    </span>
                    <h3>Jullie oefenregie</h3>
                  </div>
                  <MessageCircle size={20} />
                </div>
                <div className="pes-regie-note">
                  <span className="pes-demo-pill">FICTIEVE REGIE</span>
                  <p>
                    {state.helpReply ||
                      "‘Wij kijken met je mee. Probeer gerust een bericht of een hulpvraag.’"}
                  </p>
                </div>
                {composer ? (
                  <form
                    className="pes-composer"
                    onSubmit={(event) => {
                      event.preventDefault();
                      if (message.trim()) {
                        dispatch({ type: "MESSAGE", text: message });
                        setMessage("");
                        setComposer(false);
                      }
                    }}
                  >
                    <label htmlFor={`${id}-message`}>
                      Oefenbericht aan de fictieve regie
                    </label>
                    <textarea
                      id={`${id}-message`}
                      autoFocus
                      maxLength={240}
                      placeholder="Bijvoorbeeld: het wordt wat druk bij onze poort…"
                      value={message}
                      onChange={(event) => setMessage(event.target.value)}
                    />
                    <div>
                      <button
                        type="button"
                        className="pes-text-button"
                        onClick={() => setComposer(false)}
                      >
                        Annuleren
                      </button>
                      <button
                        type="submit"
                        className="pes-button pes-primary"
                        disabled={!message.trim()}
                      >
                        <Send size={13} /> Oefenbericht versturen
                      </button>
                    </div>
                  </form>
                ) : (
                  <div className="pes-panel-actions">
                    <button
                      type="button"
                      className="pes-button pes-secondary"
                      onClick={() => setComposer(true)}
                    >
                      <MessageCircle size={14} /> Bericht oefenen
                    </button>
                    <button
                      type="button"
                      className="pes-button pes-secondary"
                      onClick={() => dispatch({ type: "HELP" })}
                    >
                      <HelpCircle size={14} /> Hulpvraag oefenen
                    </button>
                  </div>
                )}
                <p className="pes-mini-hint">
                  Dit gesprek blijft in deze oefening. Het antwoord is vooraf
                  bedacht.
                </p>
              </section>
            </div>

            <details className="pes-log">
              <summary>
                <Volume2 size={15} />
                <span>Zo verliep jullie oefenavond</span>
                <span>{state.log.length} momenten</span>
                <ChevronRight size={15} />
              </summary>
              <ol>
                {state.log
                  .slice()
                  .reverse()
                  .slice(0, 12)
                  .map((entry) => (
                    <li key={entry.id}>
                      <time>{entry.time}</time>
                      <span>{entry.text}</span>
                    </li>
                  ))}
              </ol>
            </details>
            <div className="pes-extra">
              <div>
                <Sparkles size={17} />
                <span>Nog een toefje magie?</span>
                <p>
                  {state.completed.includes("seal")
                    ? "Probeer de fictieve finale en laat de straat oplichten."
                    : "Rond eerst een oefenbezoek af om de finale te bekijken."}
                </p>
              </div>
              <button
                type="button"
                className="pes-button pes-secondary"
                disabled={!state.completed.includes("seal") || state.finale}
                onClick={() => dispatch({ type: "FINALE" })}
              >
                <Sparkles size={14} />{" "}
                {state.finale ? "Oefenfinale bekeken" : "Bekijk de oefenfinale"}
              </button>
            </div>
          </>
        )}
        <p className="pes-safety-note">
          <FlaskConical size={14} />
          Alle groepen, aankomsten, zegels en regieantwoorden zijn fictief.
          Voortgang blijft bij tabwissels in dit tabblad bewaard. Herladen
          begint opnieuw; er is geen synchronisatie tussen apparaten.
        </p>
      </div>

      {reset && (
        <div className="pes-reset-backdrop">
          <section
            ref={resetDialog}
            tabIndex={-1}
            role="dialog"
            aria-modal="true"
            aria-labelledby={`${id}-reset`}
            aria-describedby={`${id}-reset-description`}
            className="pes-reset-dialog"
          >
            <button
              type="button"
              className="pes-icon-button pes-reset-close"
              aria-label="Resetvenster sluiten"
              onClick={() => setReset(false)}
            >
              <X size={18} />
            </button>
            <RotateCcw size={26} />
            <h3 id={`${id}-reset`}>Nog een rondje oefenen?</h3>
            <p id={`${id}-reset-description`}>
              Begin deze fictieve oefenavond opnieuw. De oefengroepen,
              oefenzegels en stappen op dit scherm worden leeggemaakt.
            </p>
            <div>
              <button
                data-reset-cancel
                type="button"
                className="pes-button pes-secondary"
                onClick={() => setReset(false)}
              >
                Verder oefenen
              </button>
              <button
                type="button"
                className="pes-button pes-primary"
                onClick={() => {
                  dispatch({ type: "RESET" });
                  setMessage("");
                  setComposer(false);
                  setReset(false);
                }}
              >
                Opnieuw beginnen
              </button>
            </div>
          </section>
        </div>
      )}
    </section>
  );
}

function VillageScene({
  state,
  portalCode,
}: {
  state: SimulationState;
  portalCode: string;
}) {
  const id = useId().replaceAll(":", "");
  const isOpen = state.gate !== "closed";
  return (
    <div className={`pes-village ${state.finale ? "is-finale" : ""}`}>
      <svg
        viewBox="0 0 800 425"
        role="img"
        aria-label={`Fictieve oefenstraat met jullie ${state.gate === "open" ? "open" : state.gate === "paused" ? "gepauzeerde" : "gesloten"} poort en ${state.groups.length} oefengroepen`}
      >
        <defs>
          <linearGradient id={`${id}-sky`} x2="0" y2="1">
            <stop stopColor="#101e35" />
            <stop offset="1" stopColor="#122237" />
          </linearGradient>
          <linearGradient id={`${id}-road`} x2="1" y2="1">
            <stop stopColor="#23354a" />
            <stop offset="1" stopColor="#1a2a3b" />
          </linearGradient>
          <radialGradient id={`${id}-glow`}>
            <stop stopColor="#f6c96c" stopOpacity=".3" />
            <stop offset="1" stopColor="#efac55" stopOpacity="0" />
          </radialGradient>
          <linearGradient id={`${id}-door`} x2="0" y2="1">
            <stop stopColor={isOpen ? "#f2c172" : "#263746"} />
            <stop offset="1" stopColor={isOpen ? "#bd6c38" : "#142534"} />
          </linearGradient>
          <pattern
            id={`${id}-paving`}
            width="32"
            height="20"
            patternUnits="userSpaceOnUse"
          >
            <path
              d="M0 0H32M0 20H32M16 0V10M0 10H32M0 10V20M32 10V20"
              stroke="#738093"
              strokeOpacity=".08"
              fill="none"
            />
          </pattern>
        </defs>
        <rect width="800" height="425" fill={`url(#${id}-sky)`} />
        <g fill="#e2d8b4" opacity=".45">
          {[
            [49, 29],
            [107, 60],
            [192, 23],
            [277, 52],
            [406, 26],
            [478, 60],
            [550, 35],
            [742, 45],
            [699, 18],
          ].map(([x, y], i) => (
            <circle key={i} cx={x} cy={y} r={i % 3 === 0 ? 1.6 : 1} />
          ))}
        </g>
        <circle cx="718" cy="69" r="24" fill="#f1dca4" opacity=".9" />
        <circle cx="728" cy="62" r="22" fill="#152238" />
        <path
          d="M-30 398L118 288L335 310L435 238L635 264L820 328"
          fill="none"
          stroke="#0b1627"
          strokeWidth="110"
        />
        <path
          d="M-30 398L118 288L335 310L435 238L635 264L820 328"
          fill="none"
          stroke={`url(#${id}-road)`}
          strokeWidth="92"
        />
        <path
          d="M-30 398L118 288L335 310L435 238L635 264L820 328"
          fill="none"
          stroke="#6b7d8b"
          strokeOpacity=".18"
          strokeWidth="2"
          strokeDasharray="4 13"
        />
        <path
          d="M0 380L111 286L330 307L439 237L635 264L800 321V425H0Z"
          fill={`url(#${id}-paving)`}
          opacity=".5"
        />
        <House x={45} y={137} color="#334253" roof="#243245" />
        <House x={180} y={112} color="#4a4644" roof="#293041" />
        <House x={300} y={88} color="#3c4254" roof="#202b3f" small />
        <House x={81} y={321} color="#303d50" roof="#1e2d40" small />
        <House x={325} y={330} color="#403d47" roof="#253044" small />
        <g opacity=".8">
          <path
            d="M27 266v-71m-8 0h16m-8 0v-12"
            stroke="#566173"
            strokeWidth="4"
          />
          <circle cx="27" cy="187" r="43" fill={`url(#${id}-glow)`} />
          <rect x="21" y="176" width="12" height="17" rx="3" fill="#eac576" />
          <path
            d="M739 301v-78m-8 0h16m-8 0v-12"
            stroke="#566173"
            strokeWidth="4"
          />
          <circle cx="739" cy="216" r="57" fill={`url(#${id}-glow)`} />
          <rect x="732" y="205" width="14" height="19" rx="3" fill="#eac576" />
        </g>
        <g className="pes-scene-flowers">
          <ellipse cx="499" cy="280" rx="49" ry="10" fill="#091626" />
          <path
            d="M471 267l-5-15m22 21l6-25m-7 24l-9-10"
            stroke="#47645c"
            strokeWidth="4"
          />
          <circle cx="465" cy="251" r="7" fill="#866c51" />
          <circle cx="494" cy="247" r="6" fill="#907e5f" />
          <circle cx="478" cy="261" r="6" fill="#687d6e" />
        </g>
        <g transform="translate(520 78)">
          <ellipse
            cx="88"
            cy="188"
            rx="111"
            ry="43"
            fill={isOpen ? `url(#${id}-glow)` : "#0c1728"}
          />
          <path
            d="M-5 176V42L18 21L145 21L167 43V176Z"
            fill="#1b3043"
            stroke="#45586b"
            strokeWidth="1.5"
          />
          <path
            d="M-15 41L78-9L177 41"
            fill="#273a4d"
            stroke="#536173"
            strokeWidth="2"
          />
          <path
            d="M15 176V58Q78-1 143 58V176"
            fill="#142434"
            stroke="#637181"
            strokeWidth="8"
          />
          <path
            d="M28 178V65Q78 15 130 65V178"
            fill={`url(#${id}-door)`}
            stroke="#c89f62"
            strokeWidth="3"
          />
          <g
            opacity={isOpen ? ".5" : ".8"}
            stroke={isOpen ? "#ffe0a3" : "#455361"}
          >
            <path d="M79 30v149M28 94h103M28 137h103" />
            <path d="M42 53v126M116 51v128" />
          </g>
          {isOpen && (
            <g className="pes-door-sparkles" fill="#ffe4a2">
              <circle cx="63" cy="96" r="2" />
              <circle cx="99" cy="71" r="2.5" />
              <circle cx="91" cy="138" r="2" />
            </g>
          )}
          <circle cx="88" cy="120" r="3" fill="#f9df9c" />
          <path d="M-8 178h179M0 186h156" stroke="#4b5b69" strokeWidth="6" />
          <rect
            x="26"
            y="-18"
            width="112"
            height="24"
            rx="5"
            fill="#122237"
            stroke="#77674e"
          />
          <text
            x="82"
            y="-2"
            textAnchor="middle"
            fill="#dfc89e"
            fontSize="11"
            fontFamily="system-ui"
            letterSpacing="1.2"
          >
            JULLIE POORT
          </text>
          <rect x="55" y="49" width="50" height="16" rx="3" fill="#192736" />
          <text
            x="80"
            y="61"
            textAnchor="middle"
            fill="#c7b48d"
            fontSize="9"
            fontFamily="system-ui"
          >
            {portalCode}
          </text>
          <path
            d="M2 90q-16 15-2 32m159-32q15 15 1 32"
            fill="none"
            stroke="#968367"
            strokeWidth="2"
          />
          <rect x="-5" y="102" width="8" height="15" rx="2" fill="#eac576" />
          <rect x="158" y="102" width="8" height="15" rx="2" fill="#eac576" />
          <g transform="translate(14 167)">
            <ellipse rx="14" ry="11" fill="#b9663d" />
            <path
              d="M-6-3l4 4m8-4L3 1M-5 5Q0 10 6 4"
              stroke="#e8b663"
              fill="none"
              strokeWidth="2"
            />
            <path d="M0-10l2-5" stroke="#748062" strokeWidth="3" />
          </g>
          <g transform="translate(144 166)">
            <ellipse rx="11" ry="9" fill="#9c603c" />
            <path d="M0-9l2-4" stroke="#748062" strokeWidth="3" />
          </g>
        </g>
        <path
          d="M139 296Q250 337 352 292T571 261"
          fill="none"
          stroke={state.started ? "#d8b874" : "#596b7d"}
          strokeOpacity=".7"
          strokeWidth="2"
          strokeDasharray="4 9"
          className={moving(state) ? "pes-route-moving" : ""}
        />
        {state.groups.map((group, index) => {
          const progress =
            group.status === "waiting"
              ? 0
              : group.status === "inside"
                ? 100
                : group.status === "arrived"
                  ? 92
                  : group.status === "done"
                    ? 113
                    : group.progress;
          const p = progress / 100;
          const x = 132 + p * 455;
          const y =
            300 -
            Math.sin(p * Math.PI) * 15 -
            p * 37 +
            (group.status === "waiting" ? index * 13 : 0);
          return (
            <g
              key={group.id}
              className={`pes-map-group ${group.status}`}
              style={{
                transform: `translate(${x}px, ${y}px)`,
                opacity: group.status === "done" ? 0 : 1,
              }}
            >
              <ellipse
                cx="0"
                cy="12"
                rx="32"
                ry="11"
                fill="#091323"
                opacity=".7"
              />
              <g fill={group.color} stroke="#122338" strokeWidth="2">
                <circle cx="-12" cy="-5" r="10" />
                <circle cx="11" cy="-9" r="11" />
                <circle cx="30" cy="-1" r="9" />
              </g>
              <g fill="#f2d6b0">
                <circle cx="-12" cy="-9" r="4" />
                <circle cx="11" cy="-14" r="4.5" />
                <circle cx="30" cy="-5" r="3.5" />
              </g>
              <path
                d="M-16 8l-3 9m10-10l2 9M5 7l-3 10m14-9l3 10m6-8l-2 8m10-6l4 6"
                stroke={group.color}
                strokeWidth="4"
                strokeLinecap="round"
              />
              <g transform="translate(-42 -52)">
                <rect
                  width="125"
                  height="25"
                  rx="12.5"
                  fill="#101f31"
                  stroke={group.color}
                  strokeOpacity=".5"
                />
                <text
                  x="62"
                  y="16"
                  textAnchor="middle"
                  fill="#f0e9d9"
                  fontSize="10"
                  fontWeight="600"
                  fontFamily="system-ui"
                >
                  {group.name}
                </text>
              </g>
              {group.status === "inside" && (
                <g transform="translate(25 -30)">
                  <circle r="11" fill="#e6c68b" />
                  <path
                    d="M-4 0l3 3 5-6"
                    stroke="#1a3040"
                    strokeWidth="2"
                    fill="none"
                  />
                </g>
              )}
            </g>
          );
        })}
        {!state.started && (
          <g>
            <rect
              x="232"
              y="345"
              width="337"
              height="36"
              rx="18"
              fill="#101e30"
              stroke="#6d634e"
            />
            <text
              x="400"
              y="368"
              textAnchor="middle"
              fill="#d1b88a"
              fontSize="12"
              fontFamily="system-ui"
            >
              Hier komen straks jullie oefengroepen aan.
            </text>
          </g>
        )}
        {state.finale && (
          <g className="pes-final-stars" fill="#f2d28b">
            {[
              [342, 112],
              [456, 74],
              [597, 38],
              [663, 87],
              [391, 173],
              [714, 167],
            ].map(([x, y], i) => (
              <g key={i} transform={`translate(${x} ${y})`}>
                <path d="M0-9L3-3 9 0 3 3 0 9-3 3-9 0-3-3Z" />
                <circle r="21" fill={`url(#${id}-glow)`} />
              </g>
            ))}
          </g>
        )}
      </svg>
      {state.finale && (
        <div className="pes-finale-caption">
          <Sparkles size={15} /> Een kleine straat. Een magische nacht.
        </div>
      )}
    </div>
  );
}
function moving(state: SimulationState) {
  return state.groups.some((group) => group.status === "approaching");
}
function House({
  x,
  y,
  color,
  roof,
  small = false,
}: {
  x: number;
  y: number;
  color: string;
  roof: string;
  small?: boolean;
}) {
  return (
    <g transform={`translate(${x} ${y}) scale(${small ? 0.75 : 1})`}>
      <path
        d="M0 112V20L56-5L113 20V112Z"
        fill={color}
        stroke="#5e6a78"
        strokeOpacity=".3"
      />
      <path
        d="M-8 23L56-13L121 23"
        fill={roof}
        stroke="#667180"
        strokeOpacity=".35"
        strokeWidth="2"
      />
      <rect x="80" y="-14" width="12" height="22" fill={color} />
      <rect
        x="43"
        y="65"
        width="27"
        height="47"
        rx="3"
        fill="#1b2c3c"
        stroke="#67717a"
        strokeOpacity=".4"
      />
      {[
        [16, 36],
        [77, 36],
      ].map(([x, y], i) => (
        <g key={i}>
          <rect
            x={x}
            y={y}
            width="21"
            height="27"
            rx="1"
            fill="#b68d52"
            opacity={i ? ".65" : ".85"}
          />
          <path
            d={`M${x + 10} ${y}v27m-10-13h21`}
            stroke="#3e4549"
            strokeWidth="2"
          />
        </g>
      ))}
      <path d="M2 112h108M5 120h104" stroke="#202e3e" strokeWidth="4" />
      <ellipse cx="28" cy="112" rx="11" ry="7" fill="#985e3e" />
      <path d="M28 106v-5" stroke="#71755c" strokeWidth="2" />
    </g>
  );
}
