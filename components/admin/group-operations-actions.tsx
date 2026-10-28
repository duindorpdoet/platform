"use client";

import { useId, useRef, useState } from "react";
import { AdminDialog } from "./admin-dialog";
import { createClient } from "@/lib/supabase/client";
import { proposeGroupAutofill, type AutofillGroup } from "@/lib/domain/group-autofill";
import type { CompositionRegistration } from "@/lib/domain/group-composition";

type Impact = { inputHash: string; groups: number; registrations: number; children: number; confirmedCompositions: number; draftAppointments: number; publishedAppointments: number; reservations: number; communicationRecipients: number; blockers: Array<{ code: string; reason: string }> };
type Group = {
  id: string;
  systemCode: string;
  compositionConfirmed?: boolean | null;
  locked: boolean;
};
type GroupOperationsProps = {
  eventSlug: string;
  inputHash: string;
  unassigned?: CompositionRegistration[];
  groups?: Group[];
  group?: Group;
  target: number;
  maximum: number;
  reload: () => Promise<void>;
  notice: (message: string) => void;
  onOpenStarts?: () => void;
};

export function GroupOperationsActions({
  eventSlug,
  inputHash,
  unassigned = [],
  group,
  target,
  maximum,
  reload,
  notice,
  onOpenStarts,
}: GroupOperationsProps) {
  const dialogTitleId = useId();
  const [dialog, setDialog] = useState<{ action: string; impact: Impact; key: string; group?: Group; proposal?: AutofillGroup[] } | null>(null);
  const [confirmation, setConfirmation] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const pending = useRef(false);
  async function preview(action: string, group?: Group) {
    const client = createClient(); if (!client || pending.current) return;
    pending.current = true; setBusy(true); setError("");
    try {
      const result = await client.schema("api").rpc("admin_group_operations_preview", { _event_slug: eventSlug });
      if (result.error) throw result.error;
      const impact = result.data as Impact;
      if (impact.inputHash !== inputHash) { await reload(); notice("De indeling is gewijzigd. Controleer het actuele bord en open de preview opnieuw."); return; }
      setDialog({ action, impact, key: crypto.randomUUID(), group, proposal: action === "autofill" ? proposeGroupAutofill(unassigned, maximum, target) : undefined });
      setConfirmation(""); setReason("");
    } catch (cause) { notice(cause instanceof Error ? cause.message : "De impact kon niet worden opgehaald."); }
    finally { pending.current = false; setBusy(false); }
  }
  async function apply() {
    const client = createClient(); if (!client || !dialog || pending.current) return;
    pending.current = true; setBusy(true); setError("");
    try {
      const payload = dialog.action === "reset" ? { confirmation } : dialog.action === "autofill" ? { groups: dialog.proposal } : { groupId: dialog.group?.id, reason };
      const result = await client.schema("api").rpc("admin_group_operations_apply", { _event_slug: eventSlug, _action: dialog.action, _input_hash: dialog.impact.inputHash, _payload: payload, _idempotency_key: dialog.key });
      if (result.error) { setError(/STALE_/.test(result.error.message) ? "De gegevens zijn gewijzigd. Sluit deze preview, vernieuw het bord en controleer de impact opnieuw." : result.error.message); return; }
      setDialog(null); await reload();
      notice(dialog.action === "confirm" ? "Groepssamenstelling bevestigd. Persoonlijke groepsmails staan in de wachtrij." : dialog.action === "reset" ? "Alle groepen teruggezet. Benodigde intrekkingsberichten staan in de wachtrij." : dialog.action === "autofill" ? "Conceptgroepen opgeslagen. Er is niemand gemaild." : "Samenstelling heropend. De eerdere afspraak is ingetrokken; bevestig de nieuwe indeling opnieuw.");
    } catch { setError("Verbinding onderbroken. Probeer opnieuw; dezelfde opdracht wordt veilig herhaald."); }
    finally { pending.current = false; setBusy(false); }
  }
  const titles: Record<string, string> = { reset: "Alle groepen terugzetten", autofill: "Groepen automatisch vullen", confirm: "Groep bevestigen", reopen: "Samenstelling heropenen" };
  return <section className={`group-operations${group ? " group-operations-inline" : ""}`} aria-label={group ? `Acties voor ${group.systemCode}` : "Groepsacties"}>
    {group ? (
      <button
        className="btn outline"
        type="button"
        disabled={busy}
        aria-label={`${group.systemCode} · ${group.compositionConfirmed || group.locked ? "Heropenen" : "Groep bevestigen"}`}
        onClick={() => void preview(group.compositionConfirmed || group.locked ? "reopen" : "confirm", group)}
      >
        {group.compositionConfirmed || group.locked ? "Heropenen" : "Groep bevestigen"}
      </button>
    ) : (
      <details className="group-operations-menu">
        <summary>Groepsacties</summary>
        <div className="actions">
          {onOpenStarts && <button className="btn outline" type="button" disabled={busy} onClick={onOpenStarts}>Groepen over startpunten verdelen</button>}
          <button className="btn" type="button" disabled={busy || !unassigned.length} onClick={() => void preview("autofill")}>Groepen automatisch vullen</button>
          <button className="btn outline" type="button" disabled={busy} onClick={() => void preview("reset")}>Alle groepen terugzetten</button>
        </div>
        <p>Streef {target} kinderen · evenementmaximum {maximum}. Groepsbevestiging en startafspraak hebben elk hun eigen bevestiging.</p>
      </details>
    )}
    {dialog && <AdminDialog labelledBy={dialogTitleId} close={() => { if (!busy) setDialog(null); }}>
      <h2 id={dialogTitleId}>{titles[dialog.action]}{dialog.group ? ` · ${dialog.group.systemCode}` : ""}</h2>
      {dialog.action === "reset" && <>
        <p>{dialog.impact.groups} groepen · {dialog.impact.registrations} inschrijvingen · {dialog.impact.children} kinderen.</p>
        <p>{dialog.impact.confirmedCompositions} bevestigde samenstellingen · {dialog.impact.draftAppointments} conceptafspraken · {dialog.impact.publishedAppointments} gepubliceerde afspraken · {dialog.impact.reservations} reserveringen.</p>
        <p>De actuele indeling en afspraken worden ingetrokken. Nog deelnemende inschrijvingen staan daarna weer bij ‘Nog in te delen’. Samenlopen, kinderen, betalingen en historie blijven behouden. {dialog.impact.communicationRecipients} volwassen ontvanger(s) krijgen eenmaal bericht over de herziening.</p>
        {dialog.impact.blockers.map((blocker, i) => <p role="alert" key={i}>{blocker.reason}</p>)}
        <label className="field"><span>Typ ALLE GROEPEN TERUGZETTEN</span><input data-initial-focus value={confirmation} onChange={e => setConfirmation(e.target.value)} /></label>
      </>}
      {dialog.proposal && <><p>{unassigned.filter(r=>r.childCount===0).length} inschrijving(en) zonder actieve kinderen blijven zichtbaar bij Nog in te delen.</p><p>{dialog.proposal.length} conceptgroepen · streef {target} · maximum {maximum}. Startslots zijn hiervoor niet nodig. Bestaande groepen blijven intact.</p>{dialog.proposal.map(group => <article key={group.key}><strong>{group.key} · {group.childCount} kinderen · {group.registrationIds.length} inschrijvingen</strong><p>Voorkeurstijd {group.preferredStartAt ? new Intl.DateTimeFormat("nl-NL", { timeZone: "Europe/Amsterdam", hour: "2-digit", minute: "2-digit" }).format(new Date(group.preferredStartAt)) : "neutraal"}</p>{group.warnings.map(w => <p className="form-warning" key={w}>{w === "EVENT_MAXIMUM_EXCEPTION_REQUIRED" ? "Intact blok boven evenementmaximum: blijft zichtbaar als concept. Pas het beleid bewust aan voordat je bevestigt." : `Boven streef ${target}: inschrijving/samenloop blijft intact.`}</p>)}</article>)}</>}
      {dialog.action === "confirm" && <p>Bevestig de huidige samenstelling. Alle bevoegde volwassen ontvangers krijgen een persoonlijke groepsmail. De definitieve starttijd wordt afzonderlijk bevestigd.</p>}
      {dialog.action === "reopen" && <><p>De samenstelling wordt weer bewerkbaar. Een bestaande startafspraak en de bijbehorende reserveringen worden ingetrokken. Controleer daarna opnieuw de leden, planning en communicatie.</p><label className="field"><span>Reden van heropenen</span><input value={reason} onChange={e => setReason(e.target.value)} /></label></>}
      {error && <p role="alert" className="form-warning">{error}</p>}
      <div className="actions"><button type="button" className="btn outline" disabled={busy} onClick={() => setDialog(null)}>Terug</button><button type="button" className="btn" disabled={busy || (dialog.action === "reset" && (confirmation !== "ALLE GROEPEN TERUGZETTEN" || !!dialog.impact.blockers.length)) || (dialog.action === "reopen" && reason.trim().length < 10)} onClick={() => void apply()}>{dialog.action === "autofill" ? "Conceptgroepen opslaan" : titles[dialog.action]}</button></div>
    </AdminDialog>}
  </section>;
}
