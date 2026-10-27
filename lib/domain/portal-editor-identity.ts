type IdentityState = { lifecycleStatus: string; approvalStatus: string };

export function portalNumberIsEditable(portal: IdentityState) {
  return ["concept", "registered"].includes(portal.lifecycleStatus) && portal.approvalStatus !== "approved";
}

/** Approved identity comes from the portal record, never an older maintenance draft. */
export function portalEditorSystemNumber(portal: IdentityState & { systemCode: string }, saved?: { systemNumber?: string | number | null } | null) {
  if (portalNumberIsEditable(portal) && saved && Object.hasOwn(saved, "systemNumber")) return String(saved.systemNumber ?? "");
  return portal.systemCode.match(/\d+/)?.[0] ?? "";
}
