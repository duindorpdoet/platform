"use client";

import { useState, type ReactNode } from "react";
import "./child-payment-rows.css";
import { ExternalLink } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { paymentAmount, type ParticipantPayment } from "./payment-details";

export type ChildPaymentBatch = {
  id: string;
  version: number;
  totalAmountCents: number;
  status: string;
  childNames: string[];
  anchorChildId: string;
  anchorChildName: string;
  externalUrl: string | null;
  canPay: boolean;
  legacy?: boolean;
};
export type ChildPayment = { status: string; version: number; batch: ChildPaymentBatch | null };
export type PaymentChild = {
  id: string;
  childId?: string;
  firstName: string;
  status: string;
  unitPriceCents: number;
  canRemove?: boolean;
  payment?: ChildPayment | null;
};

/** Older snapshots retain their existing payment action while child records roll out. */
export function childPaymentFor(child: PaymentChild, children: PaymentChild[], payment?: ParticipantPayment | null): ChildPayment | null {
  if (child.payment !== undefined) return child.payment;
  if (!payment) return null;
  const anchor = children.find((item) => item.status === "active");
  const oldBatch = payment.batch;
  return {
    status: payment.status,
    version: payment.version,
    batch: anchor && (oldBatch || payment.externalUrl) ? {
      id: oldBatch?.id ?? "legacy-registration",
      version: oldBatch?.version ?? payment.version,
      totalAmountCents: oldBatch?.totalAmountCents ?? payment.amountCents,
      status: oldBatch?.status ?? payment.status,
      childNames: children.filter((item) => item.status === "active").map((item) => item.firstName),
      anchorChildId: anchor.childId ?? anchor.id,
      anchorChildName: oldBatch && !oldBatch.canPay ? oldBatch.payerName : anchor.firstName,
      externalUrl: oldBatch ? oldBatch.externalUrl : payment.externalUrl ?? null,
      canPay: oldBatch?.canPay ?? true,
      legacy: true,
    } : null,
  };
}

export function childPaymentState(child: PaymentChild, payment: ChildPayment | null) {
  const batch = payment?.batch;
  const status = batch?.status ?? payment?.status ?? "awaiting_link";
  const active = child.status === "active";
  const paid = active && ["confirmed", "waived"].includes(payment?.status ?? status);
  const included = Boolean(batch && (batch.anchorChildId !== (child.childId ?? child.id) || !batch.canPay));
  const canPay = Boolean(active && !paid && !included && status === "awaiting_payment" && batch?.externalUrl);
  const label = !active ? "Niet actief" : paid ? "Betaald" : status === "reported" ? "In controle"
    : status === "needs_review" ? "Tikkie wordt aangepast" : included ? "Tikkie inbegrepen" : "Tikkie volgt";
  return { paid, included, canPay, label, status };
}

export function ChildPaymentRows({ items: children, registrationId, legacyPayment, reload, additionalAction }: {
  items: PaymentChild[];
  registrationId: string;
  legacyPayment?: ParticipantPayment | null;
  reload: () => Promise<void>;
  additionalAction?: (child: PaymentChild) => ReactNode;
}) {
  const [reporting, setReporting] = useState<string | null>(null);
  const [notice, setNotice] = useState("");

  async function report(batch: ChildPaymentBatch) {
    if (reporting) return;
    const client = createClient();
    if (!client) { setNotice("De verbinding is niet beschikbaar. Probeer het opnieuw."); return; }
    setReporting(batch.id);
    setNotice("");
    try {
      const { error } = batch.legacy
        ? await client.schema("api").rpc("registration_report_payment", { _registration_id: registrationId, _expected_version: legacyPayment?.version })
        : await client.schema("api").rpc("child_payment_report", { _batch_id: batch.id, _expected_version: batch.version });
      setNotice(error ? "De betaalmelding kon niet worden verwerkt. We halen de actuele status op." : "De betaling is gemeld. De organisatie controleert de ontvangst; betaal niet opnieuw.");
      await reload();
    } catch { setNotice("De verbinding is onderbroken. Probeer het opnieuw zodra je verbinding hebt."); }
    finally { setReporting(null); }
  }

  return <div className="child-payment-list">
    {children.map((child) => {
      const payment = childPaymentFor(child, children, legacyPayment);
      const batch = payment?.batch;
      const state = childPaymentState(child, payment);
      return <div className="child-payment-row" key={child.id} data-child-payment-row={child.id}>
        <span className="participant-avatar" aria-hidden="true">{child.firstName.slice(0, 1)}</span>
        <div className="child-payment-main">
          <div className="child-payment-name-action"><strong>{child.firstName}</strong>
            {state.canPay && batch ? <a className="child-tikkie-action" href={batch.externalUrl!} target="_blank" rel="noreferrer noopener" aria-label={`Betaal Tikkie voor ${child.firstName}: ${paymentAmount(batch.totalAmountCents)}`}>Tikkie {paymentAmount(batch.totalAmountCents)}<ExternalLink aria-hidden="true" /></a>
              : <button className="child-tikkie-action" type="button" disabled>{state.label}</button>}
            {state.canPay && batch && <button type="button" className="child-payment-report" disabled={reporting !== null} onClick={() => void report(batch)} aria-label={`Betaling voor ${child.firstName} melden`}>{reporting === batch.id ? "Melden…" : "Betaling melden"}</button>}
          </div>
          <small>{child.status !== "active" ? "Afgezegd" : state.paid ? "Toegang actief" : state.status === "reported" ? "Betaling gemeld · wacht op controle" : `Aangemeld · ${paymentAmount(child.unitPriceCents)}`}</small>
          {child.status === "active" && state.included && batch && <small className="child-payment-included">Inbegrepen bij {batch.anchorChildName}.</small>}
          {state.canPay && batch && batch.childNames.length > 1 && <small className="child-payment-for">Eén betaling voor {batch.childNames.join(" · ")}.</small>}
          {state.status === "needs_review" && <small>De organisatie past de betaling aan. Gebruik de eerdere link niet.</small>}
        </div>
        {additionalAction && <div className="child-payment-extra">{additionalAction(child)}</div>}
      </div>;
    })}
    {notice && <p className="form-notice" role="status">{notice}</p>}
  </div>;
}
