"use client";

import { useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronRight,
  Eye,
  FileCheck2,
  FlaskConical,
  Gauge,
  ShieldAlert,
  Sparkles,
} from "lucide-react";
import {
  portalTime,
  roomMetrics,
  type PortalRoom,
} from "@/lib/domain/poortkamer";
import s from "./poortkamer.module.css";

type Command = (
  operation: string,
  payload: Record<string, unknown>,
) => Promise<boolean>;

const simulationLabels: Record<string, string> = { quiet: "Nog rustig", open: "Poort open", approaching: "Groep onderweg", arrived: "Groep aangekomen", busy: "Drukte bij de poort", paused: "Even pauze", stopped: "Poort gesloten", incident: "Hulp vragen", chat: "Bericht proberen", seal: "Zegel ontvangen", finale: "De laatste poort", completed: "Oefening klaar" };

const incidentLabels = {
  crowding: "Drukte bij de poort",
  lingering: "Groep blijft te lang",
  technical: "Technisch probleem",
  nuisance: "Overlast",
  unsafe: "Onveilige situatie",
  contact_requested: "Contact met organisatie gewenst",
  other: "Anders",
} as const;

export function PoortkamerLiveV2({ room }: { room: PortalRoom }) {
  const metrics = roomMetrics(room);
  return (
    <section className={`${s.v2Live} ${s.card}`}>
      <img
        src="/images/poortkamer-v2/nightwatch-live-hero-wide.webp"
        alt="De nachtwacht kijkt vanuit een verlichte poort over Duindorp"
      />
      <div className={s.v2LiveBody}>
        <p className={s.eyebrow}>De avond in beeld</p>
        <h2>De stroom door jullie poort</h2>
        <p>
          Hier zie je wie er onderweg is en welke groepen al bij jullie zijn geweest.
        </p>
        <div className={s.v2Queue}>
          <div>
            <Gauge />
            <strong>{metrics.nextHalfHour}</strong>
            <span>groepen in het komende halfuur</span>
          </div>
          <div>
            <Eye />
            <strong>{metrics.remainingChildren}</strong>
            <span>kinderen volgens de huidige prognose</span>
          </div>
        </div>
        {metrics.next && (
          <article className={s.v2Next}>
            <div>
              <small>Volgende verwachte groep</small>
              <strong>{metrics.next.groupCode}</strong>
            </div>
            <span>
              {portalTime(metrics.next.plannedArrivalAt)}–
              {portalTime(metrics.next.plannedDepartureAt)}
            </span>
          </article>
        )}
        <div className={s.v2Log} aria-label="Live bezoeklog">
          {room.v2.liveLog.slice(0, 5).map((entry) => (
            <article key={`${entry.groupCode}-${entry.visitedAt}`}>
              <CheckCircle2 />
              <div>
                <strong>{entry.groupCode}</strong>
                <small>
                  {entry.children} kinderen · {portalTime(entry.visitedAt)}
                </small>
              </div>
            </article>
          ))}
          {!room.v2.liveLog.length && (
            <p className={s.muted}>De eerste bezoekers moeten nog komen. Hier zie je straks de groepen die jullie hebben ontvangen.</p>
          )}
        </div>
      </div>
    </section>
  );
}

export function PoortkamerManagementV2({
  room,
  busy,
  disabled,
  canEdit,
  command,
  section,
}: {
  section: string;
  room: PortalRoom;
  busy: boolean;
  disabled: boolean;
  canEdit: boolean;
  command: Command;
}) {
  return (
    <>
      {section === "presentation" && <PresentationCard
        room={room}
        disabled={disabled}
        canEdit={canEdit}
        command={command}
      />
      }
      {section === "incident" && <IncidentCard room={room} disabled={disabled} command={command} />}
      {section === "simulation" && <SimulationCard
        room={room}
        disabled={disabled || busy}
        command={command}
      />
      }
    </>
  );
}

