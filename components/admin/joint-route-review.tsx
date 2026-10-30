"use client";

import { useRef, useState } from "react";
import { RefreshCw } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import type { JointRouteMetrics, JointRouteProposal } from "@/lib/domain/joint-route-planner";
import { jointRouteReviewDiagnostics } from "@/lib/domain/joint-route-review";
import type { BoardSnapshot } from "@/lib/domain/live-planboard";
import { AdminDialog } from "./admin-dialog";

const time = (value: string | null | undefined) => value ? new Date(value).toLocaleTimeString("nl-NL", { timeZone: "Europe/Amsterdam", hour: "2-digit", minute: "2-digit", second: new Date(value).getUTCSeconds() ? "2-digit" : undefined }) : "niet beschikbaar";
const number = (value: number) => value.toLocaleString("nl-NL", { maximumFractionDigits: 1 });
const minutes = (seconds: number) => `${number(seconds / 60)} min`;
const deviation = (seconds: number | null) => seconds === null ? "niet beschikbaar" : seconds === 0 ? "op streeftijd" : `${minutes(Math.abs(seconds))} ${seconds > 0 ? "uitloop" : "eerder"}`;
function safeError(error: unknown) {
  const message = error && typeof error === "object" && "message" in error ? String(error.message) : "";
  if (/STALE|SOURCE_CHANGED|INPUT_CHANGED/.test(message)) return "De brongegevens of route-intenties zijn intussen gewijzigd. Dit voorstel is niet toegepast. Bereken opnieuw en controleer de nieuwe verschillen.";
  if (/42501|NOT_AUTHORIZED|PERMISSION/.test(message)) return "Groepsbeheer is nodig voor deze actie. Er is niets gewijzigd.";
  return "Het voorstel is niet bevestigd. Controleer de actuele gegevens en probeer dezelfde opdracht opnieuw; bestaande afspraken en berichten blijven behouden.";
}

