import type { JointRouteDiagnostic, JointRouteProposal } from "./joint-route-planner";

/** Group diagnostics are also included in conflicts; show each finding once. */
export function jointRouteReviewDiagnostics(proposal: Pick<JointRouteProposal, "groups" | "conflicts">) {
  const findings = [
    ...proposal.conflicts,
    ...proposal.groups.flatMap(group => group.diagnostics.map(diagnostic => ({ ...diagnostic, groupId: diagnostic.groupId ?? group.groupId }))),
  ];
  const unique = new Map<string, JointRouteDiagnostic>();
  for (const finding of findings) {
    const key = JSON.stringify([finding.code, finding.groupId ?? null, finding.portalId ?? null]);
    const existing = unique.get(key);
    if (!existing || existing.severity !== "block" && finding.severity === "block") unique.set(key, finding);
  }
  const diagnostics = [...unique.values()];
  return {
    blocks: diagnostics.filter(diagnostic => diagnostic.severity === "block"),
    advice: diagnostics.filter(diagnostic => diagnostic.severity === "warning"),
  };
}
