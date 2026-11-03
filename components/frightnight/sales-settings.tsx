"use client";
import { amsterdamDateTimeInput, amsterdamInputToIso } from "@/lib/time/amsterdam";
import { salesMessage } from "@/lib/frightnight/sales";
import type { FestivalController } from "./client";

export function SalesSettings({ controller: c }: { controller: FestivalController }) {
  const edition = c.snapshot!.event;
  const message = salesMessage(edition);
  return <section aria-labelledby="fn-sales-heading">
    <h3 id="fn-sales-heading">Verkoop en verwachte startblokken</h3>
    <p>Verkoop sluiten stopt nieuwe inschrijvingen en betaalpogingen. Betaalde gezinnen kunnen hun tocht blijven lopen. Een globale tochtpauze en de editie afsluiten zijn aparte acties.</p>
    <p className="ui-note">{message ?? "De verkoop staat open volgens de actuele editieklok."}</p>
    <form key={`sales-${edition.version}`} onSubmit={async event => {
      event.preventDefault();
      const data = new FormData(event.currentTarget);
      const closes = String(data.get("salesClosesAt") ?? "");
      const closesAt = closes ? amsterdamInputToIso(closes) : null;
      if (closes && !closesAt) { c.setNotice("Kies een geldige, eenduidige Amsterdamse datum en tijd voor de verkoopsluiting."); return; }
      await c.command("admin.settings", {
        expectedVersion: edition.version, salesOpen: data.has("salesOpen"), salesClosesAt: closesAt,
        enabledRoutes: ["lantern", "roots"].filter(route => data.has(route)),
        startBlockMinutes: Number(data.get("startBlockMinutes")),
        maxRegistrationPersons: Number(data.get("maxRegistrationPersons")),
        maxPartyPersons: Number(data.get("maxPartyPersons")),
        reason: "Verkoop en verwachte startblokken gecontroleerd aangepast",
      }, edition.version);
    }}>
      <fieldset className="fn-checkboxes"><legend>Nieuwe verkoop</legend>
        <label><input name="salesOpen" type="checkbox" defaultChecked={edition.salesOpen !== false} /> Verkoop ingeschakeld</label>
        <label><input name="lantern" type="checkbox" defaultChecked={!edition.enabledRoutes || edition.enabledRoutes.includes("lantern")} /> Lantaarnentocht beschikbaar voor nieuwe verkoop</label>
        <label><input name="roots" type="checkbox" defaultChecked={!edition.enabledRoutes || edition.enabledRoutes.includes("roots")} /> Worteltocht beschikbaar voor nieuwe verkoop</label>
      </fieldset>
      <div className="ui-fields">
        <label className="ui-field full">Verkoop sluiten op (Europe/Amsterdam, optioneel)<input name="salesClosesAt" type="datetime-local" defaultValue={amsterdamDateTimeInput(edition.salesClosesAt)} /></label>
        <label className="ui-field full">Afstand tussen verwachte startblokken<select name="startBlockMinutes" defaultValue={edition.startBlockMinutes ?? 15}>{[5, 10, 15, 30].map(minutes => <option value={minutes} key={minutes}>{minutes} minuten</option>)}</select></label>
        <label className="ui-field">Maximum personen per inschrijving<input name="maxRegistrationPersons" type="number" required min={1} max={20} defaultValue={edition.maxRegistrationPersons ?? 20} /></label>
        <label className="ui-field">Maximum personen in een samenloopgroep<input name="maxPartyPersons" type="number" required min={1} max={100} defaultValue={edition.maxPartyPersons ?? 20} /></label>
      </div>
      <p className="fn-caption">De sluiting gebruikt de editieklok, zodat je haar veilig kunt testen. Een leeg sluitmoment heeft geen tijdslimiet. Een nieuw blokrooster bewaart oude blokken, betaalde plaatsen en lopende betaalreserveringen. Nieuwe blokken beginnen met 100 plaatsen; pas de capaciteit hieronder aan. Een startblok blijft een verwachte aankomst, geen verplichte afspraak.</p>
      <p className="fn-caption">Het samenloopmaximum is minstens het maximum per inschrijving. Verlagen verandert bestaande betaalquotes en reeds gekoppelde gezinnen niet. Nieuwe inschrijvingen, uitbreidingen en koppelingen moeten binnen de nieuwe limieten passen.</p>
      <button className="ui-button" disabled={c.busy || !c.online}>Verkoopinstellingen bewaren</button>
    </form>
  </section>;
}
