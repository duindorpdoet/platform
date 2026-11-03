import { describe, it, expect } from "vitest";
import { StagingBeaconAdapter } from "./beacon";
describe("onafhankelijk lokaal Lichtbaken", () => {
  it("maakt stabiele ontvangstbewijzen zonder internet of hardwareuitvoer", async () => {
    const command = { eventId: "test-event", registrationId: "synthetic-family", commandId: "same-command", mode: "finale" as const };
    const adapter = new StagingBeaconAdapter();
    expect(await adapter.receive(command)).toEqual(await adapter.receive(command));
    expect((await adapter.receive(command)).hardwareEnabled).toBe(false);
    expect((await new StagingBeaconAdapter(true).receive(command)).state).toBe("unavailable");
  });
});
