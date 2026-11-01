import { afterEach, describe, expect, it, vi } from "vitest";
import { actualPortalImpact, registeredPortalImpact, type PortalRoom } from "@/lib/domain/poortkamer";
import { portalCertificateDetails, sharePortalCertificate } from "@/components/portal/portal-certificate";

afterEach(() => vi.unstubAllGlobals());
describe("physical portal impact and export privacy", () => {
  it("requires explicit valid physical totals and never falls back to seals, visits or expected children", () => {
    const room = { impact: undefined, visits: { recap: { groups: 100, children: 500 } }, seals: Array(90).fill({ source: "event_closure" }) };
    expect(actualPortalImpact(room)).toBeNull();
    expect(actualPortalImpact({ impact: { actualGroups: 2, actualChildren: 7 } })).toEqual({ actualGroups: 2, actualChildren: 7 });
    expect(actualPortalImpact({ impact: { actualGroups: 0, actualChildren: 0 } })).toEqual({ actualGroups: 0, actualChildren: 0 });
    for (const value of [-1, .5, Infinity, NaN, Number.MAX_SAFE_INTEGER + 1]) expect(actualPortalImpact({ impact: { actualGroups: value, actualChildren: 2 } })).toBeNull();
  });
  it("projects only public certificate fields, independently of extra identity, address and child properties", () => {
    const room = { eventDate: "2026-10-31", portal: { id: "private-id", name: "De warme pompoen", code: "P-42", address: "PRIVATE_ADDRESS", secret: "PRIVATE_TOKEN" }, impact: { actualGroups: 3, actualChildren: 8 }, registeredImpact: { registeredGroups: 12, registeredChildren: 47, unexpectedExtra: "PRIVATE_IMPACT" }, userId: "PRIVATE_USER", children: [{ name: "PRIVATE_CHILD" }], contacts: ["PRIVATE_EMAIL"] } as unknown as PortalRoom;
    expect(portalCertificateDetails(room)).toEqual({ portalName: "De warme pompoen", portalCode: "P-42", year: "2026", registeredGroups: 12, registeredChildren: 47 });
    expect(JSON.stringify(portalCertificateDetails(room))).not.toContain("PRIVATE");
    expect(portalCertificateDetails({ ...room, eventDate: "unknown" })).toBeNull();
  });
  it("requires the explicit registered projection and never substitutes physical visits, gift seals or recap estimates", () => {
    const room = { registeredImpact: undefined, impact: { actualGroups: 3, actualChildren: 8 }, visits: { recap: { groups: 100, children: 500 } }, seals: Array(90).fill({ source: "event_closure" }) };
    expect(registeredPortalImpact(room)).toBeNull();
    expect(registeredPortalImpact({ registeredImpact: { registeredGroups: 12, registeredChildren: 47 } })).toEqual({ registeredGroups: 12, registeredChildren: 47 });
    expect(registeredPortalImpact({ registeredImpact: { registeredGroups: 0, registeredChildren: 0 } })).toEqual({ registeredGroups: 0, registeredChildren: 0 });
    for (const value of [-1, .5, Infinity, NaN, Number.MAX_SAFE_INTEGER + 1]) {
      expect(registeredPortalImpact({ registeredImpact: { registeredGroups: value, registeredChildren: 2 } })).toBeNull();
      expect(registeredPortalImpact({ registeredImpact: { registeredGroups: 2, registeredChildren: value } })).toBeNull();
    }
    const certificateRoom = { ...room, eventDate: "2026-10-31", portal: { name: "Een poort", code: "P-1" } } as unknown as PortalRoom;
    expect(portalCertificateDetails(certificateRoom)).toBeNull();
  });
});
describe("explicit prepared-file sharing", () => {
  const file = new File(["local certificate"], "certificaat-P42-2026.png", { type: "image/png" });
  function downloads() {
    const click = vi.fn(), remove = vi.fn(), append = vi.fn();
    vi.stubGlobal("document", { body: { append }, createElement: () => ({ click, remove }) });
    vi.stubGlobal("URL", { createObjectURL: vi.fn(() => "blob:local-only"), revokeObjectURL: vi.fn() });
    return click;
  }
  it("opens native sharing synchronously with the prepared file and does not download", async () => {
    const click = downloads(), share = vi.fn(async () => {});
    vi.stubGlobal("navigator", { canShare: () => true, share });
    const pending = sharePortalCertificate(file);
    expect(share).toHaveBeenCalledWith({ title: "Ons Poortcertificaat", files: [file] });
    expect(await pending).toBe("shared"); expect(click).not.toHaveBeenCalled();
  });
  it("a cancelled share does not download or retry", async () => {
    const click = downloads(), share = vi.fn(async () => { throw new DOMException("Cancelled", "AbortError"); });
    vi.stubGlobal("navigator", { canShare: () => true, share });
    expect(await sharePortalCertificate(file)).toBe("cancelled"); expect(share).toHaveBeenCalledOnce(); expect(click).not.toHaveBeenCalled();
  });
  it("unsupported sharing downloads the same local file", async () => {
    vi.useFakeTimers();
    try { const click = downloads(); vi.stubGlobal("navigator", { canShare: () => false }); expect(await sharePortalCertificate(file)).toBe("downloaded"); expect(click).toHaveBeenCalledOnce(); vi.runAllTimers(); }
    finally { vi.useRealTimers(); }
  });
  it("a native share failure leaves retry or download to a new explicit user action", async () => {
    const click = downloads(), share = vi.fn(async () => { throw new DOMException("Not allowed", "NotAllowedError"); });
    vi.stubGlobal("navigator", { canShare: () => true, share });
    await expect(sharePortalCertificate(file)).rejects.toMatchObject({ name: "NotAllowedError" });
    expect(share).toHaveBeenCalledOnce(); expect(click).not.toHaveBeenCalled();
  });
});
