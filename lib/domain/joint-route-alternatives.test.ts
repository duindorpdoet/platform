import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { JOINT_ROUTE_COMPARISON_LIMITS, proposeJointRouteAlternatives } from "./joint-route-alternatives";
import { jointRouteProposalDigestText, measureJointRoutes, validateJointRoutes,
  type JointRouteGroupPlan, type JointRouteInput, type JointRouteProposal, type proposeJointRoutes } from "./joint-route-planner";

const time = (minutes: number) => new Date(Date.UTC(2026, 9, 31, 17, minutes)).toISOString();
function fixture(): JointRouteInput {
  const window = { opensAt: time(0), arrivalClosesAt: time(300), closesAt: time(300), visitSeconds: 300,
    bufferSeconds: 0, maxGroups: 10, maxChildren: 30, maxTotalChildren: 1000, headwaySeconds: 0 };
  const portals = ["a", "b", "new", "finale"].map(id => ({ id, code: id === "finale" ? "P-38" : id,
    name: id, nodeId: `portal:${id}`, worldSlug: "any-label", finale: id === "finale",
    accessibilityStatus: "step_free" as const, windows: [{ ...window }] }));
  const groups = ["one", "two"].map(id => ({ id, code: id, childCount: 4, startNodeId: `start:${id}`,
    startsAt: time(0), startConfirmed: true, ordinaryStopAt: time(240), desiredEndAt: null, maxOrdinaryVisits: null,
    requiresStepFree: false, accessibilityNeedsReview: false, fixedFirstPortalId: null, excludedPortalIds: [],
    finale: { portalId: "finale", reservedAt: time(180), reservationValid: true, latestArrivalAt: time(290) } }));
  return { eventId: "synthetic", sourceHash: "a".repeat(64), boardHash: "b".repeat(32), policyVersion: "synthetic",
    maxGroupOverrunSeconds: 1800, maxLegWalkingSeconds: 900, maxTotalWalkingSeconds: 3900, needsAnders: false,
    organizerCoveragePortalIds: ["a", "b"], groups, portals, before: [], fixedVisits: [],
    legs: [...groups.map(group => group.startNodeId), ...portals.map(portal => portal.nodeId)].flatMap(from =>
      portals.map(portal => ({ from, to: portal.nodeId, seconds: 60, meters: 60 }))) };
}
function result(input: JointRouteInput, orders: string[][]): JointRouteProposal {
  const groups: JointRouteGroupPlan[] = orders.map((order, index) => ({ groupId: input.groups[index].id,
    startsAt: time(0), finaleArrivalAt: time(180), expectedCompletionAt: time(185), diagnostics: [],
    visits: [...order.map((portalId, sequence) => ({ portalId, kind: "ordinary" as const, sequence: sequence + 1,
      startsAt: time(1 + sequence * 6), visitSeconds: 300, bufferSeconds: 0, walkSeconds: 60, walkMeters: 60 })),
    { portalId: "finale", kind: "finale" as const, sequence: order.length + 1, startsAt: time(180), visitSeconds: 300,
      bufferSeconds: 0, walkSeconds: 60, walkMeters: 60 }] }));
  expect(validateJointRoutes(input, groups)).toEqual([]);
  return { sourceHash: input.sourceHash, boardHash: input.boardHash, policyVersion: input.policyVersion,
    proposalHash: createHash("sha256").update(jointRouteProposalDigestText(input.sourceHash, input.boardHash, groups)).digest("hex"),
    valid: true, groups, conflicts: [], metrics: { before: measureJointRoutes(input, []), after: measureJointRoutes(input, groups) },
    work: { candidateEvaluations: 11, variants: 1, pairReplans: 0, routeRepairs: 0, jointFinaleReplans: 0, exhausted: false },
    walkingPolicy: { maxOrdinaryLegSeconds: 900, maxTotalSeconds: 3900, finaleLegLimitSeconds: null },
    completionPolicy: { maxEarlyFinishSeconds: null, maxOverrunSeconds: 1800 },
    optimization: { mode: "organizer-coverage", organizerCoveragePortalIds: input.organizerCoveragePortalIds ?? [] } };
}

