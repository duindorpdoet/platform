/** Departure spacing is independent of how many groups can gather at a gate. */
export const DEPARTURE_INTERVAL_MINUTES = 10;

type StartWindow = {
  firstStartAt?: string | null;
  globalOrdinaryStopAt?: string | null;
  allowedStartTimes?: string[];
};

/** Legacy preference choices describe the window; they are not departure slots. */
export function planningStartTimes(settings: StartWindow): string[] {
  const configured = (settings.allowedStartTimes ?? []).map(Date.parse).filter(Number.isFinite).sort((a, b) => a - b);
  const first = settings.firstStartAt ? Date.parse(settings.firstStartAt) : configured[0];
  if (!Number.isFinite(first)) return [];
  const ordinaryStop = settings.globalOrdinaryStopAt ? Date.parse(settings.globalOrdinaryStopAt) : Number.POSITIVE_INFINITY;
  const last = Math.min(ordinaryStop - 1, configured.at(-1) ?? first + 150 * 60_000);
  if (!Number.isFinite(last) || last < first) return [];
  // Amsterdam's UTC offsets are whole hours, so this also aligns the local clock.
  const interval = DEPARTURE_INTERVAL_MINUTES * 60_000;
  const alignedFirst = Math.ceil(first / interval) * interval;
  return Array.from({ length: Math.max(0, Math.floor((last - alignedFirst) / interval) + 1) }, (_, index) => new Date(alignedFirst + index * interval).toISOString());
}
