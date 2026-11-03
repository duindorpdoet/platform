export interface LoadSample { latencyMs: number; status: number; unexpected: boolean }
export interface LoadSummary { requests: number; unexpected: number; unexpectedRate: number; p50Ms: number | null; p95Ms: number | null; p99Ms: number | null; maxMs: number | null; elapsedMs: number; requestsPerSecond: number | null; statusCounts: Record<string, number> }
export interface QueuedLoadCommand { commandId: string; operation: string; payload: { destinationId: string; expectedVersion: number; [key: string]: unknown } }
export interface LoadReply { status: number; value?: unknown }
export const LOAD_STEPS: readonly number[];
export const LOAD_LIMITS: Readonly<{ p95Ms: number; unexpectedRate: number; maxActors: number; maxInFlight: number; walkDurationMs: number; maxRequestsPerStage: number }>;
export function loadPlan(startCapacity?: number, maximum?: number): { configuredStartPlaces: number; peakPhones: number; attendanceForecast: boolean; actorLimit: number; steps: number[]; limits: typeof LOAD_LIMITS; notMeasured: string[]; [key: string]: unknown };
export function percentile(values: number[], quantile: number): number | null;
export function summarize(samples: LoadSample[], elapsedMs?: number): LoadSummary;
export function stopReasons(summary: LoadSummary, integrityErrors?: string[]): string[];
export function reconnectOffsets(phones: number, seed: string, windowMs?: number): number[];
export function coalesceSnapshot<T>(read: () => Promise<T>): () => Promise<T>;
export function recoverQueuedCommand(send: (command: QueuedLoadCommand) => Promise<LoadReply>, command: QueuedLoadCommand, options?: { wait?: (ms: number) => Promise<void>; maxAttempts?: number; seed?: string }): Promise<{ state: string; attempts: number; confirmed: boolean; value?: unknown }>;
export function assertLoadBinding(env: NodeJS.ProcessEnv): { origin: string; projectRef: string; slug: string };
export function runStagingLoad(env?: NodeJS.ProcessEnv, maximum?: number): Promise<Record<string, unknown>>;

export function databaseCounterDelta(before: Record<string, unknown> | null, after: Record<string, unknown> | null): { reset: boolean; counters: Record<string, number> | null };
