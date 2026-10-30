import { compareJointRouteProposals, JOINT_ROUTE_SEARCH_LIMITS, measureJointRoutes, proposeJointRoutes, validateJointRoutes,
  type JointRouteInput, type JointRouteOptimizationMode } from "./joint-route-planner.ts";
import type { JointRouteAlternatives } from "./joint-route-policy";

/** The configured goals provide bounded search directions, never alternative hard policies. */
export const JOINT_ROUTE_COMPARISON_LIMITS = {
  strategies: 5,
  candidateEvaluations: 5 * JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations,
} as const;

export function proposeJointRouteAlternatives(input: JointRouteInput,
  propose: typeof proposeJointRoutes = proposeJointRoutes): JointRouteAlternatives {
  const goals = [...new Set(input.organizerCoveragePortalIds ?? [])];
  const strategies: Array<{ mode: JointRouteOptimizationMode; goals: string[] }> = [
    { mode: "general", goals },
    ...(goals.length ? [{ mode: "organizer-coverage" as const, goals }] : []),
    ...(goals.length > 1 ? [{ mode: "organizer-coverage" as const, goals: goals.slice(0, 1) },
      { mode: "organizer-coverage" as const, goals: goals.slice(-1) }] : []),
    // The first configured physical goal is one deterministic construction
    // direction. The final comparison always restores the full canonical set.
    { mode: "portal-spread", goals: goals.slice(0, 1) },
  ];
  const candidates = strategies.map(strategy => propose({ ...input, organizerCoveragePortalIds: strategy.goals }, { mode: strategy.mode }));
  const select = (mode: JointRouteOptimizationMode) => {
    const selected = candidates.reduce((best, candidate) =>
      compareJointRouteProposals(input, candidate, best, mode) > 0 ? candidate : best);
    // Recompute presentation under the one authoritative input. A directional
    // search must not leave a goal out of the final comparison or change policy.
    const before = measureJointRoutes(input, input.before), after = measureJointRoutes(input, selected.groups);
    after.administrativeStarts = before.administrativeStarts;
    const conflicts = [...new Map([...selected.conflicts, ...(input.diagnostics ?? []), ...validateJointRoutes(input, selected.groups),
      ...candidates[0].conflicts.filter(conflict => conflict.code === "ORGANIZER_TARGET_UNAVAILABLE")]
      .map(conflict => [`${conflict.code}|${conflict.groupId ?? ""}|${conflict.portalId ?? ""}`, conflict])).values()];
    return { ...selected, valid: !conflicts.some(conflict => conflict.severity === "block"), conflicts, metrics: { before, after },
      optimization: { ...selected.optimization, mode, organizerCoveragePortalIds: goals } };
  };
  return {
    general: select("general"),
    organizerCoverage: goals.length ? select("organizer-coverage") : null,
    portalSpread: select("portal-spread"),
    search: { strategies: candidates.length,
      candidateEvaluations: candidates.reduce((sum, candidate) => sum + candidate.work.candidateEvaluations, 0),
      maxCandidateEvaluations: JOINT_ROUTE_COMPARISON_LIMITS.candidateEvaluations },
  };
}
