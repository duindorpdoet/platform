"use client";
import Link from "next/link";
import { BookOpen, CalendarDays, Users } from "lucide-react";
import "@/components/ui/chat.css";
import { useCallback, useEffect, useRef, useState } from "react";
import { AdminDialog } from "@/components/admin/admin-dialog";
type Settings = {
  roundOneDeadline: string;
  roundTwoDeadline: string;
  closesAt: string;
  options: Array<{
    id: string;
    label: string;
    active: boolean;
    sortOrder: number;
    inUse: boolean;
  }>;
  elections: Array<{
    teamId: string;
    teamLabel?: string;
    phase: string;
    memberCount: number;
    winner: string | null;
  }>;
};
const localDate = (value: string) => {
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
    .toISOString()
    .slice(0, 16);
};
export function PoortenboekAdmin() {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const pending = useRef(false);
  const [now] = useState(() => Date.now());
  const [tab, setTab] = useState("overview");
  const [reset, setReset] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const load = useCallback(async () => {
    try {
      const result = await fetch("/api/poortenboek/admin", {
        cache: "no-store",
      });
      if (!result.ok) throw new Error();
      setSettings(await result.json());
    } catch {
      setNotice("Poortenboekbeheer kon niet worden opgehaald.");
    }
  }, []);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);
  async function save(action: "save" | "reset") {
    if (pending.current || !settings) return;
    if (action === "save" && !(Date.parse(settings.roundOneDeadline) < Date.parse(settings.roundTwoDeadline) && Date.parse(settings.roundTwoDeadline) <= Date.parse(settings.closesAt))) {
      setNotice("Laat de laatste keuzedatum na de favorietendatum vallen. De definitieve datum moet op of na de laatste keuzedatum liggen.");
      return;
    }
    pending.current = true;
    setBusy(true);
    try {
      const result = await fetch("/api/poortenboek/admin", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        cache: "no-store",
        body: JSON.stringify({
          action,
          payload:
            action === "reset"
              ? { teamId: reset, reason }
              : { ...settings, elections: undefined },
        }),
      });
      const data = await result.json();
      if (!result.ok) {
        setNotice(data.error);
        return;
      }
      setSettings(data);
      setReset(null);
      setReason("");
      setNotice("Poortenboekinstellingen opgeslagen.");
    } catch {
      setNotice("Opslaan is niet bevestigd. Probeer opnieuw.");
    } finally {
      pending.current = false;
      setBusy(false);
    }
  }
  return (
    <section className="poortenboek-admin">
      <header className="workspace-heading"><div><p className="kicker">Het avontuur van de kinderen</p><h2>Poortenboek</h2><p>Help de kindteams op weg en bepaal uit welke namen zij kunnen kiezen.</p></div><Link className="btn outline" href="/poortenboek/inloggen"><BookOpen size={17} />Bekijk de ingang</Link></header>
      <nav className="workspace-tabs" aria-label="Poortenboek beheren">{[["overview", "Overzicht"], ["names", "Namen & stemtijd"], ["teams", "Kindteams"]].map(([key, label]) => <button type="button" key={key} aria-pressed={tab === key} onClick={() => setTab(key)}>{label}</button>)}</nav>
      {notice && (
        <p role="status" className="form-notice">
          {notice}
        </p>
      )}
      {!settings && !notice && <p role="status">Poortenboek ophalen…</p>}
      {settings && (
        <>
          {tab === "overview" && <>
            <div className="book-admin-grid"><article><strong>{settings.elections.length}</strong><p>Kindteams met een Poortenboek</p></article><article><strong>{settings.elections.filter(e => e.winner).length}</strong><p>Teamnamen bekend</p></article><article><strong>{settings.options.filter(o => o.active).length}</strong><p>Namen om uit te kiezen</p></article></div>
            <div className="book-admin-guide"><article><BookOpen /><h3>Dit beleven de kinderen</h3><p>Een eigen boek met voorbereiding, reisgenootjes, een teamnaam, vaandel en verschijning. Tijdens de tocht komen er zegels en verhalen bij.</p><p>Ouders openen het boek bij hun inschrijving of geven het kind een eigen code.</p><Link className="text-link" href="/ontdek#poortenboek">Bekijk de uitleg voor ouders →</Link></article><article><Users /><h3>Een kindteam is een reisgezelschap</h3><p>Kinderen van dezelfde inschrijving en een goedgekeurde samenloop kiezen samen. Een grote wandelgroep kan meerdere kindteams bevatten.</p><button type="button" className="btn outline" onClick={() => setTab("teams")}>Bekijk kindteams</button></article></div>
            <article className="panel"><div className="workspace-heading"><div><p className="kicker">Samen een naam kiezen</p><h3><CalendarDays size={20} /> Tot wanneer kan het?</h3><p>Stemmen kan tot {new Date(settings.roundOneDeadline).toLocaleString("nl-NL", { dateStyle: "long", timeStyle: "short" })}. Zodra iedereen heeft gekozen kan de naam eerder bekend zijn.</p></div><button type="button" className="btn outline" onClick={() => setTab("names")}>Stemtijd aanpassen</button></div></article>
          </>}
          {tab === "names" && <section className="panel"><h3>Namen & stemtijd</h3><p>Kinderen kiezen maximaal drie favorieten. Namen die al gekozen zijn, blijven bewaard bij het team.</p>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              void save("save");
            }}
          >
            <div className="poortenboek-admin-dates">
              {(
                [
                  ["roundOneDeadline", "Teamfavorieten kiezen tot"],
                  ["roundTwoDeadline", "Laatste keuze mogelijk tot"],
                  ["closesAt", "Teamkeuze definitief op"],
                ] as const
              ).map(([key, label]) => (
                <label key={key}>
                  {label}
                  <input
                    type="datetime-local"
                    required
                    value={localDate(settings[key])}
                    onChange={(event) => {
                      if (event.target.value)
                        setSettings({
                          ...settings,
                          [key]: new Date(event.target.value).toISOString(),
                        });
                    }}
                  />
                </label>
              ))}
            </div>
            <p>De laatste keuzedatum geldt voor kinderen die alleen kiezen en teams die nog een eindkeuze maken. Tot de definitieve datum kun je een team opnieuw laten kiezen.</p><h4>Beschikbare teamnamen</h4><p>Vink namen aan die kinderen mogen kiezen. Met het getal bepaal je de volgorde.</p>
            <div className="poortenboek-admin-options">
              {settings.options.map((option) => (
                <label key={option.id}>
                  <input
                    type="checkbox"
                    checked={option.active}
                    disabled={option.inUse || busy}
                    onChange={(event) =>
                      setSettings({
                        ...settings,
                        options: settings.options.map((value) =>
                          value.id === option.id
                            ? { ...value, active: event.target.checked }
                            : value,
                        ),
                      })
                    }
                  />
                  <span>
                    {option.label}
                    {option.inUse && " · in gebruik"}
                  </span>
                  <input
                    aria-label={`Volgorde ${option.label}`}
                    type="number"
                    min={0}
                    max={1000}
                    value={option.sortOrder}
                    onChange={(event) =>
                      setSettings({
                        ...settings,
                        options: settings.options.map((value) =>
                          value.id === option.id
                            ? {
                                ...value,
                                sortOrder: Number(event.target.value),
                              }
                            : value,
                        ),
                      })
                    }
                  />
                </label>
              ))}
            </div>
            <button type="submit" className="btn" disabled={busy}>
              Instellingen opslaan
            </button>
          </form></section>}
          {tab === "teams" && <section><h3>Kindteams</h3><p>Bekijk welke teams nog kiezen en welke naam zij hebben gekozen. Opnieuw starten laat het hele team opnieuw kiezen.</p>
          {settings.elections.length === 0 && <div className="panel"><h3>De eerste teams zijn nog onderweg</h3><p>Zodra kinderen hun Poortenboek openen, vind je hun team hier terug.</p></div>}
          {settings.elections.map((election) => (
            <div className="poortenboek-admin-election" key={election.teamId}>
              <span>
                <strong>{election.winner ?? "Samen een naam kiezen"}</strong>
                <small>{election.teamLabel ?? "Reisgezelschap"}</small>
                {election.memberCount} kinderen ·{" "}
                {
                  (
                    {
                      direct: "Directe keuze",
                      round_one: "Stemmen staat open",
                      round_two: "Laatste keuze",
                      finished: "Afgerond",
                    } as Record<string, string>
                  )[election.phase]
                }
              </span>
              <button
                className="btn outline"
                disabled={busy || new Date(settings.closesAt).getTime() <= now}
                onClick={() => setReset(election.teamId)}
              >
                Opnieuw starten
              </button>
            </div>
          ))}</section>}
        </>
      )}
      {reset && (
        <AdminDialog
          labelledBy="pb-reset-title"
          close={() => {
            if (!pending.current) setReset(null);
          }}
        >
          <h2 id="pb-reset-title">Teamnaam opnieuw kiezen</h2>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              void save("reset");
            }}
          >
            <p>
              De huidige ronde en teamnaam vervallen voor alle reisgenootjes van
              dit team.
            </p>
            <label>
              Reden
              <textarea
                data-initial-focus
                value={reason}
                required
                minLength={10}
                maxLength={500}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
            <div className="actions">
              <button
                className="btn outline"
                type="button"
                disabled={busy}
                onClick={() => setReset(null)}
              >
                Annuleren
              </button>
              <button
                className="btn"
                type="submit"
                disabled={busy || reason.trim().length < 10}
              >
                Verkiezing opnieuw starten
              </button>
            </div>
          </form>
        </AdminDialog>
      )}
    </section>
  );
}
