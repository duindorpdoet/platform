export const DIAGNOSTIC_SQL: string;
export function diagnosticPlan(env: Record<string, string | undefined>, project: unknown, poolers: unknown): {
  image: string; environment: Record<string, string>; clientArgs: string[];
};
type Execution = (args: string[], input?: string, environment?: Record<string, string>, timeoutMs?: number) => Promise<{
  code: number | null; expired: boolean; stdout: string;
}>;
export function runDiagnostics(env?: Record<string, string | undefined>, request?: typeof fetch, execute?: Execution): Promise<{
  readOnly: boolean; changedRows: number; messagesSent: number; durationMs: number;
  activity: Array<{ role: string; state: string; waitType: string; waitEvent: string; queryClass: string;
    backends: number; activeAtLeast15s: number; longestActiveSeconds: number | null }>;
}>;
