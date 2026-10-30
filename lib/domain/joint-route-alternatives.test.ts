import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { JOINT_ROUTE_COMPARISON_LIMITS, proposeJointRouteAlternatives } from "./joint-route-alternatives";
import { jointRouteProposalDigestText, measureJointRoutes, proposeJointRoutes as buildJointRoutes, validateJointRoutes,
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
    maxGroupOverrunSeconds: 1800, maxLegWalkingSeconds: 900, maxTotalWalkingSeconds: 4500, needsAnders: false,
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
    walkingPolicy: { maxOrdinaryLegSeconds: 900, maxTotalSeconds: input.maxTotalWalkingSeconds, finaleLegLimitSeconds: null },
    completionPolicy: { maxEarlyFinishSeconds: null, maxOverrunSeconds: 1800 },
    optimization: { mode: "organizer-coverage", organizerCoveragePortalIds: input.organizerCoveragePortalIds ?? [] } };
}

describe("one shared comparison of physical route alternatives", () => {
  it("compares a stronger lower-budget construction across all variants without dropping either organization goal", () => {
    const input = fixture(), unchanged = structuredClone(input);
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => result(current,
      options?.constructionWalkingLimitSeconds === 3900 ? [["a", "b", "new"], ["a", "b"]]
        : [["a", "b"], ["a", "b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    for (const proposal of [choices.general, choices.organizerCoverage!, choices.portalSpread!]) {
      expect(proposal.metrics.after.totalOrdinaryVisits).toBe(5);
      expect(proposal.metrics.after.unvisitedPortals).toEqual([]);
      expect(proposal.metrics.after.organizerCoverage.map(item => item.portalId)).toEqual(["a", "b"]);
      expect(proposal.optimization.organizerCoveragePortalIds).toEqual(["a", "b"]);
      expect(proposal.proposalHash).toBe(createHash("sha256").update(jointRouteProposalDigestText(input.sourceHash, input.boardHash, proposal.groups)).digest("hex"));
    }
    expect(choices.general.optimization.mode).toBe("general");
    expect(choices.organizerCoverage!.optimization.mode).toBe("organizer-coverage");
    expect(choices.portalSpread!.optimization.mode).toBe("portal-spread");
    expect(engine).toHaveBeenCalledTimes(5);
    expect(engine.mock.calls.every(([current]) => current.organizerCoveragePortalIds?.join("|") === "a|b")).toBe(true);
    expect(choices.search).toEqual({ strategies: 5, candidateEvaluations: 55,
      maxCandidateEvaluations: JOINT_ROUTE_COMPARISON_LIMITS.candidateEvaluations, finaleSchedulingOperations: 0, maxFinaleSchedulingOperations: 200_000_000 });
    expect(engine.mock.calls.some(([, options]) => options?.constructionWalkingLimitSeconds === 3900)).toBe(true);
    expect(engine.mock.calls.slice(1).filter(([, options]) => options?.constructionWalkingLimitSeconds == null).every(([, options]) => options?.seedPlans?.length)).toBe(true);
    expect(input).toEqual(unchanged);
  });

  it("preserves equal organization goals before improving the remaining physical house spread", () => {
    const input = fixture();
    input.groups.push({ ...structuredClone(input.groups[0]), id: "three", code: "three", startNodeId: "start:three" });
    input.legs.push(...input.portals.map(portal => ({ from: "start:three", to: portal.nodeId, seconds: 60, meters: 60 })));
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => result(current,
      options?.mode === "portal-spread" ? [["a", "b"], ["a", "new"], ["b", "new"]]
        : [["a", "b", "new"], ["a", "b"], ["a", "b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(choices.general.metrics.after.totalOrdinaryVisits).toBe(7);
    expect(choices.organizerCoverage!.metrics.after.totalOrdinaryVisits).toBe(7);
    expect(choices.portalSpread!.metrics.after.totalOrdinaryVisits).toBe(7);
    expect(choices.portalSpread!.metrics.after.byPortal.map(portal => portal.visits)).toEqual([3, 3, 1]);
    expect(choices.portalSpread!.metrics.after.organizerCoverage.map(target => target.portalId)).toEqual(["a", "b"]);
    expect(engine.mock.calls.at(-1)?.[0].organizerCoveragePortalIds).toEqual(["a", "b"]);
    expect(validateJointRoutes(input, choices.portalSpread!.groups)).toEqual([]);
  });

  it("prefers real full physical coverage over more visits at old houses and ignores invented coverage metadata", () => {
    const input = fixture();
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => {
      const proposal = result(current, options?.constructionWalkingLimitSeconds === 3900
        ? [["a", "new"], ["b"]] : [["a", "b"], ["a", "b"]]);
      proposal.metrics.after.unvisitedPortals = [];
      return proposal;
    });
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(choices.general.metrics.after.totalOrdinaryVisits).toBe(3);
    expect(choices.general.metrics.after.unvisitedPortals).toEqual([]);
    expect(choices.organizerCoverage!.metrics.after.byPortal.find(portal => portal.portalId === "new")?.visits).toBe(1);
  });

  it("passes the validated construction calendar forward before global finale compaction", () => {
    const input = fixture(), observedSeeds: JointRouteGroupPlan[][][] = [];
    let construction: JointRouteGroupPlan[] = [];
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => {
      observedSeeds.push(structuredClone(options?.seedPlans ?? []));
      const proposal = result(current, [["a", "new"], ["b"]]);
      if (observedSeeds.length === 1) {
        construction = structuredClone(proposal.groups).map(plan => ({ ...plan,
          finaleArrivalAt: time(200), expectedCompletionAt: time(205),
          finaleChange: { portalId: "finale", previousReservedAt: time(180), proposedReservedAt: time(200) },
          visits: plan.visits.map(visit => visit.kind === "finale" ? { ...visit, startsAt: time(200) } : visit) }));
        expect(validateJointRoutes(current, construction)).toEqual([]);
        options?.onFinaleSchedulingInput?.(construction);
      }
      return proposal;
    });
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(observedSeeds.map(seeds => seeds.length)).toEqual([0, 1, 2, 3, 4]);
    expect(observedSeeds[1][0]).toEqual(construction);
    expect(observedSeeds[1][0][0].finaleArrivalAt).toBe(time(200));
    expect(engine.mock.results[0].value.groups[0].finaleArrivalAt).toBe(time(180));
    expect(validateJointRoutes(input, choices.portalSpread!.groups)).toEqual([]);
  });

  it("revalidates warm route contents instead of trusting a valid proposal flag or callback", () => {
    const input = fixture(), observedSeedConflicts: string[][] = [];
    let calls = 0;
    const engine = vi.fn<typeof proposeJointRoutes>((current, options) => {
      if (calls++ === 0) {
        const proposal = result(current, [["a", "new"], ["b"]]);
        const invalid = structuredClone(proposal.groups);
        invalid[0].visits[0].startsAt = time(-1);
        options?.onFinaleSchedulingInput?.(invalid);
        return proposal;
      }
      observedSeedConflicts.push((options?.seedPlans ?? []).flatMap(seed => validateJointRoutes(current, seed).map(conflict => conflict.code)));
      const proposal = buildJointRoutes(current, options);
      expect(proposal.valid).toBe(true);
      expect(validateJointRoutes(current, proposal.groups)).toEqual([]);
      expect(proposal.groups.flatMap(plan => plan.visits).every(visit => visit.startsAt !== time(-1))).toBe(true);
      return proposal;
    });
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(observedSeedConflicts).toHaveLength(4);
    expect(observedSeedConflicts.every(conflicts => conflicts.includes("OPENING_WINDOW") && conflicts.includes("TRAVEL_TIME"))).toBe(true);
    for (const proposal of [choices.general, choices.organizerCoverage!, choices.portalSpread!]) {
      expect(proposal.valid).toBe(true);
      expect(validateJointRoutes(input, proposal.groups)).toEqual([]);
    }
  });

  it.each([{ goals: [] }, { goals: ["a"] }])("bounds and deduplicates the searches with goals $goals", ({ goals }) => {
    const input = fixture(); input.organizerCoveragePortalIds = goals;
    const engine = vi.fn<typeof proposeJointRoutes>(current => result(current, [["a", "new"], ["b"]]));
    const choices = proposeJointRouteAlternatives(input, engine);
    expect(engine).toHaveBeenCalledTimes(goals.length ? 4 : 3);
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
