import { beforeEach, describe, expect, it, vi } from "vitest";
const calls = vi.hoisted(() => ({ config: { FRIGHTNIGHT_PAYMENT_PROVIDER: "mollie", APP_URL: "https://staging-halloween.duindorpdoet.nl", MOLLIE_TEST_API_KEY: undefined as string | undefined }, snapshot: vi.fn(), actor: vi.fn(), rpc: vi.fn(), scope: vi.fn(), mollie: vi.fn(), contract: vi.fn(), create: vi.fn(), read: vi.fn(), refund: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", () => ({ frightnightConfig: () => calls.config, frightnightActor: calls.actor, frightnightSnapshot: calls.snapshot, frightnightServiceRpc: calls.rpc }));
vi.mock("@/lib/supabase/privileged", () => ({ createPrivilegedClient: () => ({ schema: () => ({ rpc: calls.scope }) }) }));
vi.mock("./payments", async original => ({ ...await original<typeof import("./payments")>(), MollieTestAdapter: class { provider = "mollie"; constructor(key: string) { calls.mollie(key); } create = calls.create; read = calls.read; refund = calls.refund; }, ContractPaymentAdapter: class { provider = "contract"; constructor() { calls.contract(); } create = calls.create; read = calls.read; refund = calls.refund; } }));
import { adapterFor, armPaymentSandbox, paymentCheckout, paymentReconcile, paymentRefund, paymentWebhook, simulatePayment } from "./payment-server";
import type { PaymentOrder } from "./payments";
const order: PaymentOrder = { order_id: "1b30219e-e56d-4e0c-8361-d1c290776ac0", event_id: "2b30219e-e56d-4e0c-8361-d1c290776ac0", registration_id: "3b30219e-e56d-4e0c-8361-d1c290776ac0", amount_cents: 700, currency: "EUR", status: "open", provider: "contract", provider_claimed: true };
const runId = "4b30219e-e56d-4e0c-8361-d1c290776ac0";
const payment = (provider: string, status = "paid") => ({ id: provider === "mollie" ? "tr_Sandbox123" : `ct_${order.order_id}`, mode: "test", status, amountCents: order.amount_cents, currency: "EUR", orderId: order.order_id, eventId: order.event_id, checkoutUrl: "https://staging-halloween.duindorpdoet.nl/nachtpas" });
beforeEach(() => {
 vi.resetAllMocks(); calls.config.FRIGHTNIGHT_PAYMENT_PROVIDER = "mollie"; calls.config.MOLLIE_TEST_API_KEY = undefined;
 calls.actor.mockResolvedValue({ userId: "actor" });
 calls.snapshot.mockResolvedValue({ event: { id: order.event_id, slug: "frightnight-2027-test-owned", test: true }, actor: { id: "actor", capabilities: ["event_admin"] }, registration: { id: order.registration_id }, paymentSandbox: { runId } });
 calls.rpc.mockResolvedValue(order); calls.create.mockResolvedValue(payment("contract", "open")); calls.read.mockResolvedValue(payment("contract")); calls.refund.mockResolvedValue({ id: "contract_refund", status: "refunded" });
 calls.scope.mockResolvedValue({ data: { slug: "frightnight-2027-test-owned" } });
});
describe("persisted provider boundary independent of global payment configuration", () => {
 it("claims before adapter construction and opens armed contract checkout with Mollie configured and no key", async () => {
  const key = crypto.randomUUID(); await paymentCheckout(key);
  expect(calls.rpc.mock.calls[0]).toEqual(["frightnight_payment_claim", { p_actor: "actor", p_key: key, p_configured_provider: "mollie" }]);
  expect(calls.contract).toHaveBeenCalledOnce(); expect(calls.mollie).not.toHaveBeenCalled(); expect(calls.create).toHaveBeenCalledWith(order, calls.config.APP_URL);
 });
 it("never constructs a provider when the database refuses the claim", async () => {
  calls.rpc.mockRejectedValue(new Error("SANDBOX_REARM_REQUIRED"));
  await expect(paymentCheckout(crypto.randomUUID())).rejects.toThrow("SANDBOX_REARM_REQUIRED");
  expect(calls.contract).not.toHaveBeenCalled(); expect(calls.mollie).not.toHaveBeenCalled();
 });
 it("allows only a database-claimed contract order in the simulator despite global Mollie", async () => {
  await simulatePayment(crypto.randomUUID(), "paid", order.registration_id);
  expect(calls.rpc).toHaveBeenCalledWith("frightnight_payment_test_claim", expect.objectContaining({ p_configured_provider: "mollie" }));
  expect(calls.mollie).not.toHaveBeenCalled(); expect(calls.rpc).toHaveBeenCalledWith("frightnight_payment_confirm", expect.objectContaining({ p_status: "paid" }));
 });
 it("denies simulation of a persisted Mollie order without any bind/confirmation", async () => {
  calls.rpc.mockResolvedValue({ ...order, provider: "mollie" });
  await expect(simulatePayment(crypto.randomUUID(), "paid")).rejects.toMatchObject({ code: "CONTRACT_ONLY" });
  expect(calls.rpc.mock.calls).toHaveLength(1);
 });
 it.each([undefined, false])("rejects an unclaimed order (%s) before any adapter", claimed => {
  expect(() => adapterFor({ ...order, provider_claimed: claimed as boolean })).toThrow(); expect(calls.contract).not.toHaveBeenCalled(); expect(calls.mollie).not.toHaveBeenCalled();
 });
 it("denies provider/reference mismatch before adapter construction", () => {
  expect(() => adapterFor({ ...order, provider_ref: "tr_Foreign123" })).toThrow(); expect(calls.contract).not.toHaveBeenCalled();
 });
 it("reconciles a persisted contract order under global Mollie without a Mollie key", async () => {
  calls.rpc.mockResolvedValue({ ...order, provider_ref: payment("contract").id }); await paymentReconcile();
  expect(calls.contract).toHaveBeenCalledOnce(); expect(calls.mollie).not.toHaveBeenCalled();
 });
 it("refunds a persisted contract order under global Mollie without an external provider", async () => {
  calls.rpc.mockResolvedValue({ ...order, status: "paid", provider_ref: payment("contract").id }); await paymentRefund(crypto.randomUUID(), order.registration_id, "Controlled own run refund");
  expect(calls.contract).toHaveBeenCalledOnce(); expect(calls.mollie).not.toHaveBeenCalled(); expect(calls.refund).toHaveBeenCalledOnce();
 });
 it("keeps a known Mollie webhook on Mollie after global configuration changes to contract", async () => {
  calls.config.FRIGHTNIGHT_PAYMENT_PROVIDER = "contract"; calls.config.MOLLIE_TEST_API_KEY = `test_${"x".repeat(24)}`;
  calls.rpc.mockResolvedValue({ ...order, provider: "mollie", provider_ref: "tr_Sandbox123" }); calls.read.mockResolvedValue(payment("mollie"));
  await paymentWebhook("tr_Sandbox123"); expect(calls.mollie).toHaveBeenCalledOnce(); expect(calls.contract).not.toHaveBeenCalled();
 });
 it("reconciles and refunds a persisted Mollie order after global configuration changes to contract", async () => {
  calls.config.FRIGHTNIGHT_PAYMENT_PROVIDER = "contract"; calls.config.MOLLIE_TEST_API_KEY = `test_${"x".repeat(24)}`;
  calls.rpc.mockResolvedValue({ ...order, provider: "mollie", status: "paid", provider_ref: "tr_Sandbox123" }); calls.read.mockResolvedValue(payment("mollie"));
  await paymentReconcile(); await paymentRefund(crypto.randomUUID(), order.registration_id, "Provider-bound financial recovery");
  expect(calls.mollie).toHaveBeenCalledTimes(2); expect(calls.contract).not.toHaveBeenCalled(); expect(calls.refund).toHaveBeenCalledOnce();
 });
 it("never uses a public Mollie webhook to look up a contract order at Mollie", async () => {
  calls.rpc.mockResolvedValue({ ...order, provider_ref: payment("contract").id });
  await expect(paymentWebhook("tr_Sandbox123")).rejects.toMatchObject({ status: 404 }); expect(calls.mollie).not.toHaveBeenCalled(); expect(calls.read).not.toHaveBeenCalled();
 });
 it("a persisted Mollie order still requires a real test key, regardless of global contract", () => {
  calls.config.FRIGHTNIGHT_PAYMENT_PROVIDER = "contract";
  expect(() => adapterFor({ ...order, provider: "mollie" })).toThrow("MOLLIE_TEST_API_KEY"); expect(calls.contract).not.toHaveBeenCalled();
 });
 it("constructs full sandbox binding from authorized server snapshot, never browser infrastructure input", async () => {
  await armPaymentSandbox(runId, "frightnight-2027-test-owned");
  expect(calls.rpc).toHaveBeenCalledExactlyOnceWith("frightnight_contract_arm", { p_actor: "actor", p_run_id: runId, p_confirmation: `nocteiuvohesvqbowchw:staging:duindorphalloweenstg:frightnight-2027-test-owned:${runId}` });
 });
 it.each([[runId, "foreign"], [crypto.randomUUID(), "frightnight-2027-test-owned"]])("denies wrong browser confirmation or run before service delegation", async (run, slug) => {
  await expect(armPaymentSandbox(run, slug)).rejects.toMatchObject({ code: "SANDBOX_RUN_CONFLICT" }); expect(calls.rpc).not.toHaveBeenCalled();
 });
});
