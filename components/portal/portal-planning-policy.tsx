"use client";

import { useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { PortalPlanningPolicyFields, type PortalPlanningPolicy } from "@/components/admin/portal-planning-policy-fields";
import type { PortalRoom } from "@/lib/domain/poortkamer";

type Edit = { version: number; policy: PortalPlanningPolicy };
export function PortalPlanningPolicyEditor({ portal, onChanged, disabled = false }: {
  portal: PortalRoom["portal"];
  onChanged: () => Promise<void>;
  disabled?: boolean;
}) {
  const [edit, setEdit] = useState<Edit | null>(null), [busy, setBusy] = useState(false), [notice, setNotice] = useState("");
  const request = useRef<{ signature: string; key: string } | null>(null), saving = useRef(false);
  const current: PortalPlanningPolicy | null = typeof portal.arrivalHeadwaySeconds === "number" && typeof portal.ordinaryEndGraceSeconds === "number" && typeof portal.ordinaryHardClose === "boolean"
    ? { arrivalHeadwaySeconds: portal.arrivalHeadwaySeconds, ordinaryEndGraceSeconds: portal.ordinaryEndGraceSeconds, ordinaryHardClose: portal.ordinaryHardClose, accessibilityStatus: portal.accessibilityStatus ?? null } : null;
  const canManage = portal.canManagePlanningPolicy === true, stale = edit !== null && edit.version !== portal.version;
  async function save() {
    if (!edit || !canManage || stale || disabled || saving.current) return;
    const client = createClient(); if (!client) return;
    const args = { _portal_id: portal.id, _expected_version: edit.version, _payload: edit.policy };
    const signature = JSON.stringify(args);
    if (request.current?.signature !== signature) request.current = { signature, key: crypto.randomUUID() };
    saving.current = true; setBusy(true); setNotice("");
    try {
      const result = await client.schema("api").rpc("portal_planning_policy_save", { ...args, _idempotency_key: request.current.key }).abortSignal(AbortSignal.timeout(15_000));
      if (result.error) {
        setNotice(/STALE|VERSION/.test(result.error.message) ? "De poort is intussen gewijzigd. Je invoer blijft staan. Laad de actuele versie en beoordeel het beleid opnieuw." : result.error.code === "42501" ? "Je hebt geen bevoegdheid om dit ontvangstbeleid te wijzigen." : "Opslaan is geweigerd. Controleer de waarden en probeer dezelfde opdracht opnieuw; je invoer blijft staan.");
        await onChanged(); return;
      }
      if (!result.data?.id || typeof result.data.version !== "number") { setNotice("De server heeft de opslag niet bevestigd. Je invoer blijft behouden; vernieuw en controleer de poort."); return; }
      setEdit(null); setNotice("Ontvangstbeleid opgeslagen. Bestaande routes worden apart opnieuw beoordeeld; er is geen bericht verstuurd."); await onChanged();
    } catch { setNotice("Opslag is niet bevestigd. Je invoer blijft staan. Probeer dezelfde opdracht opnieuw; de opdracht wordt veilig herhaald."); }
    finally { saving.current = false; setBusy(false); }
  }
  return <section className="portal-planning-policy-editor">
    <h2>Ontvangstbeleid voor jullie poort</h2>
    {current ? <>
      {edit ? <form onSubmit={event => { event.preventDefault(); void save(); }}>
        <PortalPlanningPolicyFields value={edit.policy} finale={portal.isFinale} disabled={disabled || busy} onChange={policy => setEdit({ ...edit, policy })}/>
        <p>Dit beleid kan bestaande routeconcepten verouderen. De organisatie berekent en beoordeelt routes apart opnieuw. Startafspraken en berichten veranderen door deze opslag niet.</p>
        {stale && <div className="form-warning"><p>De opgeslagen poortversie is gewijzigd. Je invoer is behouden; laden vervangt die door het actuele beleid.</p><button className="btn outline" type="button" disabled={busy} onClick={() => { setEdit({ version: portal.version, policy: current }); request.current = null; setNotice(""); }}>Actuele versie laden en opnieuw beoordelen</button></div>}
        <div className="actions"><button className="btn outline" type="button" disabled={busy} onClick={() => setEdit(null)}>Annuleren</button><button className="btn" type="submit" disabled={busy || disabled || stale || !canManage}>{busy ? "Beleid opslaan…" : "Ontvangstbeleid opslaan"}</button></div>
      </form> : <>
        <p>Minimale aankomstafstand: {current.arrivalHeadwaySeconds / 60} minuten. Bezoek en wisseltijd eindigen uiterlijk {portal.isFinale || current.ordinaryHardClose ? "bij de harde sluiting" : `${current.ordinaryEndGraceSeconds / 60} minuten na sluiting`}; nieuwe aankomsten blijven vóór sluiting.</p>
        <p>Ingang: {current.accessibilityStatus === "step_free" ? "drempelvrij" : current.accessibilityStatus === "not_step_free" ? "niet drempelvrij" : "toegankelijkheid nog verifiëren"}.</p>
        {canManage && <button className="btn outline" type="button" disabled={disabled} onClick={() => { setEdit({ version: portal.version, policy: current }); setNotice(""); }}>Ontvangstbeleid wijzigen</button>}
      </>}
    </> : <p>Het ontvangstbeleid is nog niet beschikbaar. Vernieuw de poortgegevens.</p>}
    {notice && <p role="status" className="form-notice">{notice}</p>}
  </section>;
}
