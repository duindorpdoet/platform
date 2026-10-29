type AccessRole = { key: string; groupId?: string | null; portalId?: string | null; accessId?: string | null; expiresAt?: string | null };

/** Compare authorization scopes, not list order or presentation labels. */
export function participantAccessKey(roles: AccessRole[]): string {
  return JSON.stringify(roles.map(role => [role.key, role.groupId ?? null, role.portalId ?? null, role.accessId ?? null, role.expiresAt ?? null]).sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right))));
}

/** An explicit server denial must never become an offline-cache fallback. */
export function groupAccessDenied(error: { code?: string; message?: string }): boolean {
  return ["42501", "28000", "28P01", "PGRST301", "PGRST302", "P0002"].includes(error.code ?? "")
    || /^(?:NOT_AUTHORIZED|AUTH_REQUIRED|GROUP_NOT_FOUND|GROUP_ACCESS_DENIED|MEMBERSHIP_REQUIRED|SESSION_EXPIRED)$/.test(error.message ?? "");
}
