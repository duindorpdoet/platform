import { beforeEach, describe, expect, it, vi } from "vitest";
const calls = vi.hoisted(() => ({ provider: "mollie" as "mollie" | "contract", rpc: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => ({ FRIGHTNIGHT_ENABLED: "true", APP_ENVIRONMENT: "local", FRIGHTNIGHT_PAYMENT_PROVIDER: calls.provider }), allowedOrigins: () => new Set(["http://localhost:3000"]) }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: () => ({ abortSignal: calls.rpc }) }) }) }));
vi.mock("@/lib/supabase/privileged", () => ({ createPrivilegedClient: vi.fn() }));
vi.mock("@/lib/auth/session", () => ({ getActor: async () => ({ userId: "actor" }) }));
vi.mock("./edition-context", () => ({ activeFrightnightSlug: async () => "frightnight-2027-test-owned", validTestSlug: () => true }));
import { enrichPaymentSandbox, frightnightCommand, frightnightSnapshot } from "./server";
import type { FrightnightSnapshot } from "./model";
const base = { event: { id: "event", slug: "frightnight-2027-test-owned" }, actor: { id: "actor" } } as FrightnightSnapshot;
const sandbox = { policy: "configured", runId: "current", sandboxRunId: null, armed: false, canArm: true, reason: null, registrations: 0, orders: 0, mollieOrders: 0, canonical: false } as NonNullable<FrightnightSnapshot["paymentSandbox"]>;
beforeEach(() => { vi.resetAllMocks(); calls.provider = "mollie"; });
describe("server-only sandbox provider projection", () => {
 it("does not add privileged counts or provider controls to participant snapshots", () => {
  expect(enrichPaymentSandbox(base)).toBe(base); expect(enrichPaymentSandbox(base)).not.toHaveProperty("paymentSandbox");
 });
 it("uses trusted server configuration for a configured policy", () => {
  expect(enrichPaymentSandbox({ ...base, paymentSandbox: sandbox }).paymentSandbox).toMatchObject({ configuredProvider: "mollie", effectiveProvider: "mollie", blockedReason: null });
 });
 it("preserves configured canonical contract simulator", () => {
  calls.provider = "contract";
  expect(enrichPaymentSandbox({ ...base, paymentSandbox: { ...sandbox, canonical: true } }).paymentSandbox).toMatchObject({ effectiveProvider: "contract" });
 });
 it("uses contract only for the explicitly armed current run under global Mollie", () => {
  expect(enrichPaymentSandbox({ ...base, paymentSandbox: { ...sandbox, policy: "contract_sandbox", armed: true, sandboxRunId: "current" } }).paymentSandbox).toMatchObject({ configuredProvider: "mollie", effectiveProvider: "contract", blockedReason: null });
 });
 it.each([{ armed: false, sandboxRunId: "old" }, { armed: true, sandboxRunId: "old" }])("does not fall back to Mollie after reset (%j)", stale => {
  expect(enrichPaymentSandbox({ ...base, paymentSandbox: { ...sandbox, policy: "contract_sandbox", ...stale } }).paymentSandbox).toMatchObject({ effectiveProvider: null, blockedReason: "SANDBOX_REARM_REQUIRED" });
 });
 it("enriches both direct and command snapshots without changing the stable command result", async () => {
  const snapshot = { ...base, paymentSandbox: sandbox };
  calls.rpc.mockResolvedValueOnce({ data: snapshot, error: null });
  expect((await frightnightSnapshot()).paymentSandbox?.configuredProvider).toBe("mollie");
  calls.rpc.mockResolvedValueOnce({ data: { ok: true, result: { unchanged: true }, snapshot }, error: null });
  const command = await frightnightCommand("test.seed", {}, crypto.randomUUID());
  expect(command.result).toEqual({ unchanged: true }); expect(command.snapshot.paymentSandbox.configuredProvider).toBe("mollie");
 });
});