function PresentationCard({
  room,
  disabled,
  canEdit,
  command,
}: {
  room: PortalRoom;
  disabled: boolean;
  canEdit: boolean;
  command: Command;
}) {
  const current = room.v2.presentation;
  const approved = room.v2.presentationVersions.find(
    (version) => version.status === "approved",
  );
  return (
    <section className={`${s.card} ${s.v2Feature}`}>
      <img
        className={s.cardImage}
        src="/images/poortkamer-v2/gate-presentation-hero-wide.webp"
        alt="Een zorgvuldig gepresenteerde Halloweenpoort"
      />
      <p className={s.eyebrow}>Poortpresentatie</p>
      <h2>Het verhaal dat kinderen meenemen</h2>
      <p>
        Na een bevestigd bezoek bewaart het Poortenboek de op dat moment actieve,
        goedgekeurde versie. Adres- en contactgegevens komen er nooit in.
      </p>
      {current && (
        <aside className={s.v2Status}>
          <FileCheck2 />
          <div>
            <strong>{current.publicName}</strong>
            <small>Versie {current.version} · {presentationStatus(current.status)}</small>
            {current.reviewNote && <p>{current.reviewNote}</p>}
          </div>
        </aside>
      )}
      {canEdit && approved && (
        <button
          type="button"
          className={`${s.button} ${s.primary}`}
          disabled={disabled}
          onClick={() =>
            void command("presentation_activate", {
              presentationId: approved.id,
            })
          }
        >
          <Sparkles /> Goedgekeurde versie activeren
        </button>
      )}
      {canEdit && (
        <details className={s.v2Details}>
          <summary>Nieuwe versie schrijven</summary>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              const submitter = (event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null;
              void command(
                submitter?.value === "submit"
                  ? "presentation_submit"
                  : "presentation_save",
                Object.fromEntries(new FormData(event.currentTarget)),
              );
            }}
          >
            <label>
              Publieke poortnaam
              <input name="publicName" required minLength={2} maxLength={120} defaultValue={current?.publicName ?? room.portal.name} />
            </label>
            <label>
              Korte beschrijving
              <textarea name="shortDescription" required minLength={10} maxLength={500} defaultValue={current?.shortDescription ?? room.portal.description} />
            </label>
            <label>
              Verhaalfragment
              <textarea name="story" required minLength={10} maxLength={1200} defaultValue={current?.story ?? "Achter deze poort werd de nacht even een andere wereld."} />
            </label>
            <div className={s.formGrid}>
              <label>
                Symbool
                <select name="symbol" defaultValue={current?.symbol ?? "gate"}>
                  {[["gate","Poort"],["moon","Maan"],["flame","Vlam"],["ghost","Spook"],["key","Sleutel"],["star","Ster"],["bat","Vleermuis"],["pumpkin","Pompoen"]].map(([value,label]) => <option value={value} key={value}>{label}</option>)}
                </select>
              </label>
              <label>
                Kleur
                <select name="color" defaultValue={current?.color ?? "amber"}>
                  {[["amber","Amber"],["cyan","Cyaan"],["violet","Paars"],["emerald","Smaragd"],["crimson","Karmozijn"],["moonlight","Maanlicht"]].map(([value,label]) => <option value={value} key={value}>{label}</option>)}
                </select>
              </label>
              <label>
                Sfeerintensiteit
                <select name="intensity" defaultValue={current?.intensity ?? 2}>
                  <option value="1">1 · rustig</option><option value="2">2 · spannend</option><option value="3">3 · griezelig</option><option value="4">4 · zeer spannend</option>
                </select>
              </label>
            </div>
            <label>
              Praktische toegankelijkheidsinformatie
              <textarea name="accessibility" required minLength={2} maxLength={300} defaultValue={current?.accessibility ?? "Geen extra informatie opgegeven"} />
            </label>
            <input type="hidden" name="imagePath" value="/images/poortkamer-v2/gate-presentation-hero-wide.webp" />
            <div className={s.actions}>
              <button className={s.button} type="submit" value="draft" disabled={disabled}>Concept bewaren</button>
              <button className={`${s.button} ${s.primary}`} type="submit" value="submit" disabled={disabled}>Ter beoordeling insturen</button>
            </div>
          </form>
        </details>
      )}
    </section>
  );
}

