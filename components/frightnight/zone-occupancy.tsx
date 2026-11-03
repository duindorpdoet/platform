"use client";
import { useState } from "react";
import type { FrightnightZone } from "@/lib/frightnight/model";
import type { FestivalController } from "./client";

const observedTime = (value: string) => new Date(value).toLocaleTimeString("nl-NL", { timeZone: "Europe/Amsterdam", hour: "2-digit", minute: "2-digit" });

export function ZoneOccupancy({ controller: c, zone }: { controller: FestivalController; zone: FrightnightZone }) {
  const [clear, setClear] = useState(false);
  const occupancy = zone.occupancy;
  if (!occupancy) return <section className="fn-panel"><h2>BEZOEKERS BIJ JOUW ZONE.</h2><p>Actuele bezetting is nog niet ontvangen. Haal de actuele gegevens op voordat je een waarneming doorgeeft.</p></section>;
  return <section className="fn-panel" aria-labelledby={`occupancy-${zone.id}`}>
    <span className="ui-kicker">Eigen waarneming · serverbevestiging vereist</span><h2 id={`occupancy-${zone.id}`}>WIE STAAT ER BIJ JOU?</h2>
    <p>Appgroepen hebben al een gereserveerde plek. Vink de herkenningscodes aan van groepen die je daadwerkelijk ziet. Tel deze personen niet nog eens bij de extra bezoekers.</p>
    <div className="fn-stats"><div><strong>{occupancy.appPersons}</strong><span>personen via de app</span></div><div><strong>{occupancy.extraPersons}</strong><span>extra ongetelde personen</span></div><div><strong>{occupancy.effectivePersons}</strong><span>personen samen</span></div><div><strong>{occupancy.available}</strong><span>plaatsen beschikbaar</span></div></div>
    <p className="fn-caption">Bekende groepen samen: {occupancy.observedKnownPersons} personen; overlap met appclaims: {occupancy.overlapPersons}. Bekende personen tellen één keer mee. Een waarneming bevestigt geen bezoek of Lichtvonk.</p>
    {occupancy.observedAt && <p className="fn-caption">Waargenomen om {observedTime(occupancy.observedAt)} · vers tot {occupancy.expiresAt ? observedTime(occupancy.expiresAt) : "onbekend"} (Europe/Amsterdam). Dit volgt de werkelijke klok, ook bij een testklok.</p>}
    {occupancy.observationStale && <p className="fn-error" role="status">Waarneming verouderd, bevestig opnieuw. De bestaande claim blijft behouden; nieuwe bestemmingen wachten tot een verse waarneming.</p>}
    {occupancy.admissionBlocked && !occupancy.observationStale && <p className="ui-note">Er worden momenteel geen nieuwe groepen naar deze zone vrijgegeven. Controleer de actuele bezetting en zonestatus.</p>}
    <form key={`${zone.id}:${zone.version}`} onSubmit={async event => {
      event.preventDefault();
      const data = new FormData(event.currentTarget);
      const result = await c.command("zone.occupancy", { zoneId: zone.id, expectedVersion: zone.version, observedDestinationIds: clear ? [] : data.getAll("observedDestinationIds"), extraPersons: clear ? 0 : Number(data.get("extraPersons")), confirmedUncounted: true }, zone.version);
      if (result) { setClear(false); c.setNotice("Jouw waarneming is door de server bevestigd. Bekende groepen zijn één keer meegeteld."); }
    }}>
      <fieldset className="fn-checkboxes" disabled={clear}><legend>Appgroepen die ik nu daadwerkelijk zie</legend>
        {occupancy.candidates.map(candidate => <label key={candidate.destinationId}><input type="checkbox" name="observedDestinationIds" value={candidate.destinationId} defaultChecked={candidate.observed} />Groep {candidate.reference} · {candidate.persons} personen · {candidate.state === "current" ? "verwacht/onderweg" : candidate.state === "visited" ? "bezoek geregistreerd" : "eerder herkende groep"}{candidate.arrivalAt ? ` · aankomst rond ${observedTime(candidate.arrivalAt)}` : ""}</label>)}
        {!occupancy.candidates.length && <p>Er zijn geen herkenbare appgroepen voor deze zone ontvangen. Voeg uitsluitend bezoekers toe die nog niet in een bekende groep zijn meegeteld.</p>}
      </fieldset>
      <label className="ui-field">Extra personen buiten deze bekende appgroepen<input name="extraPersons" type="number" required min={0} max={1000} disabled={clear} defaultValue={occupancy.extraPersons} /></label>
      <label className="fn-check"><input type="checkbox" checked={clear} onChange={event => setClear(event.target.checked)} />Ik zie geen bezoekers meer: bevestig een lege waarneming en geef mijn eerdere waarneming vrij.</label>
      <label className="fn-check"><input type="checkbox" required />Ik heb dit ter plaatse gecontroleerd. Extra personen zijn nergens anders in deze waarneming meegeteld.</label>
      <button className="ui-button primary" disabled={c.busy || !c.online}>{clear ? "Lege waarneming bevestigen" : "Bezetting bevestigen"}</button>
      <p className="fn-caption">Bevestig na vijf werkelijke minuten opnieuw. Een oudere niet-lege waarneming wordt nooit stilzwijgend vrijgegeven. Appreserveringen blijven gekoppeld aan de serverroute.</p>
    </form>
  </section>;
}
