import { z } from "zod";

export type PaymentState = "open" | "pending" | "authorized" | "paid" | "failed" | "canceled" | "expired" | "refunded";
export interface PaymentOrder { order_id: string; event_id: string; registration_id: string; amount_cents: number; currency: string; status: string; provider_ref?: string | null; checkout_url?: string | null; }
export interface VerifiedPayment { id: string; status: PaymentState; amountCents: number; currency: "EUR"; mode: "test"; orderId: string; eventId: string; checkoutUrl?: string; }
export interface PaymentAdapter {
  readonly provider: "mollie" | "contract";
  create(order: PaymentOrder, origin: string): Promise<VerifiedPayment>;
  read(id: string): Promise<VerifiedPayment>;
  refund(payment: VerifiedPayment, commandId: string, reason: string): Promise<{ id: string; status: string }>;
}
const amountSchema = z.object({ currency: z.literal("EUR"), value: z.string().regex(/^\d{1,8}\.\d{2}$/) });
const mollieSchema = z.object({
  id: z.string().regex(/^tr_[A-Za-z0-9]+$/), mode: z.literal("test"),
  status: z.enum(["open", "pending", "authorized", "paid", "failed", "canceled", "expired"]),
  amount: amountSchema, amountRefunded: amountSchema.optional(),
  metadata: z.object({ order_id: z.uuid(), event_id: z.uuid(), environment: z.literal("staging") }),
  _links: z.object({ checkout: z.object({ href: z.url() }).optional() }).optional(),
});
const refundBaseSchema = z.object({
  resource: z.literal("refund"), id: z.string().regex(/^re_[A-Za-z0-9]{5,60}$/), mode: z.literal("test"),
  paymentId: z.string().regex(/^tr_[A-Za-z0-9]{5,60}$/), amount: amountSchema,
  status: z.enum(["queued", "pending", "processing", "refunded", "failed", "canceled"]),
  metadata: z.unknown(),
});
const refundSchema = refundBaseSchema.extend({
  metadata: z.object({ command_id: z.uuid(), order_id: z.uuid(), event_id: z.uuid(), environment: z.literal("staging") }),
});
const refundListSchema = z.object({
  count: z.number().int().min(0).max(250), _embedded: z.object({ refunds: z.array(refundBaseSchema).max(250) }),
  _links: z.object({ next: z.object({ href: z.url() }).nullable() }),
});

function verifiedRefund(value: unknown, payment: VerifiedPayment, commandId: string) {
  const refund = refundSchema.parse(value);
  if (refund.paymentId !== payment.id || cents(refund.amount.value) !== payment.amountCents ||
    refund.metadata.command_id !== commandId || refund.metadata.order_id !== payment.orderId || refund.metadata.event_id !== payment.eventId) throw new Error("PSP_REFUND_MISMATCH");
  return { id: refund.id, status: refund.status };
}

/** Check the complete persisted binding before accepting state or issuing a refund. */
export function assertPaymentMatchesOrder(payment: VerifiedPayment, order: PaymentOrder) {
  if (payment.mode !== "test" || payment.orderId !== order.order_id || payment.eventId !== order.event_id ||
    payment.amountCents !== order.amount_cents || payment.currency !== order.currency || order.currency !== "EUR" ||
    (order.provider_ref && payment.id !== order.provider_ref)) throw new Error("PSP_ORDER_MISMATCH");
}

export function cents(value: string) {
  if (!/^\d{1,8}\.\d{2}$/.test(value)) throw new Error("INVALID_PROVIDER_AMOUNT");
  const [whole, fraction] = value.split(".");
  return Number(whole) * 100 + Number(fraction);
}
export function money(amountCents: number) {
  if (!Number.isSafeInteger(amountCents) || amountCents < 1 || amountCents > 100_000_000) throw new Error("INVALID_ORDER_AMOUNT");
  return `${Math.floor(amountCents / 100)}.${String(amountCents % 100).padStart(2, "0")}`;
}
export function verifiedMollie(value: unknown): VerifiedPayment {
  const p = mollieSchema.parse(value);
  if (p.amountRefunded && cents(p.amountRefunded.value) > cents(p.amount.value)) throw new Error("PSP_REFUND_AMOUNT_MISMATCH");
  const checkoutUrl = p._links?.checkout?.href;
  if (checkoutUrl && (new URL(checkoutUrl).protocol !== "https:" || !new URL(checkoutUrl).hostname.endsWith(".mollie.com"))) throw new Error("INVALID_CHECKOUT_ORIGIN");
  return { id: p.id, status: p.amountRefunded && cents(p.amountRefunded.value) === cents(p.amount.value) ? "refunded" : p.status, amountCents: cents(p.amount.value), currency: p.amount.currency, mode: p.mode, orderId: p.metadata.order_id, eventId: p.metadata.event_id, checkoutUrl };
}

