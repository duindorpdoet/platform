export const ACTOR_QUERY: string;
export function checkStartregieReads(env?: Record<string, string | undefined>, request?: typeof fetch, now?: () => number): Promise<{
  environment: string;
  revision: string;
  transport: string;
  readOnly: boolean;
  changedRows: number;
  messagesSent: number;
  productionPerformanceProven: boolean;
  maximumDurationMs: number;
  checks: Array<{ attempt: number; groups: number; currentSchedules: number; snapshotMs: number; readinessMs?: number; ready?: boolean; reasonCodes?: string[]; readinessSkipped?: string }>;
}>;
