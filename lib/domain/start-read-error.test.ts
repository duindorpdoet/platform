import { describe, expect, it } from "vitest";
import { startReadError } from "./start-read-error";

describe("Startregie read failures", () => {
  it("identifies a PostgreSQL deadline without claiming a location write failed", () => {
    const copy = startReadError({ code: "57014", message: "canceling statement due to statement timeout" });
    expect(copy).toContain("database");
    expect(copy).toContain("57014");
    expect(copy).not.toMatch(/opslag|locatie/i);
  });
  it("distinguishes a browser deadline from a database deadline", () => {
    const copy = startReadError(new DOMException("signal timed out", "TimeoutError"), "Startafspraken controleren");
    expect(copy).toContain("Startafspraken controleren");
    expect(copy).not.toMatch(/database|opslag|locatie/i);
  });
  it("retains structured publication reasons instead of hiding them behind a transport warning", () => {
    const copy = startReadError({ code: "23514", details: JSON.stringify({ ready: false, reasons: [{ code: "FINALE_UNAVAILABLE", message: "Bevestig de finale.", action: "settings" }] }) });
    expect(copy).toBe("Bevestig de finale. (23514)");
  });
  it("preserves access failures and does not expose arbitrary SQL details", () => {
    const copy = startReadError({ code: "42501", message: "NOT_AUTHORIZED", details: "private SQL or participant details" });
    expect(copy).toContain("toegang");
    expect(copy).not.toContain("private SQL");
  });
});
