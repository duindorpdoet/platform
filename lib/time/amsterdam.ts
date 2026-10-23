const zone = "Europe/Amsterdam";
function parts(value: number | string) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  const values = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date).map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}`;
}
export function amsterdamDateTimeInput(value: string | null | undefined) { return value ? parts(value) ?? "" : ""; }
/** A wall time in Amsterdam, independent of the device zone. Gaps and ambiguous autumn times are rejected. */
export function amsterdamInputToIso(value: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) return null;
  const raw = Date.parse(value + ":00Z");
  if (!Number.isFinite(raw)) return null;
  const matches = [-120, -60, 0].map(minutes => raw + minutes * 60_000).filter(candidate => parts(candidate) === value);
  return matches.length === 1 ? new Date(matches[0]).toISOString() : null;
}
