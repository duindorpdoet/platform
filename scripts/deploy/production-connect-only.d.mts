type Environment = Record<string, string | undefined>;
export type ErrorClassification = { sqlState: string | null; errorClass: string; prefix: string | null };
export function connectError(error: unknown, libpq?: boolean): ErrorClassification;
type Client = { connection?: unknown; on(event: string, listener: (error: unknown) => void): unknown; connect(): Promise<unknown>; end(): Promise<unknown> };
type Execution = (args: string[], environment: Environment, timeoutMs: number) => Promise<{ code: number | null; expired: boolean; stderr: string; unavailable?: boolean }>;
export type ConnectOnlyReport = { diagnostic: "production-connect-only"; readOnly: boolean; sqlSent: boolean; changedRows: number; messagesSent: number;
  comparison: string; connectionPath: "direct" | "session-pooler"; connectionLimitMs: number; probes: Array<{ driver: string; connected: boolean; durationMs: number | null; sqlState: string | null; errorClass: string | null; prefix: string | null;
    cleanupErrorClass?: string; events?: Array<{event: string;at: string;elapsedMs: number}> }> };
export function runConnectOnlyDiagnostics(env: Environment, project: unknown, poolers: unknown,
  ClientOverride?: new (configuration: Record<string, unknown>) => Client, execute?: Execution, endpointMode?: "pooler" | "direct"): Promise<ConnectOnlyReport>;
