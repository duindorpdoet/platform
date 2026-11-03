import { describe, expect, it } from "vitest";
import { assertPaymentMatchesOrder, cents, ContractPaymentAdapter, MollieTestAdapter, money, verifiedMollie, type PaymentOrder } from "./payments";
const order: PaymentOrder = { provider: "mollie", provider_claimed: true, order_id: "1b30219e-e56d-4e0c-8361-d1c290776ac0", event_id: "2b30219e-e56d-4e0c-8361-d1c290776ac0", registration_id: "3b30219e-e56d-4e0c-8361-d1c290776ac0", amount_cents: 1050, currency: "EUR", status: "open" };
const providerPayment = { id: "tr_Fn2027example", mode: "test", status: "paid", amount: { value: "10.50", currency: "EUR" }, metadata: { order_id: order.order_id, event_id: order.event_id, environment: "staging" }, _links: { checkout: { href: "https://www.mollie.com/checkout/test" } } };
const refundListing = (items: unknown[] = [], next: string | null = null) => ({ count: items.length, _embedded: { refunds: items }, _links: { next: next ? { href: next } : null } });
const providerRefund = () => ({ resource: "refund", id: "re_example", mode: "test", paymentId: providerPayment.id, amount: { currency: "EUR", value: "10.50" }, status: "queued", metadata: { command_id: order.order_id, order_id: order.order_id, event_id: order.event_id, environment: "staging" } });
describe("FrightNight PSP testcontract", () => {
  it("gebruikt exacte eurocenten en weigert gedeeltelijke/gemanipuleerde bedragen", () => {
    expect(cents("10.50")).toBe(1050); expect(money(1050)).toBe("10.50");
    for (const invalid of ["3.5", "1e3", "-1.00", "NaN", "1.000"]) expect(() => cents(invalid)).toThrow();
    expect(() => money(3.5)).toThrow();
  });
  it("weigert livecredentials, liveresultaten en vreemde checkout-hosts", () => {
    expect(() => new MollieTestAdapter("live_example")).toThrow("MOLLIE_TEST_API_KEY_REQUIRED");
    expect(() => verifiedMollie({ ...providerPayment, mode: "live" })).toThrow();
    expect(() => verifiedMollie({ ...providerPayment, _links: { checkout: { href: "https://mollie.com.evil.invalid/pay" } } })).toThrow("INVALID_CHECKOUT_ORIGIN");
  });
  it("maakt serverbedrag en metadata leidend, met vaste idempotentiesleutel", async () => {
    const requests: RequestInit[] = [];
    const transport: typeof fetch = async (_url, init) => { requests.push(init!); return Response.json(providerPayment); };
    const adapter = new MollieTestAdapter(`test_${"x".repeat(30)}`, transport);
    await adapter.create(order, "https://staging-halloween.duindorpdoet.nl");
    const body = JSON.parse(requests[0].body as string);
    expect(body.amount.value).toBe("10.50"); expect(body.metadata.event_id).toBe(order.event_id);
    expect((requests[0].headers as Record<string, string>)["Idempotency-Key"]).toBe(order.order_id);
    expect(body.testmode).toBeUndefined(); expect(body.webhookUrl).toBe("https://staging-halloween.duindorpdoet.nl/api/frightnight/payments/webhook");
  });
  it("weigert een providerresponse voor een andere order", async () => {
    const transport: typeof fetch = async () => Response.json({ ...providerPayment, metadata: { ...providerPayment.metadata, order_id: "4b30219e-e56d-4e0c-8361-d1c290776ac0" } });
    await expect(new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).create(order, "https://staging-halloween.duindorpdoet.nl")).rejects.toThrow("PSP_ORDER_MISMATCH");
  });
  it("haalt webhookstatus opnieuw bij de provider en neemt geen browserstatus over", async () => {
    let target = "";
    const transport: typeof fetch = async (url) => { target = String(url); return Response.json(providerPayment); };
    const result = await new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).read("tr_Fn2027example");
    expect(target).toBe("https://api.mollie.com/v2/payments/tr_Fn2027example"); expect(result.status).toBe("paid");
  });
  it("onderscheidt terugbetaald van betaald en gebruikt idempotente testrefund", async () => {
    const p = verifiedMollie(providerPayment);
    expect(verifiedMollie({ ...providerPayment, amountRefunded: { value: "10.50", currency: "EUR" } }).status).toBe("refunded");
    let request: RequestInit | undefined;
    const transport: typeof fetch = async (_url, init) => { if (init?.method !== "POST") return Response.json(refundListing()); request = init; return Response.json(providerRefund()); };
    const adapter = new MollieTestAdapter(`test_${"x".repeat(30)}`, transport);
    await adapter.refund(p, order.order_id, "Gecontroleerde testrefund");
    expect((request!.headers as Record<string, string>)["Idempotency-Key"]).toBe(order.order_id);
    await expect(adapter.refund({ ...p, status: "open" }, order.order_id, "Test")).rejects.toThrow();
  });
  it("controleert ook bestaande betaalpogingen volledig bij retry", async () => {
    const transport: typeof fetch = async () => Response.json({ ...providerPayment, metadata: { ...providerPayment.metadata, event_id: "4b30219e-e56d-4e0c-8361-d1c290776ac0" } });
    await expect(new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).create({ ...order, provider_ref: providerPayment.id }, "https://staging-halloween.duindorpdoet.nl")).rejects.toThrow("PSP_ORDER_MISMATCH");
  });
  it("weigert een providerlookup die een andere betaalreferentie retourneert", async () => {
    const transport: typeof fetch = async () => Response.json({ ...providerPayment, id: "tr_OtherPayment" });
    await expect(new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).read(providerPayment.id)).rejects.toThrow("PSP_PAYMENT_REFERENCE_MISMATCH");
  });
  it.each([
    { mode: "live" }, { orderId: crypto.randomUUID() }, { eventId: crypto.randomUUID() }, { amountCents: 1 }, { currency: "USD" }, { id: "tr_OtherPayment" },
  ])("weigert een niet overeenkomende orderbinding: %j", (change) => {
    expect(() => assertPaymentMatchesOrder({ ...verifiedMollie(providerPayment), ...change } as ReturnType<typeof verifiedMollie>, { ...order, provider_ref: providerPayment.id })).toThrow("PSP_ORDER_MISMATCH");
  });
  it.each([
    { mode: "live" }, { paymentId: "tr_OtherPayment" }, { amount: { currency: "EUR", value: "0.01" } }, { status: "invented" },
    { metadata: { command_id: crypto.randomUUID(), order_id: order.order_id, event_id: order.event_id, environment: "staging" } },
    { metadata: { command_id: order.order_id, order_id: order.order_id, event_id: crypto.randomUUID(), environment: "staging" } },
  ])("weigert een niet overeenkomende refundresponse: %j", async (change) => {
    const payment = verifiedMollie(providerPayment);
    const response = { ...providerRefund(), ...change };
    const transport: typeof fetch = async (_url, init) => Response.json(init?.method === "POST" ? response : refundListing());
    await expect(new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).refund(payment, order.order_id, "Testrefund")).rejects.toThrow();
  });
  it("herstelt na verloren response dezelfde metadatarefund zonder opnieuw POST, ook buiten provider-idempotencycache", async () => {
    const requests: { url: string; method: string }[] = [];
    const transport: typeof fetch = async (url, init) => { requests.push({ url: String(url), method: init?.method ?? "GET" }); return Response.json(refundListing([providerRefund()])); };
    const result = await new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).refund(verifiedMollie(providerPayment), order.order_id, "Testrefund");
    expect(result).toEqual({ id: "re_example", status: "queued" });
    expect(requests).toEqual([{ url: `https://api.mollie.com/v2/payments/${providerPayment.id}/refunds?limit=250`, method: "GET" }]);
  });
  it.each([
    refundListing([{ ...providerRefund(), metadata: { ...providerRefund().metadata, command_id: crypto.randomUUID() } }]),
    refundListing([providerRefund()], "https://api.mollie.com/v2/payments/tr_Test/refunds?from=re_more"),
    refundListing([{ ...providerRefund(), metadata: { ...providerRefund().metadata, event_id: crypto.randomUUID() } }]),
    refundListing([{ ...providerRefund(), mode: "live" }]),
    refundListing([{ ...providerRefund(), paymentId: "tr_OtherPayment" }]),
    refundListing([providerRefund(), providerRefund()]),
  ])("weigert onzekere of afwijkende providerhistorie zonder nieuwe refundPOST", async history => {
    const methods: string[] = [];
    const transport: typeof fetch = async (_url, init) => { methods.push(init?.method ?? "GET"); return Response.json(history); };
    await expect(new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).refund(verifiedMollie(providerPayment), order.order_id, "Testrefund")).rejects.toThrow();
    expect(methods).toEqual(["GET"]);
  });
  it("laat alleen na geverifieerde mislukte of geannuleerde eerdere refund een nieuwe opdracht toe", async () => {
    const methods: string[] = [];
    const previous = { ...providerRefund(), status: "failed", metadata: null };
    const transport: typeof fetch = async (_url, init) => { methods.push(init?.method ?? "GET"); return Response.json(init?.method === "POST" ? providerRefund() : refundListing([previous])); };
    await new MollieTestAdapter(`test_${"x".repeat(30)}`, transport).refund(verifiedMollie(providerPayment), order.order_id, "Nieuwe testrefund");
    expect(methods).toEqual(["GET", "POST"]);
  });
  it("contractadapter slaat geen autoritatieve betaalstatus in geheugen op", async () => {
    const persisted = verifiedMollie(providerPayment);
    const adapter = new ContractPaymentAdapter(async () => persisted);
    const created = await adapter.create(order, "https://staging-halloween.duindorpdoet.nl");
    expect(created.status).toBe("open"); expect(created.checkoutUrl).toContain("betaling=contract");
    expect((await adapter.read(created.id)).status).toBe("paid");
  });
});
