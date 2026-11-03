"use client";
import type { FestivalController } from "./client";

export function zoneReviewLabel(status?: string) {
  return ({ submitted: "In beoordeling", changes_requested: "Wijziging gevraagd", approved: "Goedgekeurd", rejected: "Afgewezen" } as Record<string, string>)[status ?? ""] ?? "In beoordeling";
}

export function ZoneReviewForm({ controller: c, zone, onSaved }: { controller: FestivalController; zone: { id: string; name: string; version: number; reviewReason?: string | null }; onSaved: () => Promise<void> }) {
  return <details><summary>Beoordeling wijzigen</summary><form noValidate aria-label={`Beoordeling van ${zone.name}`} onSubmit={async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const decision = ((event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null)?.value;
    if (!["approved", "changes_requested", "rejected"].includes(decision ?? "")) return;
    const field = form.elements.namedItem("reason") as HTMLTextAreaElement;
    const reason = field.value.trim();
    field.minLength = decision === "approved" ? 0 : 3;
    field.setCustomValidity(decision !== "approved" && reason.length < 3 ? "Leg in minimaal drie tekens uit wat de bewoner moet aanpassen of waarom het huis is afgewezen." : "");
    if (!form.reportValidity()) return;
    if (await c.command("admin.zone.review", { zoneId: zone.id, expectedVersion: zone.version, decision, ...(decision !== "approved" && reason ? { reason } : {}) }, zone.version)) await onSaved();
  }}>
    <label className="ui-field">Reden voor de bewoner<textarea aria-label={`Beoordelingsreden voor ${zone.name}`} name="reason" minLength={3} maxLength={1000} rows={3} defaultValue={zone.reviewReason ?? ""} onInput={event => event.currentTarget.setCustomValidity("")} /></label>
    <p className="fn-caption">Bij een wijzigingsverzoek of afwijzing is een duidelijke reden verplicht. Goedkeuren wist de eerdere beoordelingsreden.</p>
    <div className="fn-table-actions"><button className="ui-button small" name="decision" value="approved" disabled={c.busy}>Goedkeuren</button><button className="ui-button small" name="decision" value="changes_requested" disabled={c.busy}>Wijziging vragen</button><button className="ui-button small" name="decision" value="rejected" disabled={c.busy}>Afwijzen</button></div>
  </form></details>;
}
