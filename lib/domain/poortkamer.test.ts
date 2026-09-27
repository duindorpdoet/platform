import { describe, expect, it } from "vitest";
import {
  canEditPortal,
  canManageTeam,
  roomMetrics,
  type PortalRoom,
} from "./poortkamer";
describe("Poortkamer presentation contracts", () => {
  it("shows preparation without mistaking it for attendance or visits", () => {
    const room = {
      checklist: [
        { item: "phone", done: true },
        { item: "unknown", done: true },
      ],
      visits: {
        arrivals: [
          {
            groupCode: "G-01",
            expectedChildren: 4,
            plannedArrivalAt: "2026-10-31T18:15:00Z",
          },
          {
            groupCode: "G-02",
            expectedChildren: 7,
            plannedArrivalAt: "2026-10-31T19:00:00Z",
          },
        ],
      },
    } as PortalRoom;
    const metrics = roomMetrics(room, Date.parse("2026-10-31T18:00:00Z"));
    expect(metrics).toMatchObject({
      ready: 1,
      remainingChildren: 11,
      remainingGroups: 2,
      nextHalfHour: 1,
      next: { groupCode: "G-01" },
    });
  });
  it("distinguishes editing from team administration", () => {
    expect(canEditPortal("coadmin")).toBe(true);
    expect(canManageTeam("coadmin")).toBe(false);
    expect(canEditPortal("crew")).toBe(false);
    expect(canEditPortal("viewer")).toBe(false);
    expect(canManageTeam("owner")).toBe(true);
    expect(canManageTeam("admin")).toBe(true);
  });
});
