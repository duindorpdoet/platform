import { beforeEach, describe, expect, it, vi } from "vitest";
const calls = vi.hoisted(() => ({ snapshot: vi.fn(), rpc: vi.fn(), read: vi.fn(), refund: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("./server", () => ({ frightnightSnapshot: calls.snapshot, frightnightServiceRpc: calls.rpc, frightnightActor: vi.fn(), frightnightConfig: () => ({ FRIGHTNIGHT_PAYMENT_PROVIDER: "contract" }) }));
vi.mock("@/lib/supabase/privileged", () => ({ createPrivilegedClient: vi.fn() }));
vi.mock("./edition-context", () => ({ validTestSlug: () => true }));
vi.mock("./payments", async importOriginal => ({ ...await importOriginal<typeof import("./payments")>(), ContractPaymentAdapter: class { readonly provider = "contract"; read = calls.read; refund = calls.refund; } }));
import { paymentRefund } from "./payment-server";
import { ApiError } from "@/lib/http/api";

const order = { order_id: "1b30219e-e56d-4e0c-8361-d1c290776ac0", event_id: "2b30219e-e56d-4e0c-8361-d1c290776ac0", registration_id: "3b30219e-e56d-4e0c-8361-d1c290776ac0", amount_cents: 1050, currency: "EUR", status: "paid", provider_ref: "ct_order" };
const payment = { id: order.provider_ref, status: "paid", amountCents: 1050, currency: "EUR", mode: "test", orderId: order.order_id, eventId: order.event_id };
beforeEach(() => {
  vi.resetAllMocks();
  calls.snapshot.mockResolvedValue({ actor: { id: "actor", capabilities: ["payments_manage"] }, event: { id: order.event_id } });
  calls.rpc.mockImplementation(async name => name === "frightnight_payment_for_refund" ? order : {});
  calls.read.mockResolvedValue(payment);
  calls.refund.mockResolvedValue({ id: "contract_refund", status: "refunded" });
});
describe("refundcontrole vóór externe financiële handeling", () => {
  it.each([{ eventId: crypto.randomUUID() }, { orderId: crypto.randomUUID() }, { amountCents: 1 }, { currency: "USD" }, { id: "ct_foreign" }, { mode: "live" }])("roept geen providerrefund of bevestiging aan voor %j", async change => {
    calls.read.mockResolvedValue({ ...payment, ...change });
    await expect(paymentRefund(crypto.randomUUID(), order.registration_id, "Gecontroleerde testrefund")).rejects.toMatchObject({ status: 409, code: "PROVIDER_MISMATCH" });
    expect(calls.refund).not.toHaveBeenCalled();
    expect(calls.rpc.mock.calls.some(([name]) => name === "frightnight_payment_refund_record")).toBe(false);
  });
  it("verwerkt een passende geverifieerde betaling één keer via de provider", async () => {
    const commandId = crypto.randomUUID();
    await paymentRefund(commandId, order.registration_id, "Gecontroleerde testrefund");
    expect(calls.refund).toHaveBeenCalledExactlyOnceWith(payment, commandId, "Gecontroleerde testrefund");
    expect(calls.rpc).toHaveBeenCalledWith("frightnight_payment_refund_record", expect.objectContaining({ p_order_id: order.order_id, p_key: commandId, p_provider_ref: "contract_refund" }));
  });
  it("voert geen provideractie uit wanneer de atomaire orderclaim een tweede verzoek weigert", async () => {
    calls.rpc.mockRejectedValueOnce(new ApiError(409, "REFUND_ALREADY_REQUESTED", "Voor deze bestelling wordt al een terugbetaling verwerkt."));
    await expect(paymentRefund(crypto.randomUUID(), order.registration_id, "Gecontroleerde testrefund")).rejects.toMatchObject({ status: 409, code: "REFUND_ALREADY_REQUESTED" });
    expect(calls.read).not.toHaveBeenCalled();
    expect(calls.refund).not.toHaveBeenCalled();
  });
  it("respecteert bij twee verschillende gelijktijdige commands de databaseclaim vóór externe effecten", async () => {
    let claimed = false;
    calls.rpc.mockImplementation(async name => {
      if (name !== "frightnight_payment_for_refund") return {};
      if (claimed) throw new ApiError(409, "REFUND_ALREADY_REQUESTED", "Voor deze bestelling wordt al een terugbetaling verwerkt.");
      claimed = true;
      return order;
    });
    const results = await Promise.allSettled([
      paymentRefund(crypto.randomUUID(), order.registration_id, "Gecontroleerde eerste testrefund"),
      paymentRefund(crypto.randomUUID(), order.registration_id, "Gecontroleerde tweede testrefund"),
    ]);
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
    expect(calls.read).toHaveBeenCalledOnce();
    expect(calls.refund).toHaveBeenCalledOnce();
    expect(calls.rpc.mock.calls.filter(([name]) => name === "frightnight_payment_refund_record")).toHaveLength(1);
  });
  it("reconcilieert een bij de provider reeds volledig terugbetaalde order zonder nog een refund te sturen", async () => {
    calls.read.mockResolvedValue({ ...payment, status: "refunded" });
    const response = await paymentRefund(crypto.randomUUID(), order.registration_id, "Herstel na verloren providerantwoord");
    expect(response.result).toMatchObject({ status: "refunded", reconciled: true });
    expect(calls.refund).not.toHaveBeenCalled();
    expect(calls.rpc).toHaveBeenCalledWith("frightnight_payment_confirm", expect.objectContaining({ p_provider_ref: payment.id, p_status: "refunded", p_amount_cents: order.amount_cents, p_currency: "EUR" }));
    expect(calls.rpc.mock.calls.some(([name]) => name === "frightnight_payment_refund_record")).toBe(false);
  });
});
