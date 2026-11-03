import { describe, expect, it } from "vitest";
import type { FrightnightDestination, FrightnightEvent } from "./model";
import { destinationRecoveryReason } from "./recovery";

const event = { serverTime: "2027-10-30T15:05:00Z" } as FrightnightEvent;
const current = { leaseUntil: "2027-10-30T15:30:00Z", zone: { type: "candy", status: "open", opensAt: "2027-10-30T15:00:00Z", closesAt: "2027-10-30T16:00:00Z" } } as FrightnightDestination;
describe("recovery from the last server snapshot", () => {
  it("offers recovery for a closed or paused current destination without inventing another address", () => {
    for (const status of ["closed", "paused"]) expect(destinationRecoveryReason(event, { ...current, zone: { ...current.zone, status } })).toContain("actuele bestemming");
    expect(destinationRecoveryReason(event, current)).toBeNull();
    expect(destinationRecoveryReason(event, null)).toBeNull();
  });
  it("uses edition time for a lease and distinguishes an exact valid boundary from expiry", () => {
    expect(destinationRecoveryReason({ ...event, serverTime: current.leaseUntil }, current)).toBeNull();
    expect(destinationRecoveryReason({ ...event, serverTime: "2027-10-30T15:30:00.001Z" }, current)).toContain("reservering is verlopen");
  });
  it("recovers an ordinary time-window change while retaining a possible finale after the route window", () => {
    const later = { ...event, serverTime: "2027-10-30T16:01:00Z" };
    const extended = { ...current, leaseUntil: "2027-10-30T17:00:00Z" };
    expect(destinationRecoveryReason(later, extended)).toContain("openingstijd");
    expect(destinationRecoveryReason(later, { ...extended, zone: { ...extended.zone, type: "finale" } })).toBeNull();
    expect(destinationRecoveryReason(event, current, "paused")).toContain("tocht is gepauzeerd");
  });
});
