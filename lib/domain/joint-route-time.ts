import type { JointRouteGroup, JointRouteInput } from "./joint-route-planner";

/** Preserve the microseconds used by PostgreSQL appointments. */
export const jointTime = (value: string) => {
  const fraction = /\.(\d+)(?:Z|[+-]\d{2}(?::?\d{2})?)$/i.exec(value)?.[1] ?? "";
  const micros = Date.parse(value) * 1000 + Number(fraction.slice(3, 6).padEnd(3, "0"));
  return Number.isSafeInteger(micros) ? micros / 1_000_000 : NaN;
};

export const jointIso = (value: number) => {
  const micros = Math.round(value * 1_000_000), millis = Math.floor(micros / 1000);
  const remainder = micros - millis * 1000, formatted = new Date(millis).toISOString();
  return remainder ? `${formatted.slice(0, -1)}${String(remainder).padStart(3, "0")}Z` : formatted;
};

export function jointCompletionBounds(input: JointRouteInput, group: JointRouteGroup) {
  const earliest = group.desiredEndAt && input.maxEarlyFinishSeconds != null
    ? Math.max(jointTime(group.desiredEndAt) - input.maxEarlyFinishSeconds,
      group.earliestCompletionAt ? jointTime(group.earliestCompletionAt) : -Infinity) : -Infinity;
  const latest = Math.min(group.desiredEndAt ? jointTime(group.desiredEndAt) + input.maxGroupOverrunSeconds : Infinity,
    group.latestCompletionAt ? jointTime(group.latestCompletionAt) : Infinity);
  return { earliest, latest };
}
