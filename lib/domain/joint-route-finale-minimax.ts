import { jointCompletionBounds, jointIso, jointTime } from "./joint-route-time.ts";
import type { JointRouteGroupPlan, JointRouteInput, JointRouteWindow } from "./joint-route-planner";

export const JOINT_FINALE_MINIMAX_LIMITS = {
  maxGroups: 20, maxFixedFinales: 128, maxWork: 40_000_000,
} as const;

export type JointFinaleMinimaxResult = {
  arrivals: Array<{ groupId: string; startsAt: string }>;
  changed: boolean;
  optimal: boolean;
  reason: string;
  waitingMetricsAvailable: boolean;
  ordinaryWaitingFloorSeconds: number;
  maxFinaleWaitingSecondsBefore: number;
  maxFinaleWaitingSecondsAfter: number;
  maxWaitingSecondsBefore: number;
  maxWaitingSecondsAfter: number;
  work: { operations: number; states: number; transitions: number; feasibilityChecks: number; exhausted: boolean };
};

const micros = (value: string) => Math.round(jointTime(value) * 1_000_000);
const valid = (value: number) => Number.isSafeInteger(value);

/**
 * Exact subset dominance applies here only when uniform arrival spacing also
 * guarantees physical capacity. For a subset, its earliest possible last
 * arrival then dominates every later one, including around fixed reservations.
 * This helper changes no visits. Its caller applies the returned finale times
 * and validates the complete routes under the canonical current input.
 */
