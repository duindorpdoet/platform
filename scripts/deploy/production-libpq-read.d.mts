import type { AdminDatabasePlan } from "./production-read-query.mjs";
type Environment = Record<string, string | undefined>;
type ProcessResult = { error: null | {code?: string | number; killed?: boolean}; stdout: string; stderr: string };
type Tools = { psql: string };
export function parseReleaseCsv(source: string, nullMarker: string): Record<string, unknown>[];
export function libpqReadQuery(batch: string, env: Environment, plan: AdminDatabasePlan, caBundle: string, statementMs: number,
  run?: (command: string, args: string[], environment: Environment, timeout: number) => Promise<ProcessResult>,
  validate?: (directory: string) => Promise<Tools>): Promise<Record<string, unknown>[]>;