export class MollieTestAdapter implements PaymentAdapter {
  readonly provider = "mollie" as const;
  constructor(private readonly key: string, private readonly transport: typeof fetch = fetch) {
    if (!/^test_[A-Za-z0-9]{20,}$/.test(key)) throw new Error("MOLLIE_TEST_API_KEY_REQUIRED");
  }
  private async request(path: string, init: RequestInit = {}) {
    const response = await this.transport(`https://api.mollie.com/v2${path}`, {
      ...init, redirect: "error", cache: "no-store", signal: AbortSignal.timeout(8_000),
      headers: { "Authorization": `Bearer ${this.key}`, "Content-Type": "application/json", ...init.headers },
    });
    if (!response.ok) throw new Error(`PSP_HTTP_${response.status}`);
    return response.json() as Promise<unknown>;
  }
  async create(order: PaymentOrder, origin: string) {
    const result = order.provider_ref ? await this.read(order.provider_ref) : verifiedMollie(await this.request("/payments", { method: "POST", headers: { "Idempotency-Key": order.order_id }, body: JSON.stringify({
      amount: { currency: "EUR", value: money(order.amount_cents) }, description: "Duindorp FrightNight 2027 — TEST Nachtpas",
      redirectUrl: new URL("/nachtpas?betaling=terug", origin).href,
      webhookUrl: new URL("/api/frightnight/payments/webhook", origin).href,
      metadata: { order_id: order.order_id, event_id: order.event_id, environment: "staging" },
    }) }));
    assertPaymentMatchesOrder(result, order);
    return result;
  }
  async read(id: string) {
    if (!/^tr_[A-Za-z0-9]{5,60}$/.test(id)) throw new Error("INVALID_PAYMENT_REFERENCE");
    const payment = verifiedMollie(await this.request(`/payments/${encodeURIComponent(id)}`));
    if (payment.id !== id) throw new Error("PSP_PAYMENT_REFERENCE_MISMATCH");
    return payment;
  }
  async refund(payment: VerifiedPayment, commandId: string, reason: string) {
    if (payment.mode !== "test" || payment.status !== "paid") throw new Error("TEST_PAID_PAYMENT_REQUIRED");
    // Mollie caches idempotency keys for only one hour. Recover the durable
    // metadata-bound refund first, including after a lost response or key rotation.
    const previous = refundListSchema.parse(await this.request(`/payments/${encodeURIComponent(payment.id)}/refunds?limit=250`));
    if (previous._links.next || previous.count !== previous._embedded.refunds.length) throw new Error("PSP_REFUND_REVIEW_REQUIRED");
    const matches = [];
    for (const refund of previous._embedded.refunds) {
      if (refund.paymentId !== payment.id) throw new Error("PSP_REFUND_MISMATCH");
      if (typeof refund.metadata === "object" && refund.metadata !== null && "command_id" in refund.metadata && refund.metadata.command_id === commandId) matches.push(refund);
      else if (!["failed", "canceled"].includes(refund.status)) throw new Error("PSP_REFUND_ALREADY_EXISTS");
    }
    if (matches.length > 1) throw new Error("PSP_REFUND_REVIEW_REQUIRED");
    if (matches.length) return verifiedRefund(matches[0], payment, commandId);
    const data = await this.request(`/payments/${encodeURIComponent(payment.id)}/refunds`, {
      method: "POST", headers: { "Idempotency-Key": commandId }, body: JSON.stringify({ amount: { currency: "EUR", value: money(payment.amountCents) }, description: reason.slice(0, 200), metadata: { command_id: commandId, order_id: payment.orderId, event_id: payment.eventId, environment: "staging" } }),
    });
    return verifiedRefund(data, payment, commandId);
  }
}

/** This adapter models provider contracts only. Its state always comes from the database. */
export class ContractPaymentAdapter implements PaymentAdapter {
  readonly provider = "contract" as const;
  constructor(private readonly lookup: (id: string) => Promise<VerifiedPayment>) {}
  async create(order: PaymentOrder, origin: string): Promise<VerifiedPayment> {
    return { id: `ct_${order.order_id}`, status: "open", amountCents: order.amount_cents, currency: "EUR", mode: "test", orderId: order.order_id, eventId: order.event_id, checkoutUrl: new URL("/nachtpas?betaling=contract", origin).href };
  }
  read(id: string) { return this.lookup(id); }
  async refund(payment: VerifiedPayment, commandId: string) {
    if (payment.status !== "paid" || payment.mode !== "test") throw new Error("TEST_PAID_PAYMENT_REQUIRED");
    return { id: `contract_refund_${commandId}`, status: "refunded" };
  }
}
