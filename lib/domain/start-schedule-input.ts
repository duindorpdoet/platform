import type { ExistingPlanningSchedule, PlanningParty } from "./route-planner";

type Registration = {
  id: string;
  startPreference?: string;
  preferredStartAt: string | null;
  desiredEndAt: string | null;
  ordinaryStopAt: string | null;
  paymentEligible: boolean;
};
type ScheduledGroup = {
  id: string;
  childCount: number;
  registrations: Registration[];
  schedule: null | { id: string; state: string; startSlotId: string; expectedFinaleArrivalAt: string };
};
type Point = { id: string; linkedPortalId: string | null; physicalDepartureKey?: string; slots: Array<{ id: string; startsAt: string }> };

/** Retain the original households inside each fixed group, including neutral votes. */
export function fixedGroupPlanningParties(groups: ScheduledGroup[]): PlanningParty[] {
  return groups.flatMap(group => group.registrations.map((registration, index) => ({
    id: registration.id,
    fixedGroupId: group.id,
    childCount: index === 0 ? group.childCount : 0,
    startPreference: registration.startPreference === "early" || registration.startPreference === "later" ? registration.startPreference : "indifferent",
    preferredStartAt: registration.preferredStartAt,
    desiredEndAt: registration.desiredEndAt,
    requestedStopAt: registration.ordinaryStopAt,
    paymentEligible: registration.paymentEligible,
  })));
}

/** Hydrate all reservations, including slots absent from the new ten-minute grid. */
export function existingStartReservations(reservations: ExistingPlanningSchedule[] | undefined, groups: ScheduledGroup[], points: Point[]): ExistingPlanningSchedule[] {
  const slots = new Map(points.flatMap(point => point.slots.map(slot => [slot.id, { startPointId: point.physicalDepartureKey ?? point.linkedPortalId ?? point.id, startsAt: slot.startsAt }] as const)));
  const groupBySchedule = new Map(groups.flatMap(group => group.schedule ? [[group.schedule.id, group.id] as const] : []));
  const existing: ExistingPlanningSchedule[] = reservations ?? groups.flatMap(group => group.schedule && ["draft", "confirmed", "published"].includes(group.schedule.state) ? [{
    id: group.schedule.id, groupId: group.id, startId: group.schedule.startSlotId,
    childCount: group.childCount, expectedFinaleArrivalAt: group.schedule.expectedFinaleArrivalAt,
    partyIds: group.registrations.map(registration => registration.id),
  }] : []);
  return existing.map(reservation => ({
    ...reservation,
    groupId: reservation.groupId ?? groupBySchedule.get(reservation.id),
    startPointId: reservation.startPointId ?? slots.get(reservation.startId)?.startPointId,
    startsAt: reservation.startsAt ?? slots.get(reservation.startId)?.startsAt,
  }));
}
