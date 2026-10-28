export type RegistrationTimePreferences = {
  id: string;
  preferredStartAt?: string | null;
  desiredEndAt?: string | null;
};

/**
 * One vote per original registration, including registrations inside together blocks.
 * Missing/invalid preferences are neutral. Duplicate snapshots cannot add votes;
 * conflicting values for one registration are neutral rather than order dependent.
 * Select the mode, then the smallest total absolute deviation, then the earliest.
 */
export function dominantTimePreference(
  registrations: RegistrationTimePreferences[],
  field: "preferredStartAt" | "desiredEndAt",
): string | null {
  const byRegistration = new Map<string, Set<number>>();
  for (const registration of registrations) {
    const value = registration[field];
    const parsed = value ? Date.parse(value) : Number.NaN;
    if (!Number.isFinite(parsed)) continue;
    const values = byRegistration.get(registration.id) ?? new Set<number>();
    values.add(parsed);
    byRegistration.set(registration.id, values);
  }
  const votes = [...byRegistration.values()].flatMap(values => values.size === 1 ? [...values] : []);
  const counts = new Map<number, number>();
  for (const vote of votes) counts.set(vote, (counts.get(vote) ?? 0) + 1);
  const selected = [...counts].sort((a, b) => b[1] - a[1]
    || votes.reduce((sum, value) => sum + Math.abs(value - a[0]), 0) - votes.reduce((sum, value) => sum + Math.abs(value - b[0]), 0)
    || a[0] - b[0])[0];
  return selected ? new Date(selected[0]).toISOString() : null;
}

export const dominantStartPreference = (registrations: RegistrationTimePreferences[]) => dominantTimePreference(registrations, "preferredStartAt");
export const dominantEndPreference = (registrations: RegistrationTimePreferences[]) => dominantTimePreference(registrations, "desiredEndAt");

/** Legacy exact-end writes copied the end wish into the ordinary-stop column. */
export function explicitOrdinaryStopPreference(preference: { requestedStopAt?: string | null; desiredEndAt?: string | null }): string | null {
  const stop = preference.requestedStopAt ? Date.parse(preference.requestedStopAt) : Number.NaN;
  const end = preference.desiredEndAt ? Date.parse(preference.desiredEndAt) : Number.NaN;
  return Number.isFinite(stop) && stop !== end ? preference.requestedStopAt! : null;
}
