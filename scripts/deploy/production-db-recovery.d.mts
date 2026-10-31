import type { ConnectionErrorClass } from "./production-db-diagnostics.mjs";
export const MANAGEMENT_PROBE_SQL: string;
type PoolerProbe = (env: Record<string, string | undefined>, project: unknown, poolers: unknown) => Promise<{
  connectivity: boolean; errorClass: ConnectionErrorClass | null;
}>;
export function recoverProductionDatabase(env?: Record<string, string | undefined>, request?: typeof fetch, poolerProbe?: PoolerProbe,
  now?: () => number, sleep?: (milliseconds: number) => Promise<void>): Promise<{
  restarted: boolean; restartRequests: number; managementReachable: boolean; deployed: boolean;
  sqlWrites: number; messagesSent: number; nextStep: string;
}>;
