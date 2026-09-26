"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  GripVertical,
  LockKeyhole,
  Plus,
  RefreshCw,
  UsersRound,
  X,
} from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  canMoveCompositionItem,
  compositionItems,
  dividedPartyIds,
  groupMatches,
  itemChildren,
  itemMatches,
  itemRepresentative,
  preferenceSummary,
  type CompositionItem,
  type CompositionRegistration,
} from "@/lib/domain/group-composition";

type Registration = CompositionRegistration;
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
const clock = (value: string | null) =>
  value
    ? new Intl.DateTimeFormat("nl-NL", {
        hour: "2-digit",
        minute: "2-digit",
        timeZone: "Europe/Amsterdam",
      }).format(new Date(value))
    : "geen voorkeur";

export function GroupCompositionBoard({ eventSlug }: { eventSlug: string }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState("");
  const [assignmentFilter, setAssignmentFilter] = useState<
    "all" | "assigned" | "unassigned"
  >("all");
  const [typeFilter, setTypeFilter] = useState<"all" | "together" | "singles">(
    "all",
  );
  const [groupFilter, setGroupFilter] = useState<
    "all" | "free" | "full" | "locked"
  >("all");
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [createOpen, setCreateOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [activeColumnId, setActiveColumnId] = useState("unassigned");
  const [activeColumn, setActiveColumn] = useState(0);
  const request = useRef(0);
  const boardRef = useRef<HTMLDivElement>(null);
  const createRef = useRef<HTMLInputElement>(null);
  const createButtonRef = useRef<HTMLButtonElement>(null);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const current = ++request.current;
    const { data, error } = await client
      .schema("api")
      .rpc("admin_group_composition_snapshot", { _event_slug: eventSlug });
    if (current !== request.current) return;
    if (error)
      setNotice(`Groepsindeling kon niet worden opgehaald: ${error.message}`);
    else setSnapshot(data as Snapshot);
  }, [eventSlug]);
  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0);
    const poll = window.setInterval(() => void load(), 30_000);
    return () => {
      window.clearTimeout(initial);
      window.clearInterval(poll);
    };
  }, [load]);
  useEffect(() => {
    const client = createClient();
    if (!client || !snapshot?.realtimeTopic) return;
    const channel = client
      .channel(snapshot.realtimeTopic, { config: { private: true } })
      .on("broadcast", { event: "snapshot_changed" }, () => void load())
      .subscribe();
    return () => {
      void client.removeChannel(channel);
    };
  }, [load, snapshot?.realtimeTopic]);
  useEffect(() => {
    if (createOpen) window.setTimeout(() => createRef.current?.focus(), 0);
  }, [createOpen]);
  useEffect(() => {
    if (!createOpen) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setCreateOpen(false);
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => document.removeEventListener("keydown", closeOnEscape);
  }, [createOpen]);
  const columns = useMemo(
    () =>
      snapshot
        ? [
            {
              id: "unassigned",
              title: "Nog niet ingedeeld",
              code: "Wacht op indeling",
              locked: false,
              childCount: snapshot.unassigned.reduce(
                (n, r) => n + r.childCount,
                0,
              ),
              registrations: snapshot.unassigned,
            },
            ...snapshot.groups.map((group) => ({
              id: group.id,
              title: group.displayName || "Naam volgt",
              code: group.systemCode,
              locked: group.locked,
              childCount: group.childCount,
              registrations: group.registrations,
            })),
          ]
        : [],
    [snapshot],
  );
  const move = async (
    item: CompositionItem,
    target: string | null,
    sourceLocked = false,
    inconsistent = false,
  ) => {
    if (!snapshot || busy) return;
    const group = target ? snapshot.groups.find((g) => g.id === target) : null;
    const check = canMoveCompositionItem(item, {
      editable: snapshot.editable,
      sourceLocked,
      targetLocked: Boolean(group?.locked),
      targetValid: target === null || Boolean(group),
      targetChildCount: group?.childCount ?? 0,
      maxGroupSize: snapshot.maxGroupSize,
      alreadyInTarget:
        group?.id === undefined ? target === null && !sourceLocked : false,
      inconsistent,
    });
    if (!check.canMove) {
      setNotice(check.reason ?? "Verplaatsen is niet beschikbaar.");
      return;
    }
    const representative = itemRepresentative(item);
    setBusy(true);
    const client = createClient();
    if (!client) return setBusy(false);
    const { data, error } = await client
      .schema("api")
      .rpc("admin_group_move_registration", {
        _event_slug: eventSlug,
        _registration_id: representative.id,
        _target_group_id: target,
      });
    setBusy(false);
    setNotice(
      error
        ? `Verplaatsen geweigerd: ${error.message}`
        : `${(data as { movedRegistrations?: number })?.movedRegistrations ?? item.registrations.length} inschrijving(en) verplaatst.`,
    );
    if (!error) await load();
  };
  const closeCreate = () => {
    setCreateOpen(false);
    setNewName("");
    window.setTimeout(() => createButtonRef.current?.focus(), 0);
  };
  const create = async () => {
    if (!snapshot || busy) return;
    setBusy(true);
    const client = createClient();
    if (!client) return setBusy(false);
    const { data, error } = await client
      .schema("api")
      .rpc("admin_group_create", {
        _event_slug: eventSlug,
        _display_name: newName.trim() || null,
      });
    setBusy(false);
    if (error) setNotice(`Groep kon niet worden gemaakt: ${error.message}`);
    else {
      const created = data as { id?: string; systemCode?: string } | null;
      closeCreate();
      await load();
      if (created?.id) setActiveColumnId(created.id);
      setNotice(`Nieuwe groep ${created?.systemCode ?? ""} aangemaakt.`);
    }
  };
  const selectColumn = (index: number) => {
    const column = columns[index];
    if (!column) return;
    setActiveColumn(index);
    setActiveColumnId(column.id);
    boardRef.current?.scrollTo({
      left: index * boardRef.current.clientWidth,
      behavior: "smooth",
    });
  };
  const dividedParties = useMemo(() => dividedPartyIds(columns), [columns]);
  const activeFilters = [
    assignmentFilter !== "all",
    typeFilter !== "all",
    groupFilter !== "all",
  ].filter(Boolean).length;
  const visible = (column: (typeof columns)[number]) =>
    compositionItems(column.registrations).filter(
      (item) =>
        itemMatches(item, query) &&
        (assignmentFilter === "all" ||
          (assignmentFilter === "assigned" && column.id !== "unassigned") ||
          (assignmentFilter === "unassigned" && column.id === "unassigned")) &&
        (typeFilter === "all" ||
          (typeFilter === "together" && Boolean(item.partyId)) ||
          (typeFilter === "singles" && !item.partyId)),
    );
  const columnVisible = (column: (typeof columns)[number]) =>
    groupMatches(column.code, column.title, query) ||
    visible(column).length > 0;
  const maxGroupSize = snapshot?.maxGroupSize ?? 0;
  const matchesGroupFilter = (column: (typeof columns)[number]) =>
    groupFilter === "all" ||
    (groupFilter === "locked" && column.locked) ||
    (groupFilter === "full" && column.childCount >= maxGroupSize) ||
    (groupFilter === "free" &&
      !column.locked &&
      column.childCount < maxGroupSize);
  if (!snapshot)
    return (
      <section className="panel loading-state">
        <RefreshCw className="spin" />
        Groepsindeling ophalen…
      </section>
    );
  return (
    <section className="group-composition" aria-label="Groepsindeling">
      <div className="group-board-toolbar">
        <div>
          <p className="kicker">Samen lopen · vóór publicatie</p>
          <h2>Maak de wandelgroepen.</h2>
          <small>
            {snapshot.groups.length} groepen · {columns[0].childCount} nog in te
            delen
          </small>
        </div>
        <div className="group-board-controls">
          <input
            aria-label="Zoek in groepsindeling"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Zoek referentie, gezin, kind…"
          />
          <button
            className="btn outline"
            type="button"
            aria-expanded={filtersOpen}
            onClick={() => setFiltersOpen(true)}
          >
            Filters{activeFilters ? ` (${activeFilters})` : ""}
          </button>
          <button
            className="btn"
            type="button"
            disabled={!snapshot.editable || busy}
            ref={createButtonRef}
            onClick={() => setCreateOpen(true)}
          >
            <Plus />
            Groep aanmaken
          </button>
        </div>
      </div>
      {notice && (
        <p className="form-notice" role="status">
          {notice}
        </p>
      )}
      <div className="group-mobile-picker">
        <button
          aria-label="Vorige groep"
          disabled={activeColumn === 0}
          onClick={() => selectColumn(activeColumn - 1)}
        >
          <ChevronLeft />
        </button>
        <span>
          <select
            aria-label="Kies groep"
            value={activeColumnId}
            onChange={(event) =>
              selectColumn(
                columns.findIndex((column) => column.id === event.target.value),
              )
            }
          >
            {columns.map((column) => (
              <option key={column.id} value={column.id}>
                {column.code} · {column.title}
              </option>
            ))}
          </select>
        </span>
        <button
          aria-label="Volgende groep"
          disabled={activeColumn === columns.length - 1}
          onClick={() => selectColumn(activeColumn + 1)}
        >
          <ChevronRight />
        </button>
      </div>
      <div
        ref={boardRef}
        className="group-composition-board"
        aria-label="Groepskolommen"
        onScroll={(event) =>
          setActiveColumn(
            Math.round(
              event.currentTarget.scrollLeft / event.currentTarget.clientWidth,
            ),
          )
        }
      >
        {columns
          .filter(
            (column) => matchesGroupFilter(column) && columnVisible(column),
          )
          .map((column) => (
            <section
              className={`group-composition-column${column.locked ? " locked" : ""}`}
              key={column.id}
              onDragOver={(e) => {
                if (!column.locked) e.preventDefault();
              }}
              onDrop={(e) => {
                e.preventDefault();
                const id = e.dataTransfer.getData("text/plain");
                const source = columns
                  .flatMap((c) => compositionItems(c.registrations))
                  .find((item) => item.id === id);
                if (source)
                  void move(
                    source,
                    column.id === "unassigned" ? null : column.id,
                  );
              }}
            >
              <header>
                <div>
                  <p className="kicker">{column.code}</p>
                  <h3>{column.title}</h3>
                </div>
                <span>
                  {column.childCount}/{snapshot.maxGroupSize} kinderen
                </span>
              </header>
              {column.locked && (
                <p className="group-locked">
                  <LockKeyhole /> Definitief
                </p>
              )}
              <div
                className="group-composition-dropzone"
                aria-label={`${column.title}: inschrijvingen`}
              >
                {visible(column).map((item) => (
                  <Card
                    key={item.id}
                    item={item}
                    current={column.id === "unassigned" ? null : column.id}
                    sourceLocked={column.locked}
                    inconsistent={Boolean(
                      item.partyId && dividedParties.has(item.partyId),
                    )}
                    snapshot={snapshot}
                    groups={snapshot.groups}
                    expanded={Boolean(expanded[item.id])}
                    toggle={() =>
                      setExpanded((value) => ({
                        ...value,
                        [item.id]: !value[item.id],
                      }))
                    }
                    move={move}
                    busy={busy}
                  />
                ))}
                {!visible(column).length && (
                  <div className="group-composition-empty">
                    <UsersRound />
                    {query || activeFilters
                      ? "Geen resultaten binnen deze filters"
                      : "Deze groep is leeg"}
                  </div>
                )}
              </div>
            </section>
          ))}
      </div>
      {filtersOpen && (
        <div
          className="group-create-backdrop"
          role="presentation"
          onMouseDown={() => setFiltersOpen(false)}
        >
          <section
            className="group-create-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="group-filter-title"
            onMouseDown={(event) => event.stopPropagation()}
          >
            <button
              className="group-dialog-close"
              aria-label="Filters sluiten"
              onClick={() => setFiltersOpen(false)}
            >
              <X />
            </button>
            <h2 id="group-filter-title">Filters</h2>
            <label>
              Indeling
              <select
                value={assignmentFilter}
                onChange={(event) =>
                  setAssignmentFilter(
                    event.target.value as typeof assignmentFilter,
                  )
                }
              >
                <option value="all">Alle</option>
                <option value="unassigned">Niet ingedeeld</option>
                <option value="assigned">Ingedeeld</option>
              </select>
            </label>
            <label>
              Type
              <select
                value={typeFilter}
                onChange={(event) =>
                  setTypeFilter(event.target.value as typeof typeFilter)
                }
              >
                <option value="all">Alle</option>
                <option value="singles">Losse inschrijvingen</option>
                <option value="together">Samenloop bevestigd</option>
              </select>
            </label>
            <label>
              Groepsstatus
              <select
                value={groupFilter}
                onChange={(event) =>
                  setGroupFilter(event.target.value as typeof groupFilter)
                }
              >
                <option value="all">Alle</option>
                <option value="free">Vrije ruimte</option>
                <option value="full">Vol</option>
                <option value="locked">Vergrendeld</option>
              </select>
            </label>
            <div className="actions">
              <button
                className="btn outline"
                onClick={() => {
                  setAssignmentFilter("all");
                  setTypeFilter("all");
                  setGroupFilter("all");
                }}
              >
                Filters wissen
              </button>
              <button className="btn" onClick={() => setFiltersOpen(false)}>
                Toepassen
              </button>
            </div>
          </section>
        </div>
      )}
      {createOpen && (
        <div
          className="group-create-backdrop"
          role="presentation"
          onMouseDown={closeCreate}
        >
          <section
            className="group-create-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="group-create-title"
            onMouseDown={(e) => e.stopPropagation()}
          >
            <button
              className="group-dialog-close"
              aria-label="Sluiten"
              onClick={closeCreate}
            >
              <X />
            </button>
            <h2 id="group-create-title">Groep aanmaken</h2>
            <form
              onSubmit={(event) => {
                event.preventDefault();
                void create();
              }}
            >
              <label>
                Naam (optioneel)
                <input
                  ref={createRef}
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                />
              </label>
              <div className="actions">
                <button className="btn outline" onClick={closeCreate}>
                  Annuleren
                </button>
                <button
                  className="btn"
                  disabled={busy}
                  onClick={() => void create()}
                >
                  Aanmaken
                </button>
              </div>
            </form>
          </section>
        </div>
      )}
    </section>
  );
}
function Card({
  item,
  current,
  sourceLocked,
  inconsistent,
  snapshot,
  groups,
  expanded,
  toggle,
  move,
  busy,
}: {
  item: CompositionItem;
  current: string | null;
  sourceLocked: boolean;
  inconsistent: boolean;
  snapshot: Snapshot;
  groups: Group[];
  expanded: boolean;
  toggle: () => void;
  move: (
    item: CompositionItem,
    target: string | null,
    sourceLocked?: boolean,
    inconsistent?: boolean,
  ) => Promise<void>;
  busy: boolean;
}) {
  const rep = itemRepresentative(item);
  const multiple = item.registrations.length > 1;
  const preference = preferenceSummary(item);
  const preferenceLabel =
    preference.kind === "none"
      ? "Geen voorkeur"
      : preference.kind === "mixed"
        ? "Verschillende voorkeurstijden"
        : `Voorkeur ${clock(preference.value)}`;
  const moveCheck = (target: Group | null) =>
    canMoveCompositionItem(item, {
      editable: snapshot.editable,
      sourceLocked,
      targetLocked: Boolean(target?.locked),
      targetValid: target === null || Boolean(target),
      targetChildCount: target?.childCount ?? 0,
      maxGroupSize: snapshot.maxGroupSize,
      alreadyInTarget: target?.id === current,
      inconsistent,
    });
  const movable = moveCheck(null).canMove;
  return (
    <article className="group-registration-card">
      <button
        className="drag-handle"
        aria-label={`${rep.reference} verplaatsen`}
        draggable={movable}
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = "move";
          e.dataTransfer.setData("text/plain", item.id);
        }}
      >
        <GripVertical />
      </button>
      <div className="registration-card-summary">
        <strong>
          {rep.reference}
          {multiple && ` (+${item.registrations.length - 1})`}
        </strong>
        <span>{rep.householdLabel || "Huishouden onbekend"}</span>
        <small>
          {itemChildren(item)} kinderen ·{" "}
          {multiple
            ? `Samenloop bevestigd · ${preferenceLabel}`
            : `Voorkeur ${clock(rep.preferredStartAt)}`}
        </small>
        {inconsistent && (
          <small className="form-warning">
            Samenloop verdeeld over meerdere groepen. Vernieuw eerst.
          </small>
        )}
      </div>
      <button
        className="accordion-toggle"
        aria-expanded={expanded}
        aria-controls={`details-${item.id}`}
        aria-label="Details tonen"
        onClick={toggle}
      >
        <ChevronDown />
      </button>
      {expanded && (
        <div id={`details-${item.id}`} className="registration-details">
          {item.registrations.map((registration) => (
            <div key={registration.id}>
              <strong>{registration.reference}</strong>
              <span>
                {registration.householdLabel || "Contact niet beschikbaar"}
                {registration.parentEmail
                  ? ` · ${registration.parentEmail}`
                  : ""}
              </span>
              <small>
                {registration.children.length
                  ? registration.children
                      .map(
                        (child) =>
                          `${child.name} (${child.age === null ? "leeftijd onbekend" : `${child.age} jaar`})`,
                      )
                      .join(", ")
                  : "Geen actieve kinderen"}
              </small>
              <small>
                Start {clock(registration.preferredStartAt)} · einde{" "}
                {clock(registration.desiredEndAt)}
              </small>
            </div>
          ))}
          <label>
            Verplaatsen naar…
            <select
              disabled={!movable || busy}
              value={current ?? "unassigned"}
              onChange={(e) =>
                void move(
                  item,
                  e.target.value === "unassigned" ? null : e.target.value,
                  sourceLocked,
                  inconsistent,
                )
              }
            >
              <option value="unassigned">Nog niet ingedeeld</option>
              {groups.map((g) => {
                const check = moveCheck(g);
                return (
                  <option
                    key={g.id}
                    value={g.id}
                    disabled={!check.canMove && g.id !== current}
                  >
                    {g.systemCode} · {g.displayName || "Naam volgt"}
                    {!check.canMove && g.id !== current
                      ? ` — ${check.reason}`
                      : ""}
                  </option>
                );
              })}
            </select>
            {!movable && (
              <small className="form-warning">{moveCheck(null).reason}</small>
            )}
          </label>
        </div>
      )}
    </article>
  );
}
