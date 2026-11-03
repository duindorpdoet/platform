"use client";

import { useState } from "react";
import { Shield } from "lucide-react";
import type { FestivalController } from "./client";

const sandboxReasons: Record<string, string> = {
  TEST_ADMIN_REQUIRED: "Alleen een bevoegde testbeheerder kan de contract-sandbox activeren.",
  CANONICAL_SANDBOX_FORBIDDEN: "De centrale testeditie kan niet worden omgezet. Gebruik een eigen lege testkopie.",
  TEST_SCOPE_REQUIRED: "Deze instelling vereist een afzonderlijke stagingtesteditie.",
  EDITION_CLOSED: "Deze testeditie is gesloten. Open haar gecontroleerd voordat je een nieuwe proef voorbereidt.",
  ALREADY_ARMED: "De contract-sandbox is al voor deze run bevestigd.",
  MOLLIE_HISTORY_FORBIDDEN: "Deze editie bevat Mollie-pogingen en kan niet worden omgezet. Maak een nieuwe lege testkopie.",
  FRESH_RUN_REQUIRED: "Deze run bevat al inschrijvingen of betaalpogingen. Begin met een lege eigen testkopie of een gecontroleerde nieuwe run.",
  SANDBOX_REARM_REQUIRED: "De sandboxbevestiging hoort bij een eerdere run. Bevestig deze lege run opnieuw voordat je betaalproeven uitvoert.",
};
const reasonText = (reason: string) => sandboxReasons[reason] ?? "De server heeft deze sandboxactie geblokkeerd. Ververs de gegevens en controleer de editie en run.";

export function PaymentSandbox({ controller: c }: { controller: FestivalController }) {
  const s = c.snapshot!;
  const sandbox = s.paymentSandbox;
  const [confirmation, setConfirmation] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [armedRun, setArmedRun] = useState<string | null>(null);
  return <section className="fn-panel" aria-label="Contract-sandbox voor deze testrun">
    <Shield size={28} aria-hidden="true" />
    <h2>EEN BEWUSTE BETAALSANDBOX.</h2>
    <p>Een lege, eigen testkopie kan voor deze ene run de contractadapter gebruiken. Die simuleert betaalbevestigingen zonder Mollie aan te roepen of geld te verplaatsen. Activeer dit vóór het testdecor en vóór inschrijvingen of betaalpogingen.</p>
    <dl className="fn-health">
      <div><dt>Editie</dt><dd>{s.event.slug}</dd></div>
      <div><dt>Actuele run</dt><dd>{s.event.runId}</dd></div>
      <div><dt>Betaalbeleid</dt><dd>{sandbox?.policy === "contract_sandbox" ? "Contract-sandbox voor één run" : "Ingestelde betaalprovider"}</dd></div>
      <div><dt>Ingestelde provider</dt><dd>{sandbox?.configuredProvider === "contract" ? "Contractadapter · geen PSP" : sandbox?.configuredProvider === "mollie" ? "Mollie-testmodus" : "Wacht op servergegevens"}</dd></div>
      <div><dt>Provider voor nieuwe betaalpogingen</dt><dd>{sandbox?.effectiveProvider === "contract" ? "Contractadapter · geen PSP" : sandbox?.effectiveProvider === "mollie" ? "Mollie-testmodus" : "Niet beschikbaar"}</dd></div>
      <div><dt>Inschrijvingen in deze run</dt><dd>{sandbox?.registrations ?? "—"}</dd></div>
      <div><dt>Betaalpogingen in deze run</dt><dd>{sandbox?.orders ?? "—"}</dd></div>
      <div><dt>Mollie-pogingen in de hele editie</dt><dd>{sandbox?.mollieOrders ?? "—"}</dd></div>
    </dl>
    {sandbox?.armed ? <p className="ui-note" role="status">De server heeft de contract-sandbox voor run {sandbox.sandboxRunId} bevestigd. Een reset maakt een nieuwe run; die vraagt opnieuw om een expliciete bevestiging.</p> : <>
      {sandbox?.canonical && <p className="ui-note">De centrale testeditie kan niet worden omgezet. Maak hierboven een eigen lege testeditie en open die.</p>}
      {sandbox?.reason && <p className="ui-note">{reasonText(sandbox.reason)}</p>}
      {!sandbox && <p className="ui-note">De server heeft de sandboxgrens nog niet bevestigd. Ververs de actuele gegevens voordat je deze instelling wijzigt.</p>}
      <form onSubmit={async event => {
        event.preventDefault();
        if (!sandbox?.canArm || confirmation !== s.event.slug || !confirmed) return;
        const result = await c.command("test.payment.sandbox", { confirmation, runId: s.event.runId });
        if (result) { setArmedRun(s.event.runId); setConfirmation(""); setConfirmed(false); }
      }}>
        <label className="ui-field">Typ de editiecode om de contract-sandbox te activeren
          <input value={confirmation} onChange={event => setConfirmation(event.target.value)} required autoComplete="off" spellCheck={false} disabled={!sandbox?.canArm || c.busy} />
        </label>
        <label className="fn-check"><input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} required disabled={!sandbox?.canArm || c.busy} /> Ik heb de editie, run en aantallen gecontroleerd. Deze run gebruikt gesimuleerde betalingen.</label>
        <button className="ui-button" disabled={c.busy || !c.online || !sandbox?.canArm || confirmation !== s.event.slug || !confirmed}>Contract-sandbox voor deze run activeren</button>
      </form>
    </>}
    {armedRun === s.event.runId && sandbox?.armed && <p className="ui-note" role="status">Contract-sandbox geactiveerd en opnieuw door de server bevestigd.</p>}
    {sandbox?.blockedReason && <p className="fn-error">{reasonText(sandbox.blockedReason)}</p>}
    <p className="fn-caption">Bestaande betaalpogingen houden hun eigen provider. De server weigert omzetting van de centrale editie, een gesloten of gevulde run en een editie met Mollie-pogingen. Dit is geen bewijs van een werkende Mollie-koppeling.</p>
  </section>;
}

