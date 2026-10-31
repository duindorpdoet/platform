export const PHASE_BODIES: Readonly<Record<string, string>>;
export const CAPACITY_SQL: string;
export function phaseSql(name: string): string;
export function observerSql(pid: number | null, original?: boolean): string;
export function diagnosticError(error: unknown): string;
export function traceConnection(client: {connection?: unknown}, entry: Record<string, unknown>): void;
export type Report = {
  status: string; observerAvailable: boolean; errorClass?: string; totalMs: number; totalExpired: boolean;
  connections: Record<string, Record<string, unknown>>;
  phases: Array<Record<string, unknown> & {name: string; status: string; samples: Array<Record<string, unknown>>}>;
  checks: Record<string, boolean | null>;
  [key: string]: unknown;
};
type Result = { rows: Record<string, unknown>[]; fields?: {name: string}[] };
type Client = { on(event: string, listener: (error: unknown) => void): unknown; connect(): Promise<unknown>;
  query(input: {text: string;query_timeout: number}): Promise<Result | Result[]>; end(): Promise<unknown> };
export function runHistoryDiagnosis(env?: Record<string, string | undefined>, request?: typeof fetch,
  ClientOverride?: new (configuration: Record<string, unknown>) => Client): Promise<Report>;