function IncidentCard({
  room,
  disabled,
  command,
}: {
  room: PortalRoom;
  disabled: boolean;
  command: Command;
}) {
  const [open, setOpen] = useState(false);
  return (
    <section className={`${s.card} ${s.v2Feature}`}>
      <img className={s.cardImage} src="/images/poortkamer-v2/incident-control-wide.webp" alt="Een verlichte operationele meldkamer" />
      <p className={s.eyebrow}>Operationele meldingen</p>
      <h2>Meld wat de ontvangst belemmert</h2>
      <p>
        Voor doorgang, techniek, drukte, toegankelijkheid, overlast en weer.
        Bij direct gevaar: bel 112. Deze melding wordt door de organisatie van
        het evenement behandeld en is geen hulpdienst.
      </p>
      <button className={s.button} type="button" onClick={() => setOpen((value) => !value)}>
        <ShieldAlert /> {open ? "Formulier sluiten" : "Probleem melden"}
      </button>
      {open && (
        <form
          className={s.v2IncidentForm}
          onSubmit={async (event) => {
            event.preventDefault();
            const ok = await command("incident_create", Object.fromEntries(new FormData(event.currentTarget)));
            if (ok) setOpen(false);
          }}
        >
          <label>
            Categorie
            <select name="category" required>
              {Object.entries(incidentLabels).map(([value, label]) => <option value={value} key={value}>{label}</option>)}
            </select>
          </label>
          <label>
            Urgentieniveau
            <select name="urgency" defaultValue="normal">
              <option value="normal">Normaal</option>
              <option value="high">Hoog · direct zichtbaar in de cockpit</option>
            </select>
          </label>
          <label>
            Wat is er aan de hand?
            <textarea name="description" minLength={10} maxLength={1000} required />
          </label>
          <label className={s.check}>
            <input type="checkbox" name="callbackRequested" value="true" />
            Ik wil graag worden teruggebeld
          </label>
          <button className={`${s.button} ${s.primary}`} disabled={disabled} type="submit">Melding versturen</button>
        </form>
      )}
      <div className={s.v2Incidents}>
        {room.v2.incidents.map((incident) => (
          <article key={incident.id} data-urgency={incident.urgency}>
            <AlertTriangle />
            <div>
              <strong>{incidentLabels[incident.category]}</strong>
              <p>{incident.description}</p>
              {incident.callbackRequested && <small> · Terugbelverzoek</small>}
              {incident.resolutionMessage && <p>{incident.resolutionMessage}</p>}
              <small>{incident.status.replace("_", " ")} · {portalTime(incident.createdAt)}</small>
            </div>
            {!['resolved','closed'].includes(incident.status) && (
              <button className={s.button} disabled={disabled} onClick={() => void command("incident_status", { incidentId: incident.id, status: "resolved" })}>Opgelost</button>
            )}
          </article>
        ))}
      </div>
    </section>
  );
}

function SimulationCard({
  room,
  disabled,
  command,
}: {
  room: PortalRoom;
  disabled: boolean;
  command: Command;
}) {
  const sim = room.v2.simulation;
  const active = sim?.state === "running";
  return (
    <section className={`${s.card} ${s.v2Feature} ${s.simulation}`}>
      <img className={s.cardImage} src="/images/poortkamer-v2/simulation-hero-wide.webp" alt="Een oefensituatie achter een verlichte poort" />
      <p className={s.eyebrow}>Oefen de avond</p>
      <h2>Oefen de avond zonder echte gegevens</h2>
      <p>
        Probeer rustig wat er gebeurt als een groep aankomt of jullie even pauze nodig hebben. In deze oefening is alles verzonnen en ontvangt niemand een echt bericht.
      </p>
      {sim && <p className={s.v2SimulationLabel}><FlaskConical /> Oefenstand · {simulationLabels[sim.phase] ?? sim.phase}</p>}
      {active && sim.scenario && (
        <div className={s.v2Queue}>
          <div><strong>{sim.scenario.visits}</strong><span>oefenbezoeken</span></div>
          <div><strong>{sim.scenario.children}</strong><span>fictieve kinderen</span></div>
        </div>
      )}
      {!active ? (
        <div className={s.actions}>
          <button className={`${s.button} ${s.primary}`} disabled={disabled} onClick={() => void command("simulation_start", {})}>Start oefenstand</button>
          {sim && <button className={s.button} disabled={disabled} onClick={() => void command("simulation_reset", { simulationRunId: sim.id })}>Oefenrun verwijderen</button>}
        </div>
      ) : (
        <div className={s.actions}>
          {(["open", "approaching", "arrived", "busy", "paused", "stopped", "incident", "chat", "seal", "finale", "completed"] as const).map((phase) => (
            <button className={s.button} key={phase} disabled={disabled} onClick={() => void command("simulation_step", { simulationRunId: sim.id, phase })}>
              {simulationLabels[phase] ?? phase} <ChevronRight />
            </button>
          ))}
          <ul className={s.muted}>
            <li>Statusbediening: {['open','paused','stopped'].includes(sim.phase) ? 'getest' : 'nog testen'}</li>
            <li>Wachtrij: gezien</li>
            <li>Chat: {sim.scenario.chatTested ? 'getest' : 'nog testen'}</li>
            <li>Incident: {sim.scenario.incident ? 'getest' : 'nog testen'}</li>
            <li>Poortenboekzegel: {sim.scenario.sealTested ? 'getest' : 'nog testen'}</li>
            <li>Eindpoort: {sim.scenario.finaleTested ? 'getest' : 'nog testen'}</li>
          </ul>
          <button className={s.button} disabled={disabled} onClick={() => void command("simulation_reset", { simulationRunId: sim.id })}>Alleen oefendata wissen</button>
        </div>
      )}
    </section>
  );
}

function presentationStatus(status: string) {
  return ({
    draft: "concept",
    submitted: "ter beoordeling",
    approved: "goedgekeurd",
    changes_requested: "aanpassing gevraagd",
    rejected: "afgewezen",
    active: "actief voor nieuwe zegels",
    retired: "historische versie",
  } as Record<string, string>)[status] ?? status;
}