export function JointRouteReview({ eventSlug, snapshot, disabled, onChanged }: { eventSlug: string; snapshot: BoardSnapshot; disabled: boolean; onChanged: () => Promise<void> }) {
  const [proposal, setProposal] = useState<JointRouteProposal | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState(""), [notice, setNotice] = useState("");
  const [reason, setReason] = useState(""), [confirmed, setConfirmed] = useState(false);
  const pending = useRef(false), command = useRef<{ signature: string; key: string } | null>(null);
  const stale = proposal !== null && proposal.boardHash !== snapshot.inputHash;
  const groupCode = (id: string) => snapshot.groups.find(group => group.id === id)?.code ?? "Onbekende groep";
  const portalCode = (id: string) => snapshot.portals.find(portal => portal.id === id)?.code ?? "Onbekende poort";
  const findings = proposal ? jointRouteReviewDiagnostics(proposal) : { blocks: [], advice: [] };
  const finaleChanges = proposal?.groups.filter(plan => plan.finaleChange) ?? [];
  async function calculate() {
    if (pending.current || disabled) return;
    pending.current = true; setBusy(true); setError(""); setNotice(""); setProposal(null); setReason(""); setConfirmed(false);
    try {
      const response = await fetch("/api/admin/routes/proposal", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ eventSlug }), signal: AbortSignal.timeout(60_000) });
      const body = await response.json() as { data?: JointRouteProposal; error?: { message?: string } };
      if (!response.ok || !body.data) { setError(body.error?.message ?? "Het gezamenlijke voorstel kon niet worden berekend. Er is niets opgeslagen."); return; }
      setProposal(body.data); command.current = null;
    } catch { setError("Het berekenen is onderbroken. Er is niets opgeslagen. Probeer het opnieuw."); }
    finally { pending.current = false; setBusy(false); }
  }
  async function apply() {
    if (!proposal || !proposal.valid || stale || disabled || pending.current || !confirmed || reason.trim().length < 10) return;
    const client = createClient(); if (!client) return;
    const args = { _event_slug: eventSlug, _proposal: proposal, _confirmed: true, _reason: reason.trim() };
    const signature = JSON.stringify(args);
    if (command.current?.signature !== signature) command.current = { signature, key: crypto.randomUUID() };
    pending.current = true; setBusy(true); setError("");
    try {
      const result = await client.schema("api").rpc("admin_joint_route_plan_apply", { ...args, _idempotency_key: command.current.key }).abortSignal(AbortSignal.timeout(30_000));
      if (result.error) { setError(safeError(result.error)); await onChanged(); return; }
      if (!result.data?.acceptedVersionId || !Number.isInteger(result.data.revision)) { setError("De server heeft de nieuwe conceptversie niet bevestigd. Controleer de actuele planning; hetzelfde verzoek kan veilig worden herhaald."); return; }
      setProposal(null); setNotice(`Routeconcept ${result.data.revision} opgeslagen voor ${result.data.groupCount} groepen.${finaleChanges.length ? ` ${finaleChanges.length} beoordeelde tijdsafspraken bij P-38 zijn samen met het planbord bijgewerkt.` : ""} Startafspraken zijn behouden; er zijn geen routes gepubliceerd en geen berichten klaargezet.`); await onChanged();
    } catch { setError("Opslag is niet bevestigd. Probeer dezelfde opdracht opnieuw; de idempotente opdracht voorkomt een dubbele conceptversie."); }
    finally { pending.current = false; setBusy(false); }
  }
  const metricRows: Array<{ label: string; value: (metrics: JointRouteMetrics) => string }> = [
    { label: "Gewone fysieke bezoeken", value: metrics => number(metrics.totalOrdinaryVisits) },
    { label: "Bezoeken per groep · minimum / gemiddeld / maximum", value: metrics => `${metrics.minOrdinaryVisits} / ${number(metrics.meanOrdinaryVisits)} / ${metrics.maxOrdinaryVisits}` },
    { label: "Groepen zonder gewoon bezoek", value: metrics => number(metrics.zeroVisitGroups) },
    { label: "Totale looptijd", value: metrics => minutes(metrics.walkingSeconds) },
    { label: "Ontvangstwachten bij gewone huizen", value: metrics => minutes(metrics.receptionWaitingSeconds) },
    { label: "Vrije tijd vóór P-38", value: metrics => minutes(metrics.unallocatedBeforeFinaleSeconds) },
    { label: "Langste afzonderlijke wachttijd", value: metrics => minutes(metrics.longestWaitSeconds) },
    { label: "Gewone poorten zonder bezoek", value: metrics => metrics.unvisitedPortals.map(portalCode).join(", ") || "geen" },
    { label: "Totale absolute eindafwijking", value: metrics => minutes(metrics.absoluteEndDeviationSeconds) },
    { label: "Totale groepsuitloop", value: metrics => minutes(metrics.overrunSeconds) },
    { label: "Administratieve starts · geen fysieke bezoeken", value: metrics => number(metrics.administrativeStarts) },
  ];
  return <section className="joint-route-review" aria-label="Gezamenlijk routevoorstel">
    <button className="btn outline" type="button" disabled={disabled || busy} onClick={() => void calculate()}><RefreshCw size={16}/>{busy && !proposal ? "Gezamenlijke routes berekenen…" : "Routes opnieuw berekenen met bevestigde starts"}</button>
    <p>Bereken een apart voorstel met één gedeelde poortkalender en zo veel mogelijk haalbare huisbezoeken per groep. Bevestigde starts en begonnen routes blijven beschermd. Een beter tijdslot bij dezelfde finalepoort P-38 verschijnt als afzonderlijk te beoordelen wijziging.</p>
    {notice && <p className="form-notice" role="status">{notice}</p>}{error && !proposal && <p className="form-warning" role="alert">{error}</p>}
    {proposal && <AdminDialog labelledBy="joint-route-proposal-title" close={() => { if (!busy) setProposal(null); }}>
      <section className="joint-route-proposal">
        <h2 id="joint-route-proposal-title">Gezamenlijk routevoorstel controleren</h2>
        <p>{proposal.valid ? "Het berekende voorstel voldoet aan de gecontroleerde harde grenzen." : "Dit voorstel bevat blokkades en kan niet worden opgeslagen."} De server controleert alle brongegevens en de gezamenlijke capaciteit opnieuw bij opslaan.</p>
        <p>De vergelijking toont opgeslagen route-intenties tegenover het nieuwe voorstel. Startafspraken worden niet opnieuw gepubliceerd en er wordt geen deelnemersmail verstuurd. Werkelijke bezoeken en begonnen routes blijven beschermd.</p>
        <p>Iedere route eindigt eenmaal bij P-38. De echte looptijd naar P-38 telt volledig mee; voor die laatste wandeling geldt geen vaste tijd- of afstandsgrens.</p>
        {proposal.walkingPolicy && <p>Voor gewone etappes geldt maximaal {minutes(proposal.walkingPolicy.maxOrdinaryLegSeconds)} lopen. Het afzonderlijke totale loopbudget is {minutes(proposal.walkingPolicy.maxTotalSeconds)} per groep, inclusief de finale-etappe. Dit budget wordt apart getoetst.</p>}
        {stale && <p className="form-warning" role="alert">Het bord of de brongegevens zijn gewijzigd sinds deze berekening. Bereken opnieuw vóór opslaan.</p>}
        <div className="joint-route-table-scroll" tabIndex={0} aria-label="Vergelijking van avondmetingen"><table><caption>Avondmetingen</caption><thead><tr><th scope="col">Meting</th><th scope="col">Huidige intenties</th><th scope="col">Voorstel</th></tr></thead><tbody>{metricRows.map(row => <tr key={row.label}><th scope="row">{row.label}</th><td>{row.value(proposal.metrics.before)}</td><td>{row.value(proposal.metrics.after)}</td></tr>)}</tbody></table></div>
        <p>De langste afzonderlijke wachttijd omvat zowel wachten bij ontvangst als vrije tijd vóór P-38. Beide categorieën staan daarnaast afzonderlijk vermeld.</p>
        <details open><summary>Vergelijking per groep</summary><div className="joint-route-table-scroll" tabIndex={0} aria-label="Groepsroutes voor en na"><table><thead><tr><th scope="col">Groep</th><th scope="col">Vaste start</th><th scope="col">Gewone bezoeken</th><th scope="col">Einde gewone poorten</th><th scope="col">Verandering bezoektijd</th><th scope="col">Aankomst P-38</th><th scope="col">Gewenst klaar</th><th scope="col">Verwacht klaar</th><th scope="col">Eindafwijking</th><th scope="col">Lopen</th><th scope="col">Ontvangstwachten</th><th scope="col">Vrije tijd vóór P-38</th><th scope="col">Langste wachttijd</th></tr></thead><tbody>{proposal.groups.map(plan => {
          const before = proposal.metrics.before.byGroup.find(group => group.groupId === plan.groupId), after = proposal.metrics.after.byGroup.find(group => group.groupId === plan.groupId);
          const ordinary=plan.visits.filter(visit=>visit.kind==="ordinary").sort((a,b)=>a.sequence-b.sequence),last=ordinary.at(-1);
          const serviceDelta=ordinary.reduce((sum,visit)=>sum+visit.visitSeconds,0)-snapshot.visits.filter(visit=>visit.groupId===plan.groupId&&visit.kind==="ordinary").reduce((sum,visit)=>sum+visit.durationSeconds,0);
          const desired = plan.desiredEndAt;
          return <tr key={plan.groupId}><th scope="row">{groupCode(plan.groupId)}</th><td>{time(plan.startsAt)}</td><td>{before?.ordinaryVisits ?? "?"} → {after?.ordinaryVisits ?? "?"}</td><td>{last?time(new Date(Date.parse(last.startsAt)+last.visitSeconds*1000).toISOString()):"geen gewoon bezoek"}</td><td>{serviceDelta<0?`${minutes(-serviceDelta)} verloren`:serviceDelta>0?`${minutes(serviceDelta)} extra`:"gelijk"}</td><td>{time(before?.finaleArrivalAt)} → {time(plan.finaleArrivalAt)}</td><td>{time(desired)}</td><td>{time(plan.expectedCompletionAt)}</td><td>{deviation(after?.endDeviationSeconds ?? null)}</td><td>{minutes(before?.walkingSeconds ?? 0)} → {minutes(after?.walkingSeconds ?? 0)}</td><td>{before?minutes(before.receptionWaitingSeconds):"?"} → {after?minutes(after.receptionWaitingSeconds):"?"}</td><td>{before?minutes(before.unallocatedBeforeFinaleSeconds):"?"} → {after?minutes(after.unallocatedBeforeFinaleSeconds):"?"}</td><td>{before?minutes(before.longestWaitSeconds):"?"} → {after?minutes(after.longestWaitSeconds):"?"}</td></tr>;
        })}</tbody></table></div></details>
        {finaleChanges.length > 0 && <section aria-label="Voorgestelde tijdswijzigingen bij P-38"><h3>Tijdswijzigingen bij P-38 afzonderlijk beoordelen</h3><p>De fysieke finale blijft P-38. Bij opslaan worden uitsluitend de hieronder beoordeelde tijdsafspraken samen met het planbord bijgewerkt.</p><ul>{finaleChanges.map(plan => <li key={plan.groupId}><strong>{groupCode(plan.groupId)}</strong>: {time(plan.finaleChange!.previousReservedAt)} → {time(plan.finaleChange!.proposedReservedAt)}</li>)}</ul></section>}
        <details><summary>Spreiding en resterende gaten per gewone poort</summary><p>Dit zijn unieke groepsbezoeken. De bruikbare opening houdt rekening met de echte loopduur, de groepsgrenzen en het geldige finalevenster. Bij geen gevonden bezoek staat de gecontroleerde beperking of de onzekerheid van de zoekroutine vermeld.</p><div className="joint-route-table-scroll" tabIndex={0} aria-label="Poortbelasting voor en na"><table><thead><tr><th scope="col">Poort</th><th scope="col">Bezoeken</th><th scope="col">Per bruikbaar open uur</th><th scope="col">Eerste bezoek</th><th scope="col">Tot eerste haalbare bezoek</th><th scope="col">Grootste gat</th><th scope="col">Kwartieren</th></tr></thead><tbody>{proposal.metrics.after.byPortal.map(after => {
          const before = proposal.metrics.before.byPortal.find(portal => portal.portalId === after.portalId);
          return <tr key={after.portalId}><th scope="row">{portalCode(after.portalId)}</th><td>{before?.visits ?? "?"} → {after.visits}</td><td>{before ? number(before.visitsPerOpenHour) : "?"} → {number(after.visitsPerOpenHour)}</td><td>{time(after.firstArrivalAt)}</td><td>{after.firstDelaySeconds === null ? "niet beschikbaar" : minutes(after.firstDelaySeconds)}</td><td>{before ? minutes(before.largestGapSeconds) : "?"} → {minutes(after.largestGapSeconds)}{after.explanation && <small>{after.explanation}</small>}</td><td>{after.quarterHourBuckets.map(bucket => `${time(bucket.startsAt)}: ${bucket.visits}`).join(" · ") || "geen bezoeken"}</td></tr>;
        })}</tbody></table></div></details>
        {findings.blocks.length > 0 && <section aria-label="Harde planningsconflicten"><h3>Harde planningsconflicten</h3>{findings.blocks.map((conflict, index) => <p key={index} className="form-warning"><strong>Blokkade{conflict.groupId ? ` · ${groupCode(conflict.groupId)}` : ""}{conflict.portalId ? ` · ${portalCode(conflict.portalId)}` : ""}</strong>: {conflict.message}</p>)}</section>}
        {findings.advice.length > 0 && <details open><summary>Kwaliteitsadviezen en routeafwegingen</summary>{findings.advice.map((diagnostic, index) => <p key={index}><strong>Advies{diagnostic.groupId ? ` · ${groupCode(diagnostic.groupId)}` : ""}{diagnostic.portalId ? ` · ${portalCode(diagnostic.portalId)}` : ""}</strong>: {diagnostic.message}</p>)}</details>}
        <p>{proposal.work.exhausted ? "De begrensde zoekruimte is gebruikt. " : "De deterministische zoekroutine heeft binnen de onderzochte alternatieven dit voorstel gekozen. "}Een wereldwijd optimum is niet bewezen; geen beter alternatief vinden bewijst op zichzelf geen onmogelijkheid. Alleen echte bezoeken vullen de route. Als die onvoldoende tijd beslaan, blijft de duurafweging zichtbaar als vrije tijd of eerdere afronding.</p>
        <label className="field"><span>Reden om dit routeconcept op te slaan</span><textarea value={reason} minLength={10} maxLength={500} disabled={busy} onChange={event => setReason(event.target.value)}/></label>
        <label className="check-row"><input type="checkbox" checked={confirmed} disabled={busy} onChange={event => setConfirmed(event.target.checked)}/><span>Ik heb de routes en iedere voorgestelde tijdswijziging bij P-38 beoordeeld. Ik sla dit routeconcept en de beoordeelde finale-afspraken samen op. Bevestigde startafspraken blijven behouden; er volgt geen publicatie of bericht.</span></label>
        {error && <p className="form-warning" role="alert">{error}</p>}
        <div className="actions"><button className="btn outline" type="button" disabled={busy} onClick={() => setProposal(null)}>Annuleren</button><button className="btn outline" type="button" disabled={busy || disabled} onClick={() => void calculate()}>Voorstel opnieuw berekenen</button><button className="btn" type="button" disabled={busy || disabled || stale || !proposal.valid || findings.blocks.length > 0 || !confirmed || reason.trim().length < 10} onClick={() => void apply()}>{busy ? "Routeconcept opslaan…" : "Beoordeeld routeconcept opslaan"}</button></div>
      </section>
    </AdminDialog>}
  </section>;
}
