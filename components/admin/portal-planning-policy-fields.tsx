"use client";

import "./portal-planning-policy-fields.css";

export type PortalPlanningPolicy = {
  arrivalHeadwaySeconds: number;
  ordinaryEndGraceSeconds: number;
  ordinaryHardClose: boolean;
  accessibilityStatus: "unknown" | "step_free" | "not_step_free" | null;
};

export function PortalPlanningPolicyFields({ value, onChange, disabled = false, finale = false }: {
  value: PortalPlanningPolicy;
  onChange: (value: PortalPlanningPolicy) => void;
  disabled?: boolean;
  finale?: boolean;
}) {
  const hardClose = finale || value.ordinaryHardClose;
  return <fieldset disabled={disabled} className="portal-planning-policy">
    <legend>Ontvangst en toegankelijkheid</legend>
    <label className="field"><span>Minimale afstand tussen groepsaankomsten</span>
      <select value={value.arrivalHeadwaySeconds} onChange={event => onChange({ ...value, arrivalHeadwaySeconds: Number(event.target.value) })}>
        {Array.from({ length: 56 }, (_, index) => index + 5).map(minutes => <option key={minutes} value={minutes * 60}>{minutes} minuten</option>)}
      </select>
    </label>
    <p>Deze aankomstafstand geldt ook bij ruimte voor meerdere groepen. Bezoekduur, wisseltijd en gelijktijdige capaciteit blijven afzonderlijke grenzen.</p>
    {!finale && <label className="check-row"><input type="checkbox" checked={value.ordinaryHardClose} onChange={event => onChange({ ...value, ordinaryHardClose: event.target.checked })}/><span>Harde sluiting: bezoek en wisseltijd zijn vóór de sluiting afgerond</span></label>}
    <label className="field"><span>Toegestane einduitloop voor bezoek en wisseltijd</span>
      <select disabled={hardClose} value={hardClose ? 0 : value.ordinaryEndGraceSeconds} onChange={event => onChange({ ...value, ordinaryEndGraceSeconds: Number(event.target.value) })}>
        {!hardClose && value.ordinaryEndGraceSeconds % 60 !== 0 && <option value={value.ordinaryEndGraceSeconds}>{value.ordinaryEndGraceSeconds} seconden (huidige waarde)</option>}
        {Array.from({ length: 6 }, (_, minutes) => <option key={minutes} value={minutes * 60}>{minutes} minuten</option>)}
      </select>
    </label>
    <p>{finale ? "Voor de finale blijft de fysieke sluiting hard: show en wisseltijd passen volledig binnen het definitieve finalevenster." : "Aankomst blijft vóór de oorspronkelijke sluiting. Deze kleine einduitloop is geen extra aankomstvenster en staat los van de maximaal 30 minuten groepsuitloop."}</p>
    <label className="field"><span>Toegankelijkheid van de ontvangstingang</span>
      <select value={value.accessibilityStatus ?? "unknown"} onChange={event => onChange({ ...value, accessibilityStatus: event.target.value as PortalPlanningPolicy["accessibilityStatus"] })}>
        <option value="unknown">Onbekend · eerst verifiëren</option>
        <option value="step_free">Drempelvrij bereikbaar</option>
        <option value="not_step_free">Niet drempelvrij bereikbaar</option>
      </select>
    </label>
    <p>Dit is een gecontroleerde eigenschap van de ingang. Een vrije toelichting maakt een onbekende ingang niet automatisch drempelvrij.</p>
  </fieldset>;
}
