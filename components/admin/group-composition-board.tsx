"use client";

import {
  useCallback,
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
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
  itemMatchesPreference,
  itemRepresentative,
  preferenceSummary,
  type CompositionItem,
  type CompositionRegistration,
  type MoveCheck,
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
  const [preferenceFilter, setPreferenceFilter] = useState("all");
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [createOpen, setCreateOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [activeColumnId, setActiveColumnId] = useState("unassigned");
  const [revealRequest, setRevealRequest] = useState(0);
  const mutationPending = useRef(false);
  const revealColumn = useRef<string | null>(null);
  const request = useRef(0);
  const boardRef = useRef<HTMLDivElement>(null);

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
    else {
      setSnapshot(data as Snapshot);
      if (revealColumn.current) {
        setQuery("");
        setAssignmentFilter("all");
        setTypeFilter("all");
        setGroupFilter("all");
        setPreferenceFilter("all");
        setActiveColumnId(revealColumn.current);
        setRevealRequest((value) => value + 1);
        revealColumn.current = null;
      }
    }
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
  const dividedParties = useMemo(() => dividedPartyIds(columns), [columns]);
  const checkMove = (
    item: CompositionItem,
    source: (typeof columns)[number],
    target: string | null,
  ): MoveCheck => {
    const group = target ? snapshot?.groups.find((g) => g.id === target) : null;
    return canMoveCompositionItem(item, {
      editable: Boolean(snapshot?.editable),
      sourceLocked: source.locked,
      targetLocked: Boolean(group?.locked),
      targetValid: target === null || Boolean(group),
      targetChildCount: group?.childCount ?? 0,
      maxGroupSize: snapshot?.maxGroupSize ?? 0,
      // The unassigned lane has no capacity ceiling.
      alreadyInTarget: target === null || target === source.id,
      inconsistent: Boolean(item.partyId && dividedParties.has(item.partyId)),
    });
  };
  const move = async (itemId: string, target: string | null) => {
    if (!snapshot || mutationPending.current) return;
    // Resolve both input methods against the latest complete snapshot.
    const source = columns.find((column) =>
      compositionItems(column.registrations).some((item) => item.id === itemId),
    );
    const item =
      source &&
      compositionItems(source.registrations).find((item) => item.id === itemId);
    if (!source || !item)
      return setNotice(
        "Inschrijving niet meer beschikbaar. Vernieuw de gegevens.",
      );
    const check = checkMove(item, source, target);
    if (!check.canMove)
      return setNotice(check.reason ?? "Verplaatsen is niet beschikbaar.");
    if (source.id === (target ?? "unassigned")) return;
    const client = createClient();
    if (!client) return;
    mutationPending.current = true;
    setBusy(true);
    try {
      const { data, error } = await client
        .schema("api")
        .rpc("admin_group_move_registration", {
          _event_slug: eventSlug,
          _registration_id: itemRepresentative(item).id,
          _target_group_id: target,
        });
      setNotice(
        error
          ? `Verplaatsen geweigerd: ${error.message}`
          : `${(data as { movedRegistrations?: number })?.movedRegistrations ?? item.registrations.length} inschrijving(en) verplaatst.`,
      );
      if (!error) await load();
    } finally {
      mutationPending.current = false;
      setBusy(false);
    }
  };
  const closeCreate = () => {
    setCreateOpen(false);
    setNewName("");
  };
  const create = async () => {
    if (!snapshot?.editable || mutationPending.current) return;
    const client = createClient();
    if (!client) return;
    mutationPending.current = true;
    setBusy(true);
    try {
      const { data, error } = await client
        .schema("api")
        .rpc("admin_group_create", {
          _event_slug: eventSlug,
          _display_name: newName.trim() || null,
        });
      if (error) setNotice(`Groep kon niet worden gemaakt: ${error.message}`);
      else {
        const created = data as { id?: string; systemCode?: string } | null;
        revealColumn.current = created?.id ?? null;
        await load();
        closeCreate();
        setNotice(`Nieuwe groep ${created?.systemCode ?? ""} aangemaakt.`);
      }
    } finally {
      mutationPending.current = false;
      setBusy(false);
    }
  };
  const activeFilters = [
    assignmentFilter !== "all",
    typeFilter !== "all",
    groupFilter !== "all",
    preferenceFilter !== "all",
  ].filter(Boolean).length;
  const preferenceTimes = [
    ...new Set(
      columns.flatMap((column) =>
        column.registrations.flatMap((registration) =>
          registration.preferredStartAt ? [registration.preferredStartAt] : [],
        ),
      ),
    ),
  ].sort();
  const visibleColumns = columns.flatMap((column) => {
    if (
      (assignmentFilter === "assigned" && column.id === "unassigned") ||
      (assignmentFilter === "unassigned" && column.id !== "unassigned")
    )
      return [];
    const maxGroupSize = snapshot?.maxGroupSize ?? 0;
    if (
      groupFilter !== "all" &&
      (column.id === "unassigned" ||
        !(
          (groupFilter === "locked" && column.locked) ||
          (groupFilter === "full" && column.childCount >= maxGroupSize) ||
          (groupFilter === "free" &&
            !column.locked &&
            column.childCount < maxGroupSize)
        ))
    )
      return [];
    const matchesGroup = groupMatches(column.code, column.title, query);
    const items = compositionItems(column.registrations).filter(
      (item) =>
        (matchesGroup || itemMatches(item, query)) &&
        (typeFilter === "all" ||
          (typeFilter === "together" && Boolean(item.partyId)) ||
          (typeFilter === "singles" && !item.partyId)) &&
        itemMatchesPreference(item, preferenceFilter),
    );
    if (
      !items.length &&
      (!matchesGroup || typeFilter !== "all" || preferenceFilter !== "all")
    )
      return [];
    return [{ ...column, items }];
  });
  const activeColumn = Math.max(
    0,
    visibleColumns.findIndex((column) => column.id === activeColumnId),
  );
  const selectedColumnId = visibleColumns[activeColumn]?.id ?? "";
  const visibleColumnOrder = JSON.stringify(
    visibleColumns.map((column) => column.id),
  );
  const scrollToColumn = (id: string, behavior: ScrollBehavior) => {
    const board = boardRef.current;
    const element =
      board &&
      [...board.children].find(
        (child) => (child as HTMLElement).dataset.columnId === id,
      );
    if (!board || !element || !board.firstElementChild) return;
    board.scrollTo({
      left:
        element.getBoundingClientRect().left -
        board.firstElementChild.getBoundingClientRect().left,
      behavior,
    });
  };
  const selectColumn = (index: number) => {
    const column = visibleColumns[index];
    if (!column) return;
    setActiveColumnId(column.id);
    scrollToColumn(column.id, "smooth");
  };
  const alignColumn = useEffectEvent(() => {
    setActiveColumnId(selectedColumnId);
    scrollToColumn(selectedColumnId, "instant");
  });
  useEffect(() => {
    const board = boardRef.current;
    if (!board) return;
    let frame = 0;
    const align = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => alignColumn());
    };
    align();
    const observer = new ResizeObserver(align);
    observer.observe(board);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  }, [visibleColumnOrder, revealRequest]);
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
          disabled={activeColumn === 0 || !visibleColumns.length}
          onClick={() => selectColumn(activeColumn - 1)}
        >
          <ChevronLeft />
        </button>
        <span>
          <select
            aria-label="Kies groep"
            disabled={!visibleColumns.length}
            value={selectedColumnId}
            onChange={(event) =>
              selectColumn(
                visibleColumns.findIndex(
                  (column) => column.id === event.target.value,
                ),
              )
            }
          >
            {visibleColumns.map((column) => (
              <option key={column.id} value={column.id}>
                {column.code} · {column.title}
              </option>
            ))}
          </select>
        </span>
        <button
          aria-label="Volgende groep"
          disabled={activeColumn >= visibleColumns.length - 1}
          onClick={() => selectColumn(activeColumn + 1)}
        >
          <ChevronRight />
        </button>
      </div>
      <div
        ref={boardRef}
        className="group-composition-board"
        aria-label="Groepskolommen"
        onScroll={(event) => {
          const board = event.currentTarget;
          const elements = [...board.children] as HTMLElement[];
          const first = elements[0];
          if (!first) return;
          const nearest = elements.reduce((best, element) => {
            const distance = (node: HTMLElement) =>
              Math.abs(
                node.getBoundingClientRect().left -
                  first.getBoundingClientRect().left -
                  board.scrollLeft,
              );
            return distance(element) < distance(best) ? element : best;
          });
          if (nearest.dataset.columnId)
            setActiveColumnId(nearest.dataset.columnId);
        }}
      >
        {visibleColumns.map((column) => (
          <section
            className={`group-composition-column${column.locked ? " locked" : ""}`}
            key={column.id}
            data-column-id={column.id}
            onDragOver={(e) => e.preventDefault()}
            onDrop={(e) => {
              e.preventDefault();
              void move(
                e.dataTransfer.getData("text/plain"),
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
              {column.items.map((item) => (
                <Card
                  key={item.id}
                  item={item}
                  current={column.id === "unassigned" ? null : column.id}
                  inconsistent={Boolean(
                    item.partyId && dividedParties.has(item.partyId),
                  )}
                  moveCheck={(target) =>
                    checkMove(item, column, target?.id ?? null)
                  }
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
              {!column.items.length && (
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
      {!visibleColumns.length && (
        <p role="status">Geen groepen binnen deze filters.</p>
      )}
      {filtersOpen && (
        <BoardDialog
          labelledBy="group-filter-title"
          close={() => setFiltersOpen(false)}
        >
          <button
            className="group-dialog-close"
            type="button"
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
          <label>
            Voorkeurstijd
            <select
              value={preferenceFilter}
              onChange={(event) => setPreferenceFilter(event.target.value)}
            >
              <option value="all">Alle voorkeurstijden</option>
              <option value="none">Geen voorkeur</option>
              <option value="mixed">Verschillende voorkeurstijden</option>
              {preferenceTimes.map((time) => (
                <option key={time} value={time}>
                  {clock(time)}
                </option>
              ))}
            </select>
          </label>
          <div className="actions">
            <button
              type="button"
              className="btn outline"
              onClick={() => {
                setAssignmentFilter("all");
                setTypeFilter("all");
                setGroupFilter("all");
                setPreferenceFilter("all");
              }}
            >
              Filters wissen
            </button>
            <button
              type="button"
              className="btn"
              onClick={() => setFiltersOpen(false)}
            >
              Toepassen
            </button>
          </div>
        </BoardDialog>
      )}
      {createOpen && (
        <BoardDialog labelledBy="group-create-title" close={closeCreate}>
          <button
            className="group-dialog-close"
            type="button"
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
                data-initial-focus
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
              />
            </label>
            <div className="actions">
              <button
                type="button"
                className="btn outline"
                onClick={closeCreate}
              >
                Annuleren
              </button>
              <button className="btn" disabled={busy} type="submit">
                Aanmaken
              </button>
            </div>
          </form>
        </BoardDialog>
      )}
    </section>
  );
}
function Card({
  item,
  current,
  inconsistent,
  moveCheck,
  groups,
  expanded,
  toggle,
  move,
  busy,
}: {
  item: CompositionItem;
  current: string | null;
  inconsistent: boolean;
  moveCheck: (target: Group | null) => MoveCheck;
  groups: Group[];
  expanded: boolean;
  toggle: () => void;
  move: (itemId: string, target: string | null) => Promise<void>;
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
  const movable = moveCheck(null).canMove;
  return (
    <article className="group-registration-card">
      <button
        className="drag-handle"
        aria-label={`${rep.reference} verplaatsen`}
        disabled={!movable || busy}
        draggable={movable && !busy}
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
                  item.id,
                  e.target.value === "unassigned" ? null : e.target.value,
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

function BoardDialog({
  labelledBy,
  close,
  children,
}: {
  labelledBy: string;
  close: () => void;
  children: ReactNode;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const opener = document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    dialog.showModal();
    dialog.querySelector<HTMLElement>("[data-initial-focus]")?.focus();
    document.body.style.overflow = "hidden";
    return () => {
      dialog.close();
      document.body.style.overflow = overflow;
      if (opener?.isConnected) opener.focus();
    };
  }, []);
  return (
    <dialog
      ref={dialogRef}
      className="group-create-dialog"
      aria-labelledby={labelledBy}
      aria-modal="true"
      onCancel={(event) => {
        event.preventDefault();
        close();
      }}
      onKeyDown={(event) => {
        if (event.key !== "Tab") return;
        const focusable = [
          ...event.currentTarget.querySelectorAll<HTMLElement>(
            'button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex="0"]',
          ),
        ];
        const first = focusable[0];
        const last = focusable.at(-1);
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }}
      onClick={(event) => {
        if (event.target !== event.currentTarget) return;
        const rect = event.currentTarget.getBoundingClientRect();
        if (
          event.clientX < rect.left ||
          event.clientX > rect.right ||
          event.clientY < rect.top ||
          event.clientY > rect.bottom
        )
          close();
      }}
    >
      {children}
    </dialog>
  );
}
