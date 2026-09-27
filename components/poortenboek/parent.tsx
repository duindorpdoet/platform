"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { BookOpen, Copy, KeyRound, LogOut, RefreshCw } from "lucide-react";

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
    return () => window.clearTimeout(timer);
  }, [load]);
  if (!children.length && !notice) return null;
  return (
    <section className="panel" aria-label="Poortenboeken van jouw kinderen">
      <p className="kicker">Een eigen avontuur</p>
      <h2>
        <BookOpen size={25} /> Het Poortenboek
      </h2>
      <p>
        Elk kind opent een eigen Poortenboek met een persoonlijke code. De code
        geeft alleen toegang tot de kinderomgeving.
      </p>
      {notice && <p role="status">{notice}</p>}
      {children.map((child) => (
        <ChildBook key={child.id} child={child} reload={load} />
      ))}
    </section>
  );
}
function ChildBook({
  child,
  reload,
}: {
  child: Child;
  reload: () => Promise<void>;
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
              ? "De teamnaamverkiezing is opnieuw gestart."
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
          Teamnaamverkiezing opnieuw starten
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
                : "Teamnaamverkiezing opnieuw starten?"}
          </strong>
          <p>
            {confirm === "renew"
              ? "De oude code wordt meteen ongeldig. Alle apparaten van dit kind worden uitgelogd. Persoonlijke voortgang blijft bewaard."
              : confirm === "revoke"
                ? "Dit kind moet op ieder apparaat opnieuw de code invullen. De code zelf blijft geldig."
                : "Hiermee vervallen de huidige stemronde en teamnaam voor alle bevestigde reisgenootjes. Dit kan alleen vóór de organisatorische sluitingsdatum."}
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
