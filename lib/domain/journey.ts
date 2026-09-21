export type ParticipantDecision = "pending" | "visited" | "skipped";
export type StopOutcome = "visited" | "mixed" | "all_skipped";

export type CompletionDecision =
  | { allowed: true; outcome: StopOutcome }
  | { allowed: false; code: "EMPTY_GROUP" | "PENDING_PARTICIPANTS" | "SCAN_REQUIRED" | "ALL_SKIP_CONFIRMATION_REQUIRED" };

export function evaluateStopCompletion(
  statuses: Array<{ status: ParticipantDecision; required: boolean }>,
  scanAccepted: boolean,
  allSkipConfirmed: boolean,
): CompletionDecision {
  const required = statuses.filter((item) => item.required);
  if (required.length === 0) return { allowed: false, code: "EMPTY_GROUP" };
  if (required.some((item) => item.status === "pending")) return { allowed: false, code: "PENDING_PARTICIPANTS" };

  const visited = required.filter((item) => item.status === "visited").length;
  const skipped = required.filter((item) => item.status === "skipped").length;
  if (visited > 0 && !scanAccepted) return { allowed: false, code: "SCAN_REQUIRED" };
  if (visited === 0 && !allSkipConfirmed) return { allowed: false, code: "ALL_SKIP_CONFIRMATION_REQUIRED" };
  if (visited > 0 && skipped > 0) return { allowed: true, outcome: "mixed" };
  return { allowed: true, outcome: visited > 0 ? "visited" : "all_skipped" };
}

export function canChangeParticipant(
  role: "leader" | "parent" | "support",
  ownsChild: boolean,
  from: ParticipantDecision,
  to: ParticipantDecision,
) {
  if (from === to) return false;
  if (role === "leader" || role === "support") return from === "pending" && (to === "visited" || to === "skipped");
  return ownsChild && ((from === "pending" && to === "skipped") || (from === "skipped" && to === "pending"));
}
