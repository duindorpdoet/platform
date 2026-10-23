"use client";
/* eslint-disable @next/next/no-location-assign-relative-destination -- Changing child identity requires a full document request without retained private router state. */
import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { BookOpen, Copy, KeyRound, LogOut, RefreshCw, Sparkles } from "lucide-react";

type Child = {
  id: string;
  firstName: string;
  activeSessions: number;
  lastUsedAt: string | null;
  together: boolean;
};
export function ParentPoortenboek() {
  const [children, setChildren] = useState<Child[]>([]);
  const [notice, setNotice] = useState("");
  const [openingChildId, setOpeningChildId] = useState<string | null>(null);
  const opening = useRef(false);
  async function openBook(childId: string) {
    if (opening.current) return;
    opening.current = true;
    setOpeningChildId(childId);
    setNotice("");
    let leaving = false;
    try {
      const result = await fetch("/api/poortenboek/parent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({ action: "open", childId }),
      });
      if (!result.ok) {
        setNotice(
          "Dit Poortenboek kon niet worden geopend. Controleer of je nog bent ingelogd en probeer opnieuw.",
        );
        return;
      }
      window.location.assign("/poortenboek");
      leaving = true;
    } catch {
      setNotice("Maak verbinding om het Poortenboek te openen.");
    } finally {
      if (!leaving) {
        opening.current = false;
        setOpeningChildId(null);
      }
    }
  }
  const load = useCallback(async () => {
    try {
      const result = await fetch("/api/poortenboek/parent", {
        cache: "no-store",
      });
      if (result.ok) setChildren(await result.json());
      else setNotice("Poortenboekbeheer kon niet worden opgehaald.");
    } catch {
      setNotice("Maak verbinding om de Poortenboeken te beheren.");
    }
  }, []);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    const restored = (event: PageTransitionEvent) => {
      if (!event.persisted) return;
      opening.current = false;
      setOpeningChildId(null);
      void load();
    };
    window.addEventListener("pageshow", restored);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("pageshow", restored);
    };
  }, [load]);
  if (!children.length && !notice) return null;
  return (
    <section className="panel" aria-label="Poortenboeken van jouw kinderen">
      <p className="kicker">Een eigen avontuur</p>
      <h2>
        <BookOpen size={25} /> Het Poortenboek
      </h2>
      <p>
        Open het Poortenboek van je kind direct op dit apparaat. Je blijft zelf
        ingelogd als ouder. Met de persoonlijke code kan je kind ook op een ander
        apparaat inloggen.
      </p>
      {children.some((child) => child.together) && <p className="note"><Sparkles size={17} /> Alleen jij als volwassene kunt een veilige teamkaart maken. Kindcodes krijgen nooit toegang tot delen. <Link className="text-link" href="/deel-de-magie">Maak een teamkaart</Link></p>}
      {notice && <p role="status">{notice}</p>}
      {children.map((child) => (
        <ChildBook
          key={child.id}
          child={child}
          reload={load}
          openingChildId={openingChildId}
          openBook={openBook}
        />
      ))}
    </section>
  );
}
function ChildBook({
  child,
  reload,
  openingChildId,
  openBook,
}: {
  child: Child;
  reload: () => Promise<void>;
  openingChildId: string | null;
  openBook: (childId: string) => Promise<void>;
}) {
  const [code, setCode] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [confirm, setConfirm] = useState<"renew" | "revoke" | "reset" | null>(
    null,
  );
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const pending = useRef(false);
  useEffect(() => {
    const clear = () => setCode(null);
    window.addEventListener("pagehide", clear);
    return () => window.removeEventListener("pagehide", clear);
  }, []);
  async function action(value: "view" | "renew" | "revoke" | "reset") {
    if (pending.current) return;
    pending.current = true;
    setBusy(true);
    setNotice("");
    try {
      const result = await fetch("/api/poortenboek/parent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({
          action: value,
          childId: child.id,
          ...(value === "reset" ? { reason } : {}),
        }),
      });
      const data = await result.json();
      if (!result.ok) {
        setNotice(data.error ?? "Dit kon niet worden opgeslagen.");
        return;
      }
      if (data.code) setCode(data.code);
      setConfirm(null);
      setReason("");
      setNotice(
        value === "renew"
          ? "Nieuwe code gemaakt. De oude code en alle eerdere kindersessies zijn afgesloten."
          : value === "revoke"
            ? "Alle kindersessies zijn afgesloten."
            : value === "reset"
              ? "De teamnaamverkiezing en het teamvaandel zijn opnieuw gestart."
              : "Bewaar deze code bij je. Deel hem alleen met je kind.",
      );
      await reload();
    } catch {
      setNotice("Even geen verbinding. Probeer opnieuw.");
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }
  return (
    <article
      className="poortenboek-parent-child"
      aria-label={`Poortenboek van ${child.firstName}`}
    >
      <h3>{child.firstName}</h3>
      <p>
        {child.activeSessions} actieve kindersessie
        {child.activeSessions !== 1 ? "s" : ""} · Laatst gebruikt:{" "}
        {child.lastUsedAt
          ? new Intl.DateTimeFormat("nl-NL", {
              dateStyle: "short",
              timeStyle: "short",
              timeZone: "Europe/Amsterdam",
            }).format(new Date(child.lastUsedAt))
          : "nog niet"}
      </p>
      {code && (
        <output
          className="poortenboek-parent-code"
          aria-label={`Poortenboekcode van ${child.firstName}`}
        >
          {code}
        </output>
      )}
      <div className="poortenboek-parent-actions">
        <button
          type="button"
          className="btn"
          disabled={busy || openingChildId !== null}
          onClick={() => void openBook(child.id)}
          aria-label={`Open Poortenboek van ${child.firstName}`}
        >
          <BookOpen size={16} />
          {openingChildId === child.id ? "Poortenboek openen…" : "Open Poortenboek"}
        </button>
        <button
          type="button"
          className="btn outline"
          disabled={busy}
          onClick={() => void action("view")}
        >
          <KeyRound size={16} />
          {code ? "Code opnieuw bekijken" : "Code bekijken"}
        </button>
        {code && (
          <button
            type="button"
            className="btn outline"
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(code);
                setNotice("Code gekopieerd.");
              } catch {
                setNotice(
                  "Kopiëren lukt niet op dit apparaat. Neem de zes tekens over.",
                );
              }
            }}
          >
            <Copy size={16} />
            Code kopiëren
          </button>
        )}
        <button
          type="button"
          className="btn outline"
          disabled={busy}
          onClick={() => setConfirm("renew")}
        >
          <RefreshCw size={16} />
          Code vernieuwen
        </button>
        <button
          type="button"
          className="btn outline"
          disabled={busy}
          onClick={() => setConfirm("revoke")}
        >
          <LogOut size={16} />
          Alle kindersessies afsluiten
        </button>
        <button
          type="button"
          className="btn outline"
          disabled={busy}
          onClick={() => setConfirm("reset")}
        >
          Teamkeuzes opnieuw starten
        </button>
      </div>
      {child.together && (
        <p className="form-notice">
          Kinderen binnen deze bevestigde samenloop kunnen in hun afgeschermde
          Poortenboek elkaars voornaam en automatisch toegewezen medaillon zien.
        </p>
      )}
      {confirm && (
        <div
          className="poortenboek-parent-confirm"
          role="group"
          aria-label="Poortenboekactie bevestigen"
        >
          <strong>
            {confirm === "renew"
              ? "Code vernieuwen?"
              : confirm === "revoke"
                ? "Alle kindersessies afsluiten?"
                : "Teamnaam en vaandel opnieuw starten?"}
          </strong>
          <p>
            {confirm === "renew"
              ? "De oude code wordt meteen ongeldig. Alle apparaten van dit kind worden uitgelogd. Persoonlijke voortgang blijft bewaard."
              : confirm === "revoke"
                ? "Dit kind moet op ieder apparaat opnieuw de code invullen. De code zelf blijft geldig."
                : "Hiermee vervallen de huidige stemronde, teamnaam en vaandelstemmen voor alle bevestigde reisgenootjes. Een ouder kan dit één keer doen en alleen vóór de organisatorische sluitingsdatum."}
          </p>
          {confirm === "reset" && (
            <label>
              Reden
              <textarea
                value={reason}
                minLength={10}
                maxLength={500}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
          )}
          <div className="poortenboek-parent-actions">
            <button
              type="button"
              className="btn outline"
              disabled={busy}
              onClick={() => setConfirm(null)}
            >
              Annuleren
            </button>
            <button
              type="button"
              className="btn"
              disabled={
                busy || (confirm === "reset" && reason.trim().length < 10)
              }
              onClick={() => void action(confirm)}
            >
              Ja, bevestigen
            </button>
          </div>
        </div>
      )}
      {notice && <p role="status">{notice}</p>}
    </article>
  );
}
