import type { FrightnightDestination, FrightnightEvent } from "./model";

/** Use the edition's last confirmed server time, never the device clock. */
export function destinationRecoveryReason(event: FrightnightEvent, current: FrightnightDestination | null | undefined, state?: string) {
  if (!current) return null;
  if (state === "paused") return "Jullie tocht is gepauzeerd. Laat de server de bestemming opnieuw controleren voordat jullie verder lopen.";
  if (!["open", "busy"].includes(current.zone.status)) return "Deze bestemming is gesloten of gepauzeerd. Loop hier nog niet verder naartoe; vraag een actuele bestemming op.";
  const now = Date.parse(event.serverTime);
  if (now > Date.parse(current.leaseUntil)) return "Jullie reservering is verlopen. De server bewaart de oude plek tot gecontroleerd herstel en kiest dan een actuele bestemming.";
  if (current.zone.type !== "finale" && (now < Date.parse(current.zone.opensAt) || now > Date.parse(current.zone.closesAt))) return "Deze bestemming valt buiten haar openingstijd. Laat de server de route opnieuw beoordelen.";
  return null;
}
