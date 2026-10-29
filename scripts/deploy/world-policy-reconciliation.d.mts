export const WORLD_POLICY_MIGRATION: string;
export type WorldPolicyInitialization = {
  capturedAt: string;
  migrationApplied: boolean;
  policyRows: Array<Record<string, unknown>>;
  expected: Array<Record<string, unknown>>;
  auditBoundary: string;
  auditOriginal: { rows: number; sha256: string };
  addedAuditRows: Array<Record<string, unknown>>;
};
export function worldPolicyInitializationQuery(before?: Pick<WorldPolicyInitialization, 'auditBoundary'>): string;
export function reconcileWorldPolicyInitialization(before: WorldPolicyInitialization | undefined, after: WorldPolicyInitialization | undefined, expectedVersions: string[]): {
  failures: string[];
  reconciledTables: string[];
  addedPolicies: number;
  addedCoverageAuditEvents: number;
};
