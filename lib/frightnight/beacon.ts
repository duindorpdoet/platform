import { createHash } from "node:crypto";
export interface BeaconCommand { eventId: string; registrationId: string; commandId: string; mode: "rehearsal" | "finale"; }
export interface BeaconAcknowledgement { receipt: string; simulated: true; hardwareEnabled: false; state: "acknowledged" | "unavailable"; }
export interface BeaconAdapter { receive(command: BeaconCommand): Promise<BeaconAcknowledgement>; }
/** No network/hardware operation is possible in staging. The physical controller is local. */
export class StagingBeaconAdapter implements BeaconAdapter {
  constructor(private readonly fault = false) {}
  async receive(command: BeaconCommand): Promise<BeaconAcknowledgement> {
    const receipt = createHash("sha256").update(`${command.eventId}:${command.registrationId}:${command.commandId}:${command.mode}`).digest("hex").slice(0, 32);
    return { receipt, simulated: true, hardwareEnabled: false, state: this.fault ? "unavailable" : "acknowledged" };
  }
}
