import type { JointRouteProposal } from "./joint-route-planner";

export type JointRouteAlternatives = { general: JointRouteProposal; organizerCoverage: JointRouteProposal | null;
  portalSpread?: JointRouteProposal;
  search?: { strategies: number; candidateEvaluations: number; maxCandidateEvaluations: number; finaleSchedulingOperations?: number; maxFinaleSchedulingOperations?: number } };
export type JointRouteProposalResponse = JointRouteProposal & { alternatives?: JointRouteAlternatives };

export type JointRoutePolicySettings = {
  policyVersion: string;
  version: number;
  maxTotalWalkingSeconds: number;
  maxEarlyFinishSeconds: number;
  organizerCoveragePortalIds: string[];
  sourceHash: string;
  portals: Array<{ id: string; code: string; name: string; active: boolean; finale: boolean }>;
};
