"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Preference = { supported: boolean; desiredOrdinaryVisits: number | null; version: number; canEdit: boolean };

export function GroupJourneyPreference({ groupId, onSaved }: { groupId: string; onSaved?: () => Promise<void> }) {
  const [preference, setPreference] = useState<Preference | null>(null);
  const [limit, setLimit] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const client = createClient();
    if (!client) return;
    const { data, error } = await client.schema("api").rpc("group_journey_preference", { _group_id: groupId });
    if (!error && data) { setPreference(data); setLimit(data.desiredOrdinaryVisits?.toString() ?? ""); }
  }, [groupId]);
  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function save() {
    if (!preference) return;
    const value = limit === "" ? null : Number(limit);
    if (value !== null && (!Number.isInteger(value) || value < 1 || value > 1000)) {
      setNotice("Vul een heel aantal vanaf 1 in, of laat het veld leeg om door te lopen zolang er tijd is."); return;
    }
    const client = createClient(); if (!client) return;
    setBusy(true); setNotice("");
    const { data, error } = await client.schema("api").rpc("group_journey_preference_save", {
      _group_id: groupId, _expected_version: preference.version, _desired_ordinary_visits: value,
    });
    setBusy(false);
    if (error) {
      setNotice(error.message.includes("JOURNEY_ALREADY_STARTED") ? "Jullie tocht is begonnen. Bespreek een wijziging met de organisatie via Messenger." : "Opslaan lukte niet. Controleer de verbinding en probeer opnieuw met de actuele gegevens.");
      await load(); return;
    }
    setPreference(data); setNotice("Voorkeur voor jullie groep opgeslagen.");
    await onSaved?.();
  }

  if (!preference?.supported) return null;
  return <section className="participant-card group-journey-card">
    <p className="participant-eyebrow">Jullie tocht</p><h2>Hoeveel huizen willen jullie bezoeken?</h2>
    <p>De groepsleider kan vóór vertrek een maximumaantal gewone huizen kiezen. Laat het veld leeg om door te lopen zolang er tijd is. Veilige routes, beschikbare huizen en jullie stopgrens kunnen de tocht korter maken. De laatste poort volgt altijd daarna.</p>
    {preference.canEdit ? <form className="group-journey-form" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <label className="participant-field"><span>Gewenst maximumaantal gewone huizen (optioneel)</span><input type="number" min={1} max={1000} step={1} inputMode="numeric" value={limit} onChange={(event) => setLimit(event.target.value)} placeholder="Zolang er tijd is" disabled={busy} /></label>
      <div className="actions"><button className="btn" disabled={busy}>{busy ? "Opslaan…" : "Aantal huizen bewaren"}</button></div>
    </form> : <p><strong>{preference.desiredOrdinaryVisits === null ? "Doorlopen zolang er tijd is" : `Maximaal ${preference.desiredOrdinaryVisits} gewone huizen`}</strong>. Wijzigingen tijdens de tocht bespreek je via Messenger.</p>}
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </section>;
}
