import type { JointRouteDiagnostic, JointRouteProposal } from "./joint-route-planner";

/** Diagnostics keep exact machine timestamps; the review presents Dutch local time. */
export function jointRouteReviewMessage(message: string) {
  return message.replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})/g, value => {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString("nl-NL", { timeZone: "Europe/Amsterdam", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
  });
}

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
