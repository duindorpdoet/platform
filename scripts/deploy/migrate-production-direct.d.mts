import type { spawn } from "node:child_process";
type Environment = Record<string, string | undefined>;
export type DirectMigrationResult = {
  status: "SUCCESS"; sqlStates: string[]; migrations: string[];
  activationReport: "COMPLETED"; activationReportRows: number;
};
export function runProductionDirectMigration(env?: Environment, request?: typeof fetch,
  spawnProcess?: typeof spawn): Promise<DirectMigrationResult>;
export function runProductionDirectMigrationDryRun(env?: Environment, request?: typeof fetch,
  spawnProcess?: typeof spawn): Promise<{status: "SUCCESS"; sqlStates: string[]; migrations: string[]; dryRun: true}>;
