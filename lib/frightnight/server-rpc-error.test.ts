import { beforeEach, describe, expect, it, vi } from "vitest";

const calls = vi.hoisted(() => ({ rpc: vi.fn(), failure: { code: "PT409", message: "VERSION_CONFLICT" } }));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ schema: () => ({ rpc: calls.rpc }) }) }));
vi.mock("@/lib/supabase/privileged", () => ({ createPrivilegedClient: vi.fn() }));
vi.mock("@/lib/auth/session", () => ({ getActor: async () => ({ userId: "320ca8af-74a0-42b1-929f-44816275af2e" }) }));
vi.mock("@/lib/config/server-env", () => ({ serverEnv: () => ({ FRIGHTNIGHT_ENABLED: "true", APP_ENVIRONMENT: "test" }), allowedOrigins: () => new Set(["http://127.0.0.1:3137"]) }));
vi.mock("./edition-context", () => ({ activeFrightnightSlug: async () => "frightnight-2027-test-rpc-errors", validTestSlug: () => true }));
vi.mock("./payment-server", () => ({ armPaymentSandbox: vi.fn(), paymentCheckout: vi.fn(), paymentReconcile: vi.fn(), paymentRefund: vi.fn(), simulatePayment: vi.fn() }));

import { rpcError } from "./server";
import { POST } from "@/app/api/frightnight/command/route";

beforeEach(() => {
  vi.clearAllMocks();
  calls.failure = { code: "PT409", message: "VERSION_CONFLICT" };
  calls.rpc.mockImplementation(() => ({ abortSignal: async () => ({ data: null, error: calls.failure }) }));
});

describe("niet-herhaalbare zakelijke PostgREST-conflicten", () => {
  it.each(["PT409", "40001"])("behoudt voor %s de gecontroleerde versieconflictmelding", code => {
    expect(() => rpcError({ code, message: "VERSION_CONFLICT" })).toThrow(expect.objectContaining({ status: 409, code: "VERSION_CONFLICT", message: "De gegevens zijn intussen gewijzigd. Vernieuw de pagina en controleer de actuele situatie." }));
  });

  it.each(["query failed: select secret from app_private.credentials", "FN_DATABASE_ERROR: internal SQL detail", "unrecognized business conflict"])("verbergt onbekende PT409-details: %s", message => {
    expect(() => rpcError({ code: "PT409", message })).toThrow(expect.objectContaining({ status: 409, code: "CONCURRENT_CHANGE", message: "Er is tegelijk iets gewijzigd. Vernieuw en probeer opnieuw." }));
  });

  it("geeft een zakelijke PT409 één keer door als409 vanuit de echte commandhandler", async () => {
    const commandId = crypto.randomUUID();
    const payload = { zoneId: crypto.randomUUID(), expectedVersion: 3, decision: "approved" };
    const response = await POST(new Request("http://127.0.0.1:3137/api/frightnight/command", { method: "POST", headers: { Origin: "http://127.0.0.1:3137", "Content-Type": "application/json" }, body: JSON.stringify({ commandId, operation: "admin.zone.review", payload }) }));
    expect(response.status).toBe(409);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(await response.json()).toMatchObject({ error: { code: "VERSION_CONFLICT", message: "De gegevens zijn intussen gewijzigd. Vernieuw de pagina en controleer de actuele situatie." } });
    expect(calls.rpc).toHaveBeenCalledExactlyOnceWith("frightnight_command", { p_slug: "frightnight-2027-test-rpc-errors", p_command: "admin.zone.review", p_payload: payload, p_key: commandId });
  });

  it("geeft bij onbekende PT409 geen database-inhoud uit de commandhandler terug", async () => {
    calls.failure = { code: "PT409", message: "FN_DATABASE_ERROR: private schema SQL or credentials" };
    const response = await POST(new Request("http://127.0.0.1:3137/api/frightnight/command", { method: "POST", headers: { Origin: "http://127.0.0.1:3137", "Content-Type": "application/json" }, body: JSON.stringify({ commandId: crypto.randomUUID(), operation: "admin.zone.review", payload: { zoneId: crypto.randomUUID(), expectedVersion: 3, decision: "approved" } }) }));
    expect(response.status).toBe(409);
    const body = await response.json();
    expect(body.error.code).toBe("CONCURRENT_CHANGE");
    expect(JSON.stringify(body)).not.toMatch(/private schema|credentials|FN_DATABASE_ERROR/);
    expect(calls.rpc).toHaveBeenCalledOnce();
  });
});