export function optimizeJointFinaleMinimax(input: JointRouteInput, plans: JointRouteGroupPlan[], options: { maxWork?: number } = {}): JointFinaleMinimaxResult {
  const work = { operations: 0, states: 0, transitions: 0, feasibilityChecks: 0, exhausted: false };
  const maximum = options.maxWork === undefined ? JOINT_FINALE_MINIMAX_LIMITS.maxWork
    : Number.isSafeInteger(options.maxWork) && options.maxWork >= 0 ? Math.min(options.maxWork, JOINT_FINALE_MINIMAX_LIMITS.maxWork) : 0;
  const spend = () => {
    if (work.operations >= maximum) { work.exhausted = true; return false; }
    work.operations++; return true;
  };
  const original = plans.flatMap(plan => {
    const finale = plan.visits.find(visit => visit.kind === "finale");
    return finale ? [{ groupId: plan.groupId, startsAt: finale.startsAt }] : [];
  }).sort((a, b) => a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0);
  let ordinaryFloor = 0, before = 0, measured = false;
  const result = (reason: string, optimal = false, arrivals = original, after = before): JointFinaleMinimaxResult => ({
    arrivals, changed: arrivals.some((arrival, index) => micros(arrival.startsAt) !== micros(original[index]?.startsAt ?? "")),
    optimal, reason, waitingMetricsAvailable: measured, ordinaryWaitingFloorSeconds: ordinaryFloor / 1_000_000,
    maxFinaleWaitingSecondsBefore: before / 1_000_000, maxFinaleWaitingSecondsAfter: after / 1_000_000,
    maxWaitingSecondsBefore: Math.max(ordinaryFloor, before) / 1_000_000,
    maxWaitingSecondsAfter: Math.max(ordinaryFloor, after) / 1_000_000, work,
  });
  if (!plans.length) return result("no-groups", true);
  if (plans.length > JOINT_FINALE_MINIMAX_LIMITS.maxGroups || plans.length !== input.groups.length)
    return result("unsupported-group-count");
  const portals = new Map(input.portals.map(portal => [portal.id, portal]));
  const physical = (id: string) => portals.get(id)?.physicalId ?? id;
  const groups = new Map(input.groups.map(group => [group.id, group]));
  const seenGroups = new Set<string>();
  const legs = new Map<string, { seconds: number; meters: number }>();
  for (const leg of input.legs) {
    if (!spend()) return result("work-limit");
    legs.set(`${leg.from}|${leg.to}`, leg);
  }
  let shared: JointRouteWindow | null = null, sharedPhysical: string | null = null;
  const jobs: Array<{ id: string; release: number; reachable: number; deadline: number; previous: number; children: number }> = [];
  for (const plan of [...plans].sort((a, b) => a.groupId < b.groupId ? -1 : 1)) {
    if (!spend()) return result("work-limit");
    const group = groups.get(plan.groupId), last = plan.visits.at(-1);
    if (!group || seenGroups.has(group.id) || !last || last.kind !== "finale" || last.portalId !== group.finale.portalId
      || plan.visits.filter(visit => visit.kind === "finale").length !== 1) return result("unsupported-plan-shape");
    seenGroups.add(group.id);
    const portal = portals.get(last.portalId);
    if (!portal?.finale || portal.windows.length !== 1) return result("unsupported-finale-windows");
    const p38 = input.portals.find(item => /^P-?38$/i.test(item.code));
    if (p38 && physical(portal.id) !== physical(p38.id)) return result("unsupported-finale-location");
    const window = portal.windows[0];
    if (shared && (physical(portal.id) !== sharedPhysical || JSON.stringify(window) !== JSON.stringify(shared)))
      return result("unsupported-finale-windows");
    shared = window; sharedPhysical = physical(portal.id);
    if (last.visitSeconds !== window.visitSeconds || last.bufferSeconds !== window.bufferSeconds) return result("unsupported-service-duration");
    let cursor = micros(group.startsAt), node = group.startNodeId, walking = 0;
    for (const visit of plan.visits.filter(visit => visit.kind === "ordinary")) {
      if (!spend()) return result("work-limit");
      const next = portals.get(visit.portalId), leg = next && legs.get(`${node}|${next.nodeId}`), start = micros(visit.startsAt);
      if (!leg || !valid(start) || !Number.isFinite(leg.seconds) || leg.seconds < 0) return result("unsupported-walk-data");
      ordinaryFloor = Math.max(ordinaryFloor, start - cursor - Math.round(leg.seconds * 1_000_000));
      walking += leg.seconds; cursor = start + visit.visitSeconds * 1_000_000; node = next!.nodeId;
    }
    const exit = legs.get(`${node}|${portal.nodeId}`);
    if (!exit || !Number.isFinite(exit.seconds) || exit.seconds < 0 || exit.seconds !== last.walkSeconds
      || walking + exit.seconds > input.maxTotalWalkingSeconds) return result("unsupported-walk-data");
    const reachable = cursor + Math.round(exit.seconds * 1_000_000), bounds = jointCompletionBounds(input, group);
    const release = Math.max(reachable, micros(group.startsAt), micros(window.opensAt), Math.round((bounds.earliest - window.visitSeconds) * 1_000_000));
    const deadline = Math.min(micros(group.finale.latestArrivalAt), micros(window.arrivalClosesAt),
      micros(window.closesAt) - (window.visitSeconds + window.bufferSeconds) * 1_000_000,
      Math.round((bounds.latest - window.visitSeconds) * 1_000_000));
    const previous = micros(last.startsAt);
    if (![reachable, release, deadline, previous].every(valid) || !Number.isSafeInteger(group.childCount) || group.childCount < 1)
      return result("unsupported-time-or-child-data");
    jobs.push({ id: group.id, release, reachable, deadline, previous, children: group.childCount });
    before = Math.max(before, previous - reachable);
  }
  measured = true;
  const window = shared!;
  const service = (window.visitSeconds + window.bufferSeconds) * 1_000_000, headway = window.headwaySeconds * 1_000_000;
  if (![service, headway, window.maxGroups, window.maxChildren, window.maxTotalChildren].every(valid)
    || !Number.isSafeInteger(window.visitSeconds) || window.visitSeconds < 60 || !Number.isSafeInteger(window.bufferSeconds) || window.bufferSeconds < 0
    || headway < 0 || window.maxGroups < 1 || jobs.some(job => job.children > window.maxChildren)
    || window.maxConcurrentChildren != null && (!Number.isSafeInteger(window.maxConcurrentChildren) || window.maxConcurrentChildren < 0)) return result("unsupported-capacity");
  const spacing = window.maxGroups === 1 ? Math.max(service, headway) : headway;
  if (!spacing || service > window.maxGroups * spacing) return result("unsupported-capacity-dominance");
  const fixed: Array<{ groupId: string; start: number; children: number }> = [];
  for (const visit of input.fixedVisits) {
    if (!spend()) return result("work-limit");
    if (visit.kind === "start" || (visit.physicalId ?? physical(visit.portalId)) !== sharedPhysical) continue;
    if (seenGroups.has(visit.groupId)) return result("protected-finale-group");
    const start = micros(visit.startsAt);
    if (!valid(start) || (visit.visitSeconds + visit.bufferSeconds) * 1_000_000 !== service
      || !Number.isSafeInteger(visit.children) || visit.children < 0) return result("unsupported-fixed-service");
    if (fixed.some(other => other.groupId === visit.groupId && other.start !== start)) return result("unsupported-fixed-group-repeat");
    const previous = fixed.find(other => other.groupId === visit.groupId && other.start === start);
    if (previous) previous.children = Math.max(previous.children, visit.children);
    else fixed.push({ groupId: visit.groupId, start, children: visit.children });
    if (fixed.length > JOINT_FINALE_MINIMAX_LIMITS.maxFixedFinales) return result("unsupported-fixed-count");
  }
  fixed.sort((a, b) => a.start - b.start || (a.groupId < b.groupId ? -1 : 1));
  for (let a = 0; a < fixed.length; a++) for (let b = a + 1; b < fixed.length; b++) {
    if (!spend()) return result("work-limit");
    if (fixed[a].groupId !== fixed[b].groupId && fixed[b].start - fixed[a].start < spacing) return result("unsupported-fixed-capacity");
  }
  const children = new Map<string, number>();
  for (const item of [...fixed, ...jobs.map(job => ({ groupId: job.id, children: job.children }))])
    children.set(item.groupId, Math.max(children.get(item.groupId) ?? 0, item.children));
  const counts = [...children.values()].sort((a, b) => b - a), simultaneous = Math.ceil(service / spacing);
  if (counts.reduce((sum, count) => sum + count, 0) > window.maxTotalChildren) return result("infeasible-total-children", true);
  if (window.maxConcurrentChildren != null && counts.slice(0, simultaneous).reduce((sum, count) => sum + count, 0) > window.maxConcurrentChildren)
    return result("unsupported-concurrent-children");
  const forbidden: Array<{ low: number; high: number }> = [];
  for (const visit of fixed) {
    const next = { low: visit.start - spacing, high: visit.start + spacing }, previous = forbidden.at(-1);
    // The endpoints are allowed. Do not merge intervals merely touching there.
    if (previous && next.low < previous.high) previous.high = Math.max(previous.high, next.high);
    else forbidden.push(next);
  }
  const nextFree = (time: number) => {
    let low = 0, high = forbidden.length;
    while (low < high) {
      if (!spend()) return NaN;
      const middle = (low + high) >>> 1;
      if (forbidden[middle].low < time) low = middle + 1; else high = middle;
    }
    const interval = forbidden[low - 1];
    return interval && time < interval.high ? interval.high : time;
  };
  const oldOrder = [...jobs].sort((a, b) => a.previous - b.previous);
  let originalValid = jobs.every(job => job.release <= job.previous && job.previous <= job.deadline);
  for (let index = 0; index < oldOrder.length; index++) {
    const job = oldOrder[index];
    if (nextFree(job.previous) !== job.previous || index && job.previous - oldOrder[index - 1].previous < spacing) originalValid = false;
  }
  if (work.exhausted) return result("work-limit");
  const upper = originalValid ? before : Math.max(...jobs.map(job => job.deadline - job.reachable));
  if (upper < 0 || jobs.some(job => job.release > job.deadline)) return result("infeasible-final-times", true);
  const waits = new Set<number>([0, upper]);
  // Every earliest DP arrival is release_i+k*spacing or the end of a fixed
  // exclusion interval+k*spacing. These are all possible optimum wait values.
  for (const anchor of [...jobs.map(job => job.release), ...fixed.map(visit => visit.start + spacing)])
    for (let count = 0; count < jobs.length; count++) for (const job of jobs) {
      if (!spend()) return result("work-limit");
      const wait = anchor + count * spacing - job.reachable;
      if (wait >= 0 && wait <= upper) waits.add(wait);
    }
  const candidates = [...waits].sort((a, b) => a - b), size = 1 << jobs.length, full = size - 1;
  const feasible = (limit: number): number[] | null => {
    work.feasibilityChecks++;
    const times = new Float64Array(size); times.fill(Infinity); times[0] = -Infinity;
    const choice = new Int8Array(size); choice.fill(-1);
    for (let mask = 0; mask < size; mask++) {
      if (!spend()) return null; work.states++;
      if (times[mask] === Infinity) continue;
      let remaining = full ^ mask;
      while (remaining) {
        if (!spend()) return null; work.transitions++;
        const bit = remaining & -remaining, index = 31 - Math.clz32(bit); remaining ^= bit;
        const job = jobs[index], arrival = nextFree(Math.max(job.release, times[mask] + spacing));
        if (work.exhausted) return null;
        if (arrival > job.deadline || arrival - job.reachable > limit) continue;
        const next = mask | bit;
        if (arrival >= times[next]) continue;
        times[next] = arrival; choice[next] = index;
        if (next === full) {
          const arrivals = new Array<number>(jobs.length);
          for (let cursor = full; cursor; cursor ^= 1 << choice[cursor]) arrivals[choice[cursor]] = times[cursor];
          return arrivals;
        }
      }
    }
    return null;
  };
  let best: number[] | null = originalValid ? jobs.map(job => job.previous) : feasible(upper);
  if (!best) return result(work.exhausted ? "work-limit" : "infeasible-final-times", !work.exhausted);
  let low = -1, high = candidates.length - 1;
  while (high - low > 1) {
    const middle = (low + high) >>> 1, next = feasible(candidates[middle]);
    if (work.exhausted) break;
    if (next) { best = next; high = middle; } else low = middle;
  }
  const after = Math.max(0, ...best.map((arrival, index) => arrival - jobs[index].reachable));
  const arrivals = jobs.map((job, index) => ({ groupId: job.id,
    startsAt: best![index] === job.previous ? original[index].startsAt : jointIso(best![index] / 1_000_000) }));
  return result(work.exhausted ? "work-limit" : "optimized", !work.exhausted, arrivals, after);
}
