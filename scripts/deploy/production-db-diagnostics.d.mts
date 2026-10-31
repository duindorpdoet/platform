export const DIAGNOSTIC_SQL: string;
export function diagnosticPlan(env: Record<string, string | undefined>, project: unknown, poolers: unknown): {
  image: string; environment: Record<string, string>; clientArgs: string[];
};
type Execution = (args: string[], input?: string, environment?: Record<string, string>, timeoutMs?: number) => Promise<{
  code: number | null; expired: boolean; stdout: string; errorClass?: string | null;
}>;
export type ConnectionErrorClass = "CONNECTION_TIMEOUT" | "AUTH_FAILED" | "TLS" | "DNS" | "OTHER";
export function classifyConnectionError(stderr: string): ConnectionErrorClass;
export function probePoolerConnection(env: Record<string, string | undefined>, project: unknown, poolers: unknown, execute?: Execution): Promise<{
  connectivity: boolean; durationMs: number; code: number | null; expired: boolean; errorClass: ConnectionErrorClass | null; activity: unknown[] | null;
}>;
export function runDiagnostics(env?: Record<string, string | undefined>, request?: typeof fetch, execute?: Execution,
  connectOnlyProbe?: (env: Record<string, string | undefined>, project: unknown, poolers: unknown) => Promise<import("./production-connect-only.mjs").ConnectOnlyReport>): Promise<{
  readOnly: boolean; changedRows: number; messagesSent: number; durationMs: number;
  activity: Array<{ role: string; state: string; waitType: string; waitEvent: string; queryClass: string;
    backends: number; activeAtLeast15s: number; longestActiveSeconds: number | null }>;
} | import("./production-connect-only.mjs").ConnectOnlyReport>;
