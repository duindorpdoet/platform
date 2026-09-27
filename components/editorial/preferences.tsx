"use client";
import { useEffect, useState } from "react";
import { PushNotificationSettings } from "@/components/pwa/pwa-experience";
import "./editorial.css";
type Preferences = {
  email: boolean;
  parentsPush: boolean;
  housesPush: boolean;
  consentedAt: string | null;
  source: string | null;
  unsubscribedAt: string | null;
  devices: {
    id: string;
    label: string;
    active: boolean;
    lastUsed: string | null;
  }[];
};
export function CommunicationPreferences() {
  const [value, setValue] = useState<Preferences | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/editorial/preferences", {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (r) => {
        const body = await r.json();
        if (!r.ok) throw new Error(body.error?.message);
        setValue(body.data);
      })
      .catch((cause) => {
        if (cause.name !== "AbortError")
          setMessage(cause.message || "Voorkeuren konden niet worden geladen.");
      });
    return () => controller.abort();
  }, []);
  async function save() {
    if (!value || busy) return;
    setBusy(true);
    setMessage("");
    try {
      const r = await fetch("/api/editorial/preferences", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          email: value.email,
          parentsPush: value.parentsPush,
          housesPush: value.housesPush,
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error?.message);
      setValue(body.data);
      setMessage("Je communicatievoorkeuren zijn opgeslagen.");
    } catch (cause) {
      setMessage(
        cause instanceof Error ? cause.message : "Probeer het later opnieuw.",
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="editorial-preferences">
      <p className="kicker">Jij kiest wat je ontvangt</p>
      <h1>Nieuws op jouw manier.</h1>
      <p>
        Nachtpost is onze afmeldbare nieuwsbrief. Betaling, starttijd,
        veiligheid en andere belangrijke deelnameberichten blijven beschikbaar.
      </p>
      <p role="status">{message}</p>
      {value ? (
        <form
          className="editorial-panel"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <label className="editorial-check">
            <input
              type="checkbox"
              checked={value.email}
              onChange={(e) => setValue({ ...value, email: e.target.checked })}
            />
            <span>
              <strong>Nachtpost per e-mail</strong>
              <small>Verhalen en nieuws van De Duindorpse Poorten.</small>
            </span>
          </label>
          <label className="editorial-check">
            <input
              type="checkbox"
              checked={value.parentsPush}
              onChange={(e) =>
                setValue({ ...value, parentsPush: e.target.checked })
              }
            />
            <span>
              <strong>Push voor oudernieuws</strong>
              <small>
                Alleen wanneer je toegang hebt tot het ouderportaal.
              </small>
            </span>
          </label>
          <label className="editorial-check">
            <input
              type="checkbox"
              checked={value.housesPush}
              onChange={(e) =>
                setValue({ ...value, housesPush: e.target.checked })
              }
            />
            <span>
              <strong>Push voor huizennieuws</strong>
              <small>
                Alleen wanneer je toegang hebt tot het huizenportaal.
              </small>
            </span>
          </label>
          <button className="btn" type="submit" disabled={busy}>
            {busy ? "Opslaan…" : "Voorkeuren opslaan"}
          </button>
          {value.consentedAt && (
            <p className="editorial-meta">
              Toestemming vastgelegd op{" "}
              {new Date(value.consentedAt).toLocaleString("nl-NL", {
                timeZone: "Europe/Amsterdam",
              })}{" "}
              via{" "}
              {value.source === "legacy_preferences"
                ? "je bestaande accountvoorkeuren"
                : "je communicatievoorkeuren"}
              .
            </p>
          )}
          {value.unsubscribedAt && (
            <p className="editorial-meta">
              Afgemeld op{" "}
              {new Date(value.unsubscribedAt).toLocaleString("nl-NL", {
                timeZone: "Europe/Amsterdam",
              })}
              .
            </p>
          )}
        </form>
      ) : (
        !message && <p aria-busy="true">Voorkeuren worden opgehaald…</p>
      )}
      <PushNotificationSettings />
      {value && (
        <section className="editorial-panel">
          <h2>Jouw apparaten</h2>
          <p>
            Activeren doe je op ieder apparaat zelf. Toestemming voor de browser
            en jouw nieuwskeuze zijn beide nodig.
          </p>
          {value.devices.length ? (
            value.devices.map((d) => (
              <div className="summary-row" key={d.id}>
                <span>{d.label}</span>
                <strong>{d.active ? "Actief" : "Uitgeschakeld"}</strong>
              </div>
            ))
          ) : (
            <p>Er zijn nog geen apparaten verbonden.</p>
          )}
        </section>
      )}
    </div>
  );
}