describe("one shared comparison of physical route alternatives", () => {
  it("includes a better single-goal search in both displayed variants and restores canonical goal metrics", () => {
    const input = fixture(), unchanged = structuredClone(input);
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => result(current,
      options?.mode === "organizer-coverage" && current.organizerCoveragePortalIds?.length === 1
        && current.organizerCoveragePortalIds[0] === "b" ? [["a", "b", "new"], ["a", "b"]]
        : [["a", "b"], ["a", "b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    for (const proposal of [choices.general, choices.organizerCoverage!]) {
      expect(proposal.metrics.after.totalOrdinaryVisits).toBe(5);
      expect(proposal.metrics.after.unvisitedPortals).toEqual([]);
      expect(proposal.metrics.after.organizerCoverage.map(item => item.portalId)).toEqual(["a", "b"]);
      expect(proposal.optimization.organizerCoveragePortalIds).toEqual(["a", "b"]);
      expect(proposal.proposalHash).toBe(createHash("sha256").update(jointRouteProposalDigestText(input.sourceHash, input.boardHash, proposal.groups)).digest("hex"));
    }
    expect(choices.general.optimization.mode).toBe("general");
    expect(choices.organizerCoverage!.optimization.mode).toBe("organizer-coverage");
    expect(engine).toHaveBeenCalledTimes(4);
    expect(choices.search).toEqual({ strategies: 4, candidateEvaluations: 44,
      maxCandidateEvaluations: JOINT_ROUTE_COMPARISON_LIMITS.candidateEvaluations });
    expect(input).toEqual(unchanged);
  });

  it("prefers real full physical coverage over more visits at old houses and ignores invented coverage metadata", () => {
    const input = fixture();
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => {
      const proposal = result(current, options?.mode === "organizer-coverage" && current.organizerCoveragePortalIds?.length === 1
        ? [["a", "new"], ["b"]] : [["a", "b"], ["a", "b"]]);
      proposal.metrics.after.unvisitedPortals = [];
      return proposal;
    });
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(choices.general.metrics.after.totalOrdinaryVisits).toBe(3);
    expect(choices.general.metrics.after.unvisitedPortals).toEqual([]);
    expect(choices.organizerCoverage!.metrics.after.byPortal.find(portal => portal.portalId === "new")?.visits).toBe(1);
  });

  it.each([{ goals: [] }, { goals: ["a"] }])("bounds and deduplicates the searches with goals $goals", ({ goals }) => {
    const input = fixture(); input.organizerCoveragePortalIds = goals;
    const engine = vi.fn<typeof proposeJointRoutes>(current => result(current, [["a", "new"], ["b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(engine).toHaveBeenCalledTimes(goals.length ? 2 : 1);
    expect(choices.search!.strategies).toBeLessThanOrEqual(JOINT_ROUTE_COMPARISON_LIMITS.strategies);
    expect(choices.search!.candidateEvaluations).toBeLessThanOrEqual(JOINT_ROUTE_COMPARISON_LIMITS.candidateEvaluations);
    expect(choices.organizerCoverage === null).toBe(goals.length === 0);
  });

  it("retains invalid authoritative policy conflicts even when a directional search can produce routes", () => {
    const input = fixture();
    input.policyVersion = "joint-reception-v3"; input.maxEarlyFinishSeconds = 1800; input.routePolicySettingsVersion = 1;
    input.organizerCoveragePortalIds = ["a", "a"];
    const engine = vi.fn<typeof proposeJointRoutes>(current => result(current, [["a", "new"], ["b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(choices.general.valid).toBe(false);
    expect(choices.general.conflicts.some(conflict => conflict.code === "INVALID_ROUTE_POLICY_CONFIG" && conflict.severity === "block")).toBe(true);
  });
});
