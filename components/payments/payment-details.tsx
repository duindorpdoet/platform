import { ExternalLink, WalletCards } from "lucide-react";

export type PaymentBatch = {
  id: string;
  version: number;
  totalAmountCents: number;
  status: "awaiting_payment" | "reported" | "confirmed" | "needs_review";
  participants: string[];
  externalUrl: string | null;
  payerPaymentRequestId: string;
  payerName: string;
  canPay: boolean;
};

export type ParticipantPayment = {
  status: string;
  amountCents: number;
  externalUrl?: string | null;
  version: number;
  batch?: PaymentBatch | null;
};

export function paymentAmount(cents: number) {
  return new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
}

export function PaymentDetails({ payment }: { payment: ParticipantPayment }) {
  const batch = payment.batch;
  const shared = Boolean(batch && batch.participants.length > 1);
  const needsReview = batch?.status === "needs_review";
  const reported = batch?.status === "reported" || payment.status === "reported";
  const settled = ["confirmed", "waived", "refunded"].includes(payment.status) || batch?.status === "confirmed";
  const url = batch ? batch.externalUrl : payment.externalUrl;
  const canPay = (!batch || batch.canPay) && !settled && !needsReview && !reported && Boolean(url);
  if (!batch && !url) return null;
  return <section className="payment-details" aria-label={shared ? "Gezamenlijke betaling" : "Betaallink openen"}>
    <div className="payment-details-heading"><WalletCards aria-hidden="true" /><div><p className="participant-eyebrow">{shared ? "Eén gezamenlijke betaling" : "Jullie bijdrage"}</p><h3>{paymentAmount(batch?.totalAmountCents ?? payment.amountCents)}</h3></div></div>
    {batch && <p className="payment-participants"><strong>Gekoppeld aan:</strong> {batch.participants.join(" · ")}</p>}
    {shared && <p>Dit totaal is voor alle genoemde gezinnen samen. Jullie eigen aandeel is {paymentAmount(payment.amountCents)}. Het totaal wordt één keer betaald; betaal deze link niet ieder apart.</p>}
    {batch && <p className="payment-payer"><strong>Betaling loopt via {batch.payerName}.</strong>{!batch.canPay && " Je hoeft zelf geen aparte betaling te doen. Jullie inschrijving is in dit gezamenlijke bedrag inbegrepen."}</p>}
    {needsReview ? <p role="status">De inschrijving of betaling is gewijzigd. De organisatie controleert het gezamenlijke verzoek. Gebruik de eerdere betaallink niet.</p> : reported ? <p role="status">De betaling is gemeld en wordt gecontroleerd. Betaal niet nogmaals.</p> : settled ? <p>De betaling is afgehandeld.</p> : <p>De organisatie bevestigt de ontvangst na controle.</p>}
    {canPay && <a className="btn participant-primary-action" href={url!} target="_blank" rel="noreferrer noopener">{shared ? "Betaal het gezamenlijke bedrag" : "Open de betaallink"}<ExternalLink aria-hidden="true" /></a>}
  </section>;
}
