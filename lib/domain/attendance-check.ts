export type AttendanceDecision = "present" | "absent";

export function reconcileAttendance(childIds: string[], current: Record<string, AttendanceDecision>) {
  return Object.fromEntries(childIds.filter((id) => current[id]).map((id) => [id, current[id]])) as Record<string, AttendanceDecision>;
}

export function attendanceSummary(childIds: string[], decisions: Record<string, AttendanceDecision>) {
  const checked = childIds.filter((id) => decisions[id]).length;
  const presentIds = childIds.filter((id) => decisions[id] === "present");
  return {
    checked,
    total: childIds.length,
    presentIds,
    absent: checked - presentIds.length,
    complete: childIds.length > 0 && checked === childIds.length,
    canStart: childIds.length > 0 && checked === childIds.length && presentIds.length > 0,
  };
}
