import "server-only";
import { ApiError } from "@/lib/http/api";
import { frightnightActor, frightnightConfig, frightnightServiceRpc, frightnightSnapshot } from "./server";
import { assertPaymentMatchesOrder, ContractPaymentAdapter, MollieTestAdapter, type PaymentOrder, type VerifiedPayment } from "./payments";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { validTestSlug } from "./edition-context";

function verifyOrderPayment(payment: VerifiedPayment, order: PaymentOrder, eventId = order.event_id) {
  try {
    assertPaymentMatchesOrder(payment, order);
    if (payment.eventId !== eventId) throw new Error("PSP_ORDER_MISMATCH");
  } catch { throw new ApiError(409, "PROVIDER_MISMATCH", "De betaalcontrole past niet bij deze bestelling en editie."); }
}

export function adapterFor(order: PaymentOrder) {
  const env = frightnightConfig();
  if (!order.provider_claimed || !["mollie", "contract"].includes(order.provider)) throw new ApiError(409, "PROVIDER_CLAIM_REQUIRED", "De betaalpoging mist een veilige providerbinding. Vraag de organisatie om herstel.");
  if (order.provider_ref && !(order.provider === "mollie" ? /^tr_[A-Za-z0-9]+$/ : /^ct_[a-f0-9-]{36}$/).test(order.provider_ref)) throw new ApiError(409, "PROVIDER_MISMATCH", "De opgeslagen betaalprovider en referentie komen niet overeen.");
  if (order.provider === "mollie") {
    if (!env.MOLLIE_TEST_API_KEY) throw new ApiError(503, "PAYMENT_CONFIGURATION", "Mollie testbetalingen zijn nog niet geconfigureerd. De organisatie moet MOLLIE_TEST_API_KEY instellen.");
    try { return new MollieTestAdapter(env.MOLLIE_TEST_API_KEY); }
    catch { throw new ApiError(503, "LIVE_PAYMENTS_BLOCKED", "Alleen een geldige Mollie testsleutel is toegestaan."); }
  }
  return new ContractPaymentAdapter(async (id) => {
    const order = await frightnightServiceRpc("frightnight_payment_lookup", { p_provider_ref: id }) as PaymentOrder;
    return { id, mode: "test", status: order.status as VerifiedPayment["status"], amountCents: order.amount_cents, currency: "EUR", orderId: order.order_id, eventId: order.event_id };
  });
}

export async function confirmProvider(payment: VerifiedPayment, slug?: string) {
  return frightnightServiceRpc("frightnight_payment_confirm", {
    ...(slug ? { p_slug: slug } : {}),
    p_provider_ref: payment.id, p_status: payment.status, p_amount_cents: payment.amountCents, p_currency: payment.currency,
    p_provider_event: `${payment.id}:${payment.status}`, p_metadata: { order_id: payment.orderId, event_id: payment.eventId, testmode: true, environment: "staging" },
  });
}

export async function paymentCheckout(commandId: string) {
  const actor = await frightnightActor();
  const order = await frightnightServiceRpc("frightnight_payment_claim", { p_actor: actor.userId, p_key: commandId, p_configured_provider: frightnightConfig().FRIGHTNIGHT_PAYMENT_PROVIDER }) as PaymentOrder;
  const provider = adapterFor(order);
  if (order.status === "paid") return { ok: true, result: { status: "paid" }, snapshot: await frightnightSnapshot() };
  let payment: VerifiedPayment;
  try { payment = await provider.create(order, frightnightConfig().APP_URL!); }
  catch { throw new ApiError(503, "PAYMENT_PROVIDER_UNAVAILABLE", "De betaalprovider kon geen testbetaling openen. Probeer opnieuw; je inschrijving blijft bewaard."); }
  verifyOrderPayment(payment, order);
  await frightnightServiceRpc("frightnight_payment_bind", { p_order_id: order.order_id, p_provider_ref: payment.id, p_checkout_url: payment.checkoutUrl ?? null });
  await confirmProvider(payment);
  return { ok: true, result: { checkoutUrl: payment.checkoutUrl, provider: provider.provider, simulated: provider.provider === "contract", message: provider.provider === "contract" ? "Contractsimulator: geen externe betaling. Een testbeheerder kan de providerstatus in het testcentrum naspelen." : "Mollie testcheckout", orderId: order.order_id }, snapshot: await frightnightSnapshot() };
}

export async function paymentReconcile() {
  const snapshot = await frightnightSnapshot();
  if (!snapshot.registration) throw new ApiError(409, "REGISTRATION_REQUIRED", "Schrijf je eerst in.");
  const order = await frightnightServiceRpc("frightnight_payment_for_actor", { p_actor: snapshot.actor.id }) as PaymentOrder | null;
  if (order?.provider_ref) {
    const payment = await adapterFor(order).read(order.provider_ref);
    verifyOrderPayment(payment, order, snapshot.event.id);
    await confirmProvider(payment);
  }
  return { ok: true, result: { reconciled: Boolean(order?.provider_ref) }, snapshot: await frightnightSnapshot() };
}

