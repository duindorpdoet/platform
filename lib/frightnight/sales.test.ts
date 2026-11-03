import { describe, expect, it } from "vitest";
import type { FrightnightEvent } from "./model";
import { salesMessage } from "./sales";

const event = { closed: false, salesOpen: true, salesClosesAt: "2027-10-30T16:00:00Z", serverTime: "2027-10-30T15:59:59Z", enabledRoutes: ["lantern", "roots"] } as FrightnightEvent;
describe("sales snapshot explanation", () => {
  it("uses edition time and closes at the exact configured instant", () => {
    expect(salesMessage(event, "lantern")).toBeNull();
    expect(salesMessage({ ...event, serverTime: "2027-10-30T16:00:00Z" }, "lantern")).toContain("verkoop is gesloten");
  });
  it("distinguishes sales closure, unavailable route and edition closure", () => {
    expect(salesMessage({ ...event, salesOpen: false })).toContain("routes blijven beschikbaar");
    expect(salesMessage({ ...event, enabledRoutes: ["roots"] }, "lantern")).toContain("Lantaarnentocht");
    expect(salesMessage({ ...event, enabledRoutes: ["roots"] }, "roots")).toBeNull();
    expect(salesMessage({ ...event, closed: true })).toContain("editie is afgesloten");
  });
  it("allows a deliberately unset close time and explains either disabled route", () => {
    expect(salesMessage({ ...event, salesClosesAt: null })).toBeNull();
    expect(salesMessage({ ...event, enabledRoutes: ["lantern"] }, "roots")).toContain("Worteltocht");
    expect(salesMessage({ ...event, enabledRoutes: [] })).toContain("geen tochten beschikbaar");
  });
});
