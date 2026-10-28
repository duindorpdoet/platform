import { describe, expect, it } from "vitest";
import { existingStartReservations, fixedGroupPlanningParties } from "./start-schedule-input";
import { dominantEndPreference, dominantStartPreference } from "./start-preference";
import { planningStartTimes } from "./start-slots";

const at = (clock: string) => new Date(`2026-10-31T${clock}:00+01:00`).toISOString();
const registration = (id: string, start: string | null, end: string | null) => ({ id, preferredStartAt: start && at(start), desiredEndAt: end && at(end), ordinaryStopAt: null, paymentEligible: true });

describe("start schedule input chain", () => {
  it("passes original majority votes and end wishes through fixedGroupId without child weighting", () => {
    const families = [registration("one", "17:00", "19:00"), registration("two", "17:00", "19:00"), registration("minority", "18:00", "18:30"), registration("neutral", null, null)];
    for (const registrations of [families, [...families].reverse()]) {
      const parties = fixedGroupPlanningParties([{ id: "confirmed-composition", childCount: 18, registrations, schedule: null }]);
      expect(parties.map(party => party.id).sort()).toEqual(families.map(family => family.id).sort());
      expect(parties.every(party => party.fixedGroupId === "confirmed-composition")).toBe(true);
      expect(parties.reduce((sum, party) => sum + party.childCount, 0)).toBe(18);
      expect(dominantStartPreference(parties)).toBe(at("17:00"));
      expect(dominantEndPreference(parties)).toBe(at("19:00"));
      expect(parties.find(party => party.id === "minority")?.desiredEndAt).toBe(at("18:30"));
    }
  });

  it("reserves a physical gate and legacy time even when the departure slot is absent from new choices", () => {
    const points = ["alias-a", "alias-b"].map(id => ({ id, linkedPortalId: "physical-portal", slots: [{ id: `${id}-old`, startsAt: at("17:15") }] }));
    const reservation = { id: "published", groupId: "fixed", startId: "alias-b-old", childCount: 4, expectedFinaleArrivalAt: at("20:00"), partyIds: ["household"] };
    expect(existingStartReservations([reservation], [], points)).toEqual([{ ...reservation, startPointId: "physical-portal", startsAt: at("17:15") }]);
    expect(reservation).not.toHaveProperty("startPointId");
  });

  it("includes group identity in fallback reservations so replacing one's own draft does not double-reserve", () => {
    const [reservation] = existingStartReservations(undefined, [{ id: "fixed", childCount: 2, registrations: [registration("one", null, null)], schedule: { id: "draft", state: "draft", startSlotId: "slot", expectedFinaleArrivalAt: at("20:00") } }], [{ id: "point", linkedPortalId: null, slots: [{ id: "slot", startsAt: at("17:00") }] }]);
    expect(reservation).toMatchObject({ groupId: "fixed", startPointId: "point", startsAt: at("17:00"), partyIds: ["one"] });
  });

  it("preserves the published reservation snapshot when live slot metadata differs", () => {
    const reservation = { id: "published", groupId: "fixed", startId: "slot", startPointId: "published-physical-gate", startsAt: at("17:00"), childCount: 4, expectedFinaleArrivalAt: at("20:00") };
    expect(existingStartReservations([reservation], [], [{ id: "live-point", linkedPortalId: "different-gate", slots: [{ id: "slot", startsAt: at("17:10") }] }])).toEqual([reservation]);
  });
});

describe("ten-minute departure window", () => {
  it("fills legacy fifteen-minute preference choices with actual ten-minute departures", () => {
    expect(planningStartTimes({ firstStartAt: at("17:00"), allowedStartTimes: [at("17:30"), at("17:00"), at("17:15")] })).toEqual(["17:00", "17:10", "17:20", "17:30"].map(at));
  });
  it("uses the fallback window, aligns the local clock and respects the ordinary stop boundary", () => {
    const slots = planningStartTimes({ firstStartAt: at("17:05"), globalOrdinaryStopAt: at("17:35") });
    expect(slots).toEqual(["17:10", "17:20", "17:30"].map(at));
    expect(planningStartTimes({ firstStartAt: at("17:00"), globalOrdinaryStopAt: at("17:30") })).toEqual(["17:00", "17:10", "17:20"].map(at));
    expect(planningStartTimes({ firstStartAt: at("18:00"), globalOrdinaryStopAt: at("17:00") })).toEqual([]);
    expect(planningStartTimes({})).toEqual([]);
  });
});
