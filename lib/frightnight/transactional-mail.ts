import { z } from "zod";

const slug = z.string().regex(/^frightnight-2027-test(?:-[a-z0-9-]{1,90})?$/);
const common = z.object({ brandVersion: z.literal(7), message: z.string().trim().min(1).max(4000), label: z.string().trim().max(120).optional() }).strict();
const payment = z.object({ brandVersion: z.literal(7), orderId: z.uuid(), amountCents: z.number().int().min(1).max(100_000_000), fulfillment: z.enum(["active", "start_required", "quote_mismatch", "cancelled"]).default("active") }).strict();
const copy = {
  "frightnight-registration-confirmed": ["Je inschrijving is bewaard", "Jullie avontuur krijgt vorm"],
  "frightnight-payment-confirmed": ["Je testbetaling is bevestigd", "Je Nachtpas staat klaar"],
  "frightnight-payment-status": ["Er is nieuws over je testbetaling", "Bekijk je betaalstatus"],
  "frightnight-house-submitted": ["Je huisaanmelding is ontvangen", "Een licht in de wijk"],
  "frightnight-house-approved": ["Je zone is goedgekeurd", "Welkom in het Oogstdorp"],
  "frightnight-reminder": ["Tot op het Duinpad", "De nacht komt dichterbij"],
  "frightnight-help-reply": ["Het hulppunt heeft geantwoord", "We helpen je op weg"],
  "frightnight-closed": ["Deze testavond is afgesloten", "Het Duinlicht blijft bij ons"],
  "frightnight-thanks": ["Bedankt voor jullie Lichtvonken", "De nacht was van ons"],
} as const;
export type FrightnightMailTemplate = keyof typeof copy;
const escape = (value: string) => value.replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]!));

/** Rendering/capture only. No transport, address lookup, Auth or delivery is possible. */
export function renderFrightnightTransactionalMail(template: string, payload: unknown, context: { eventSlug: string; logoDataUri?: string }) {
  const eventSlug = slug.parse(context.eventSlug);
  if (!Object.hasOwn(copy, template)) throw new Error("UNKNOWN_FRIGHTNIGHT_MAIL_TEMPLATE");
  const [subject, defaultTitle] = copy[template as FrightnightMailTemplate];
  let title: string = defaultTitle;
  let message: string;
  let reference = "";
  if (template === "frightnight-payment-confirmed") {
    const values = payment.parse(payload);
    const amount = `${Math.floor(values.amountCents / 100)},${String(values.amountCents % 100).padStart(2, "0")}`;
    const received = `De server heeft jullie testbetaling van € ${amount} bevestigd.`;
    if (values.fulfillment === "cancelled") {
      title = "Betaling ontvangen na annulering";
      message = `${received} De inschrijving blijft geannuleerd; deze ontvangst opent geen tocht of nieuwe plaatsen. Neem contact op met het hulppunt voor controle of testterugbetaling.`;
    } else if (values.fulfillment === "quote_mismatch") {
      title = "Betaling ontvangen; bedrag afstemmen";
      message = `${received} Het ontvangen bedrag sluit niet aan bij de vastgelegde inschrijving. Nieuwe tochtrechten blijven geblokkeerd. Neem contact op met het hulppunt voor controle of testterugbetaling.`;
    } else if (values.fulfillment === "start_required") {
      title = "Betaling ontvangen; startmoment afstemmen";
      message = `${received} De tijdelijke startreservering was verlopen en het gekozen blok is vol. Er is nog geen actieve inschrijving. Kies een beschikbaar startmoment in je Nachtpas of neem contact op met het hulppunt voor omboeken of testterugbetaling.`;
    } else {
      message = `${received} Open je Nachtpas voor jullie tocht en verwachte startmoment. Een startblok helpt de aankomst spreiden; het is geen verplichte afspraak.`;
    }
    reference = `Orderreferentie: ${values.orderId}`;
  } else {
    const values = common.parse(payload);
    message = `${values.label ? `${values.label},\n\n` : ""}${values.message}`;
  }
  const logo = context.logoDataUri && /^data:image\/(?:png|webp);base64,[A-Za-z0-9+/=]{32,750000}$/.test(context.logoDataUri) ? `<img width="120" height="120" src="${context.logoDataUri}" alt="De Pompoenkoning" style="object-fit:contain">` : "";
  if (context.logoDataUri && !logo) throw new Error("INVALID_MAIL_IMAGE");
  const text = `Duindorp FrightNight 2027\nTESTVOORBEELD — NIET VERZONDEN\n${title}\n\n${message}\n\n${reference ? `${reference}\n` : ""}30 oktober 2027 · Europe/Amsterdam\nStart en finale: Oogstdorp · Duinpad\nTesteditie: ${eventSlug}\n\nDit is een afgeschermde stagingcapture. Er is geen e-mail bezorgd. Open je Nachtpas op https://staging-halloween.duindorpdoet.nl/nachtpas. Hulp: het hulppunt op het Duinpad.`;
  const html = `<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(subject)} · FrightNight 2027</title><style>body{margin:0;background:#081712;color:#f2e9d2;font:16px/1.7 Arial,sans-serif}main{max-width:620px;margin:35px auto;padding:35px;border:1px solid #bb8653;background:#11291d}header{text-align:center;border-bottom:2px dashed #bb8653;padding-bottom:25px}h1{font:700 48px/1.05 Impact,'Arial Narrow',sans-serif;text-transform:uppercase;color:#f2d3a8}p{overflow-wrap:anywhere}.badge{display:inline-block;border:1px solid #d79a52;padding:5px 12px;font-size:12px;color:#f4b770}.reference,footer{font-size:12px;color:#d0c3a7}footer{border-top:2px dashed #bb8653;margin-top:30px;padding-top:20px}a{color:#edaa64}@media print{body,main{background:#fff;color:#13271c}main{margin:0;border-color:#755333}h1,footer,.reference{color:#13271c}}</style></head><body><main><header>${logo}<p>DUINDORP FRIGHTNIGHT 2027</p><span class="badge">TESTVOORBEELD · NIET VERZONDEN</span></header><h1>${escape(title)}</h1><p>${escape(message).replaceAll("\n", "<br>")}</p>${reference ? `<p class="reference">${escape(reference)}</p>` : ""}<p><a href="https://staging-halloween.duindorpdoet.nl/nachtpas">Open je eigen Nachtpas</a></p><footer>30 oktober 2027 · Europe/Amsterdam<br>Start en finale: Oogstdorp · Duinpad<br>Testeditie: ${escape(eventSlug)}<p>Dit is een afgeschermde stagingcapture. Er is geen e-mail bezorgd. Hulp: het hulppunt op het Duinpad.</p></footer></main></body></html>`;
  return { subject: `${subject} · FrightNight 2027`, text, html, delivery: "sink" as const, externallyDelivered: false as const };
}
