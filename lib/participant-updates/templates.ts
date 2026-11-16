/** A copyable message only: applying this preset never changes payment state. */
export const PAYMENT_REQUEST_WITHDRAWN_2026 = {
  eventSlug: "duindorp-halloween-2026",
  title: "Het eerdere betaalverzoek is ingetrokken",
  body: [
    "<p>Hoi, het eerdere betaalverzoek voor de Halloweentocht van 31 oktober is uit jullie persoonlijke omgeving gehaald. Gebruik de oude betaallink niet meer.</p>",
    "<p>Op verzoek van meerdere deelnemers lopen we de betalingen nog één keer na. Staat er volgens onze administratie daarna nog een bedrag open, dan sturen we één nieuw betaalverzoek met de actuele betaallink. Zo houden we het eerlijk voor iedereen.</p>",
    "<p>Hebben jullie via de eerdere link al betaald en is dat nog niet verwerkt? Laat het ons weten. Dan kijken we het voor jullie na.</p>",
  ].join("\n"),
} as const;
