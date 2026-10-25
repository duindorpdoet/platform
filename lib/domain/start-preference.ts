/** One vote per registration. Mode, then total absolute deviation, then earliest. */
export function dominantStartPreference(registrations: Array<{ id: string; preferredStartAt?: string | null }>): string | null {
  const votes = [...new Map(registrations.map(r => [r.id, r])).values()]
    .flatMap(r => r.preferredStartAt && Number.isFinite(Date.parse(r.preferredStartAt)) ? [Date.parse(r.preferredStartAt)] : []);
  const counts = new Map<number, number>();
  for (const vote of votes) counts.set(vote, (counts.get(vote) ?? 0) + 1);
  const selected = [...counts].sort((a, b) => b[1] - a[1]
    || votes.reduce((sum, v) => sum + Math.abs(v - a[0]), 0) - votes.reduce((sum, v) => sum + Math.abs(v - b[0]), 0)
    || a[0] - b[0])[0];
  return selected ? new Date(selected[0]).toISOString() : null;
}
