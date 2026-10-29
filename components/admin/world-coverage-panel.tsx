"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

export type WorldCoverage = {
  portalRegistrationOpen: boolean;
  status: "provisional" | "active";
  policyVersion: number | null;
  missingWorlds: string[];
  worldNames: Record<string, string>;
  pendingRevision: null | { version: number; missingWorlds: string[]; fingerprint: string; createdAt: string };
  canRevise: boolean;
};

export function WorldCoveragePanel({ coverage, eventSlug, onChanged, disabled = false }: {
  coverage?: WorldCoverage; eventSlug: string; onChanged: () => Promise<void>; disabled?: boolean;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  if (!coverage) return null;
  const names = (slugs: string[]) => slugs.map(slug => coverage.worldNames[slug] ?? slug).join(", ") || "geen";
  async function accept() {
    const client = createClient(), pending = coverage?.pendingRevision;
    if (!client || !pending || busy || disabled) return;
    setBusy(true); setNotice("");
    try {
      const { error } = await client.schema("api").rpc("admin_accept_world_coverage_revision", {
        _event_slug: eventSlug, _expected_version: pending.version,
        _expected_fingerprint: pending.fingerprint, _reason: reason.trim(),
      });
      if (error) {
        setNotice(error.message.includes("STALE_WORLD_COVERAGE") ? "Het huizenaanbod is intussen gewijzigd. Controleer de nieuwe beleidsrevisie." : "De wereldregeling is niet aangepast. Controleer je rechten en probeer opnieuw.");
      } else { setReason(""); setNotice("Wereldregeling bijgewerkt. Eerder verdiende zegels blijven behouden."); }
      await onChanged();
    } catch { setNotice("Opslag is niet bevestigd. Probeer opnieuw; dezelfde revisie wordt veilig herhaald."); }
    finally { setBusy(false); }
  }
  return <section className="panel" aria-label="Ontbrekende wereldzegels">
    <p className="kicker">Wereldcollectie · {coverage.portalRegistrationOpen ? "voorlopige dekking" : `beleid ${coverage.policyVersion ?? "—"}`}</p>
    <h3>Ontbrekende themawerelden blokkeren de planning niet.</h3>
    <p>{coverage.portalRegistrationOpen
      ? `De huisinschrijving is open. Voorlopig ontbreken: ${names(coverage.missingWorlds)}. De definitieve compensatie start pas wanneer de huisinschrijving sluit; deelnemersinschrijving staat hier los van.`
      : `Definitief ontbrekend: ${names(coverage.missingWorlds)}. Bij een echte gewone Anders-aankomst krijgt ieder aanwezig kind willekeurig een nog ontbrekende wereldzegel. Bij het laatste geschikte bezoek of de eigen afsluiting worden de overige zegels aangevuld op die bewezen aankomst.`}</p>
    <p>Plan waar mogelijk een haalbaar gewoon Anders-bezoek. Bonuszegels zijn geen extra huisbezoeken; de finale telt hiervoor niet mee.</p>
    {coverage.pendingRevision && <div className="form-warning">
      <strong>Gewijzigd huizenaanbod · beleidsrevisie {coverage.pendingRevision.version} controleren</strong>
      <p>Volgens het nieuwe aanbod ontbreken: {names(coverage.pendingRevision.missingWorlds)}. De huidige regeling blijft gelden totdat je deze wijziging beoordeelt. Verdiende zegels blijven bestaan.</p>
      {coverage.canRevise && <><label className="field"><span>Reden voor deze beleidswijziging</span><input value={reason} maxLength={500} onChange={event => setReason(event.target.value)} /></label>
        <button type="button" className="btn outline" disabled={busy || disabled || reason.trim().length < 10} onClick={() => void accept()}>Beoordeelde wereldregeling toepassen</button></>}
    </div>}
    {notice && <p role="status">{notice}</p>}
  </section>;
}
