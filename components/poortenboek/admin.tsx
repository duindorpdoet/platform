"use client";
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
    <section className="panel">
      <p className="kicker">Kindomgeving · teamnamen</p>
      <h2>Het Poortenboek</h2>
      <p>
        Beheer de keuzenamen en sluitingsmomenten. Een naam die in een
        verkiezing is gebruikt, blijft behouden. Dit verandert geen
        organisatorische wandelgroep.
      </p>
      {notice && (
        <p role="status" className="form-notice">
          {notice}
        </p>
      )}
      {settings && (
        <>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              void save("save");
            }}
          >
            <div className="poortenboek-admin-dates">
              {(
                [
                  ["roundOneDeadline", "Einde ronde één"],
                  ["roundTwoDeadline", "Einde finale"],
                  ["closesAt", "Definitieve sluiting"],
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
          </form>
          <h3>Teamnaamverkiezingen</h3>
          {settings.elections.map((election) => (
            <div className="poortenboek-admin-election" key={election.teamId}>
              <span>
                <strong>{election.winner ?? "Naam nog niet gekozen"}</strong>
                <br />
                {election.memberCount} kinderen ·{" "}
                {
                  (
                    {
                      direct: "Directe keuze",
                      round_one: "Ronde één",
                      round_two: "Finale",
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
          ))}
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
