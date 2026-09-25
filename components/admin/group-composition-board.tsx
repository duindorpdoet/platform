"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { GripVertical, LockKeyhole, Plus, RefreshCw, UsersRound } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

type Registration = {
  id: string;
  reference: string;
  householdLabel: string;
  parentEmail: string | null;
  childCount: number;
  children: Array<{ name: string; age: number | null }>;
  partyId: string | null;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  assignmentPublished: boolean;
};

type Group = {
  id: string;
  systemCode: string;
  displayName: string | null;
  status: string;
  version: number;
  locked: boolean;
  childCount: number;
  registrations: Registration[];
};

type Snapshot = {
  eventId: string;
  phase: string;
  editable: boolean;
  maxGroupSize: number;
  realtimeTopic: string;
  groups: Group[];
  unassigned: Registration[];
};

const time = (value: string | null) => value
  ? new Intl.DateTimeFormat("nl-NL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }).format(new Date(value))
  : "geen voorkeur";

export function GroupCompositionBoard({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [moving, setMoving] = useState<Record<string, string>>( {} );
  const [connection, setConnection] = useState<"connecting" | "live" | "offline">("connecting");

  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("admin_group_composition_snapshot", { _event_slug: eventSlug });
    if (error) return setNotice(`Groepsindeling kon niet worden opgehaald: ${error.message}`);
    setSnapshot(data as Snapshot);
  }, [eventSlug]);

  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 30_000);
    return () => { window.clearTimeout(initial); window.clearInterval(poll); };
  }, [load]);

  useEffect(() => {
    const client = createClient();
    if (!client || !snapshot?.realtimeTopic) return;
    const channel = client.channel(snapshot.realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe((status: string) => setConnection(status === "SUBSCRIBED" ? "live" : status === "CHANNEL_ERROR" || status === "TIMED_OUT" ? "offline" : "connecting"));
    return () => { void client.removeChannel(channel); };
  }, [load, snapshot?.realtimeTopic]);

  const groupOptions = useMemo(() => snapshot?.groups.filter((group) => !group.locked) ?? [], [snapshot]);

  async function createGroup() {
    const displayName = window.prompt("Naam van de nieuwe groep (optioneel):")?.trim() ?? "";
    setBusy(true);
    const client = createClient();
    if (!client) return setBusy(false);
    const { error } = await client.schema("api").rpc("admin_group_create", {
      _event_slug: eventSlug,
      _display_name: displayName || null,
    });
    setBusy(false);
    setNotice(error ? `Groep kon niet worden gemaakt: ${error.message}` : "Nieuwe groep aangemaakt. Sleep nu een inschrijving naar de groep.");
    if (!error) await load();
  }

  async function moveRegistration(registrationId: string, targetGroupId: string | null) {
    if (!snapshot?.editable || busy) return;
    setBusy(true);
    const client = createClient();
    if (!client) return setBusy(false);
    const { data, error } = await client.schema("api").rpc("admin_group_move_registration", {
      _event_slug: eventSlug,
      _registration_id: registrationId,
      _target_group_id: targetGroupId,
    });
    setBusy(false);
    const result = data as { movedRegistrations?: number; childCount?: number } | null;
    setNotice(error
      ? error.message.includes("GROUPS_FINALIZED")
        ? "Deze indeling is al definitief en kan hier niet meer worden gewijzigd."
        : error.message.includes("GROUP_SIZE_LIMIT_EXCEEDED")
          ? `Deze verplaatsing overschrijdt de grens van ${snapshot.maxGroupSize} kinderen.`
          : `Verplaatsen geweigerd: ${error.message}`
      : `${result?.movedRegistrations ?? 1} inschrijving(en) met ${result?.childCount ?? 0} kinderen verplaatst.`);
    if (!error) await load();
  }

  function registrationCard(registration: Registration, currentGroupId: string | null) {
    const selectedTarget = moving[registration.id] ?? currentGroupId ?? "unassigned";
    return <article
      className="group-registration-card"
      key={registration.id}
      draggable={Boolean(snapshot?.editable && !registration.assignmentPublished)}
      onDragStart={(event) => { event.dataTransfer.effectAllowed = "move"; event.dataTransfer.setData("text/plain", registration.id); }}
    >
      <GripVertical aria-hidden="true" />
      <div>
        <strong>{registration.householdLabel}</strong>
        <span className="group-registration-children">
          {registration.children.length
            ? registration.children.map((child) => `${child.name} (${child.age === null ? "leeftijd onbekend" : `${child.age} jaar`})`).join(", ")
            : "Geen actieve kinderen"}
        </span>
        <small>{registration.reference} · {registration.childCount} kind{registration.childCount === 1 ? "" : "eren"}</small>
        <small>Start {time(registration.preferredStartAt)} · laatste poort {time(registration.desiredEndAt)}</small>
        {registration.partyId && <em>Samenloopinschrijvingen verplaatsen als één geheel</em>}
      </div>
      <div className="group-registration-move">
        <label htmlFor={`move-${registration.id}`}>Verplaats naar</label>
        <select id={`move-${registration.id}`} value={selectedTarget} disabled={!snapshot?.editable || registration.assignmentPublished || busy}
          onChange={(event) => setMoving((current) => ({ ...current, [registration.id]: event.target.value }))}>
          <option value="unassigned">Nog niet ingedeeld</option>
          {groupOptions.map((group) => <option key={group.id} value={group.id}>{group.systemCode} · {group.displayName || "Naam volgt"}</option>)}
        </select>
        <button className="btn outline" type="button" disabled={selectedTarget === (currentGroupId ?? "unassigned") || busy || !snapshot?.editable}
          onClick={() => void moveRegistration(registration.id, selectedTarget === "unassigned" ? null : selectedTarget)}>
          Verplaats
        </button>
      </div>
    </article>;
  }

  if (!snapshot) return <section className="panel loading-state"><RefreshCw className="spin" />Groepsindeling ophalen…</section>;

  const totalChildren = snapshot.groups.reduce((sum, group) => sum + group.childCount, 0) + snapshot.unassigned.reduce((sum, registration) => sum + registration.childCount, 0);
  return <div className="group-composition">
    <section className="panel group-composition-intro">
      <div>
        <p className="kicker">Samen lopen · vóór publicatie</p>
        <h2>Maak de wandelgroepen.</h2>
        <p>Sleep complete inschrijvingen naar een groep. Een goedgekeurde samenloop blijft één bundel en telt direct mee in het groepstotaal.</p>
      </div>
      <div className="group-composition-summary" aria-label="Samenvatting groepsindeling">
        <span><strong>{snapshot.groups.length}</strong> groepen</span>
        <span><strong>{totalChildren}</strong> kinderen</span>
        <span><strong>{snapshot.unassigned.reduce((sum, item) => sum + item.childCount, 0)}</strong> nog in te delen</span>
      </div>
      <div className="actions">
        <span className={`live-connection ${connection}`}><i />{connection === "live" ? "Live bijgewerkt" : connection === "offline" ? "Verbinding verbroken" : "Verbinden…"}</span>
        <button className="btn outline" type="button" onClick={() => void load()}><RefreshCw />Vernieuwen</button>
        <button className="btn" type="button" disabled={!snapshot.editable || busy} onClick={() => void createGroup()}><Plus />Groep maken</button>
      </div>
      {!snapshot.editable && <p className="form-warning"><LockKeyhole /> De groepsindeling is definitief. Gepubliceerde groepen blijven zichtbaar, maar kunnen niet meer worden verplaatst.</p>}
      {notice && <p className="form-notice" role="status">{notice}</p>}
    </section>

    <div className="group-composition-board">
      <section className="group-composition-column unassigned" onDragOver={(event) => event.preventDefault()}
        onDrop={(event) => { event.preventDefault(); void moveRegistration(event.dataTransfer.getData("text/plain"), null); }}>
        <header><div><p className="kicker">Wacht op indeling</p><h3>Nog geen groep</h3></div><span>{snapshot.unassigned.reduce((sum, item) => sum + item.childCount, 0)} kinderen</span></header>
        <div className="group-composition-dropzone">
          {snapshot.unassigned.length ? snapshot.unassigned.map((registration) => registrationCard(registration, null)) : <div className="group-composition-empty"><UsersRound /><span>Alle inschrijvingen zijn ingedeeld.</span></div>}
        </div>
      </section>
      {snapshot.groups.map((group) => <section className={`group-composition-column${group.locked ? " locked" : ""}`} key={group.id}
        onDragOver={(event) => { if (!group.locked) event.preventDefault(); }}
        onDrop={(event) => { event.preventDefault(); if (!group.locked) void moveRegistration(event.dataTransfer.getData("text/plain"), group.id); }}>
        <header>
          <div><p className="kicker">{group.systemCode}</p><h3>{group.displayName || "Naam volgt"}</h3></div>
          <span className={group.childCount > snapshot.maxGroupSize ? "over" : ""}>{group.childCount}/{snapshot.maxGroupSize} kinderen</span>
        </header>
        {group.locked && <p className="group-locked"><LockKeyhole /> Definitief</p>}
        <div className="group-composition-dropzone">
          {group.registrations.length ? group.registrations.map((registration) => registrationCard(registration, group.id)) : <div className="group-composition-empty"><UsersRound /><span>Sleep hier een inschrijving naartoe.</span></div>}
        </div>
      </section>)}
    </div>
  </div>;
}
