import { compareJointRouteProposals, JOINT_ROUTE_SEARCH_LIMITS, measureJointRoutes, proposeJointRoutes, validateJointRoutes,
  type JointRouteInput, type JointRouteGroupPlan, type JointRouteOptimizationMode } from "./joint-route-planner.ts";
import { JOINT_FINALE_MINIMAX_LIMITS } from "./joint-route-finale-minimax.ts";
import type { JointRouteAlternatives } from "./joint-route-policy";

/** The configured goals provide bounded search directions, never alternative hard policies. */
export const JOINT_ROUTE_COMPARISON_LIMITS = {
  strategies: 5,
  candidateEvaluations: 5 * JOINT_ROUTE_SEARCH_LIMITS.candidateEvaluations,
} as const;

export function proposeJointRouteAlternatives(input: JointRouteInput,
  propose: typeof proposeJointRoutes = proposeJointRoutes): JointRouteAlternatives {
  const goals = [...new Set(input.organizerCoveragePortalIds ?? [])];
  const candidates: ReturnType<typeof proposeJointRoutes>[] = [];
  const routeSeeds: JointRouteGroupPlan[][] = [];
  const run = (mode: JointRouteOptimizationMode, direction = goals, constructionWalkingLimitSeconds?: number) => {
    let construction: JointRouteGroupPlan[] | undefined;
    const candidate = propose({ ...input, organizerCoveragePortalIds: direction }, { mode,
      ...(constructionWalkingLimitSeconds != null ? { constructionWalkingLimitSeconds } : {}),
      seedPlans: routeSeeds,
      onFinaleSchedulingInput: plans => { construction = plans; } });
    candidates.push(candidate);
    if (candidate.valid) routeSeeds.push(construction ?? candidate.groups);
  };
  run("general");
  if (goals.length) run("organizer-coverage");
  // Explore independent lower-budget constructions while retaining stronger
  // valid warm routes. The source and reported hard policy remain canonical.
  if (input.maxTotalWalkingSeconds > 3900) run("portal-spread", goals, 3900);
  run("portal-spread");
  // Revisit the full-goal portfolio after the first shared balancing pass.
  // Equal organization goals remain present in every construction direction.
  if (goals.length > 1 && candidates.length < JOINT_ROUTE_COMPARISON_LIMITS.strategies) run("portal-spread");
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
      maxCandidateEvaluations: JOINT_ROUTE_COMPARISON_LIMITS.candidateEvaluations,
      finaleSchedulingOperations: candidates.reduce((sum, candidate) => sum + (candidate.finaleScheduling?.work.operations ?? 0), 0),
      maxFinaleSchedulingOperations: candidates.length * JOINT_FINALE_MINIMAX_LIMITS.maxWork },
  };
}