export async function simulatePayment(commandId: string, status: string, registrationId?: string, scenario: "normal" | "duplicate" | "delayed" = "normal") {
  const snapshot = await frightnightSnapshot();
  if (!snapshot.event.test || !snapshot.actor.capabilities.some(x => x === "event_admin" || x === "test_manage")) throw new ApiError(403, "TEST_ADMIN_REQUIRED", "Alleen testbeheer mag providerresultaten naspelen.");
  const order = await frightnightServiceRpc("frightnight_payment_test_claim", { p_actor: snapshot.actor.id, p_registration: registrationId ?? snapshot.registration?.id, p_key: commandId, p_configured_provider: frightnightConfig().FRIGHTNIGHT_PAYMENT_PROVIDER }) as PaymentOrder;
  if (order.provider !== "contract" || !order.provider_claimed) throw new ApiError(409, "CONTRACT_ONLY", "Alleen een vastgelegde contractbetaling kan worden nagespeeld.");
  const payment: VerifiedPayment = { id: order.provider_ref ?? `ct_${order.order_id}`, status: status as VerifiedPayment["status"], amountCents: order.amount_cents, currency: "EUR", mode: "test", orderId: order.order_id, eventId: order.event_id };
  await frightnightServiceRpc("frightnight_payment_bind", { p_order_id: order.order_id, p_provider_ref: payment.id, p_checkout_url: null });
  if (scenario === "delayed") await new Promise(resolve => setTimeout(resolve, 1500));
  await confirmProvider(payment);
  if (scenario === "duplicate") await confirmProvider(payment);
  return { ok: true, result: { simulated: true, status, provider: "contract", scenario, delayMilliseconds: scenario === "delayed" ? 1500 : 0 }, snapshot: await frightnightSnapshot() };
}

export async function paymentRefund(commandId: string, registrationId: string, reason: string) {
  const snapshot = await frightnightSnapshot();
  if (!snapshot.actor.capabilities.some(x => x === "event_admin" || x === "payments_manage")) throw new ApiError(403, "FINANCE_REQUIRED", "Je hebt geen betaalbeheerrechten.");
  const order = await frightnightServiceRpc("frightnight_payment_for_refund", { p_actor: snapshot.actor.id, p_registration: registrationId, p_key: commandId, p_reason: reason }) as PaymentOrder;
  if (order.status === "refunded") return { ok: true, result: { status: "refunded" }, snapshot: await frightnightSnapshot() };
  if (!order.provider_ref) throw new ApiError(409, "PAYMENT_NOT_FOUND", "Er is geen geverifieerde testbetaling om terug te betalen.");
  const provider = adapterFor(order);
  const payment = await provider.read(order.provider_ref);
  verifyOrderPayment(payment, order, snapshot.event.id);
  if (payment.status === "refunded") {
    await confirmProvider(payment);
    return { ok: true, result: { status: "refunded", simulated: provider.provider === "contract", reconciled: true }, snapshot: await frightnightSnapshot() };
  }
  const refund = await provider.refund(payment, commandId, reason);
  await frightnightServiceRpc("frightnight_payment_refund_record", { p_actor: snapshot.actor.id, p_order_id: order.order_id, p_provider_ref: refund.id, p_status: refund.status, p_key: commandId, p_reason: reason });
  return { ok: true, result: { status: refund.status, simulated: provider.provider === "contract" }, snapshot: await frightnightSnapshot() };
}

export async function paymentWebhook(id: string) {
  // Find the scoped order before using a public webhook as a provider lookup proxy.
  const client = createPrivilegedClient();
  const scope = await client!.schema("api").rpc("frightnight_payment_scope", { p_provider_ref: id });
  const slug = (scope.data as { slug?: string } | null)?.slug;
  if (scope.error || !slug || !validTestSlug(slug)) throw new ApiError(404, "PAYMENT_NOT_FOUND", "Onbekende testbetaling.");
  const order = await frightnightServiceRpc("frightnight_payment_lookup", { p_slug: slug, p_provider_ref: id }) as PaymentOrder;
  if (!order) throw new ApiError(404, "PAYMENT_NOT_FOUND", "Onbekende betaling.");
  if (order.provider !== "mollie") throw new ApiError(404, "PAYMENT_NOT_FOUND", "Onbekende Mollie testbetaling.");
  const payment = await adapterFor(order).read(id);
  verifyOrderPayment(payment, order);
  return confirmProvider(payment, slug);
}

/** Arm only the selected, actor-authorized fresh child run; browser supplies no provider or infrastructure binding. */
export async function armPaymentSandbox(runId: string, confirmation: string) {
  const snapshot = await frightnightSnapshot();
  if (confirmation !== snapshot.event.slug || runId !== snapshot.paymentSandbox?.runId) throw new ApiError(409, "SANDBOX_RUN_CONFLICT", "Controleer de editie en de actuele testronde.");
  const result = await frightnightServiceRpc("frightnight_contract_arm", {
    p_actor: snapshot.actor.id, p_run_id: runId,
    p_confirmation: `nocteiuvohesvqbowchw:staging:duindorphalloweenstg:${snapshot.event.slug}:${runId}`,
  });
  return { ok: true, result, snapshot: await frightnightSnapshot() };
}