export function PaymentContracts({ controller: c }: { controller: FestivalController }) {
  const s = c.snapshot!;
  const [result, setResult] = useState<Record<string, unknown> | null>(null);
  const available = s.paymentSandbox?.effectiveProvider === "contract";
  return <section className="fn-panel" aria-label="Betaalcontracten simuleren">
    <Shield size={28} aria-hidden="true" /><h2>BETAALCONTRACTEN.</h2>
    <p>Speel betaalstatussen na voor testinschrijvingen van deze editie. Dit verplaatst geen geld. Elke bestaande betaalpoging houdt haar eigen provider; Mollie-pogingen kunnen hier niet worden bevestigd.</p>
    {!available && <p className="ui-note">De contractsimulator is voor nieuwe betaalpogingen niet beschikbaar. Bij Mollie gebruik je de echte testcheckout. Voor een afzonderlijke synthetische proef kun je een lege eigen testeditie maken en de contract-sandbox hierboven activeren.</p>}
    <form onSubmit={async event => {
      event.preventDefault(); if (!available) return;
      const data = new FormData(event.currentTarget);
      setResult(await c.command("test.payment", { registrationId: data.get("registrationId"), status: data.get("status"), scenario: data.get("scenario") }));
    }}>
      <label className="ui-field">Testinschrijving van uitsluitend deze editie<select name="registrationId" required defaultValue="" disabled={!available}><option value="" disabled>Kies testinschrijving</option>{s.registrations?.map(item => <option key={item.id} value={item.id}>{item.label} · {item.paymentStatus}</option>)}</select></label>
      <label className="ui-field">Gesimuleerde betaalstatus<select name="status" disabled={!available}><option value="paid">Bevestigd betaald</option><option value="failed">Mislukt</option><option value="canceled">Geannuleerd</option><option value="expired">Verlopen</option></select></label>
      <label className="ui-field">Bezorgscenario<select name="scenario" disabled={!available}><option value="normal">Normaal</option><option value="duplicate">Dubbele webhook</option><option value="delayed">Vertraagde webhook</option></select></label>
      <button className="ui-button" disabled={c.busy || !c.online || !available || !s.registrations?.length}>Contractadapter afspelen</button>
    </form>
    {result && <pre className="fn-result">{JSON.stringify(result, null, 2)}</pre>}
  </section>;
}
