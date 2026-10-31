export const METRICS_ENDPOINT: string;
export type Metrics = {
  acceptedSeries: number; rejectedSeries: number;
  cpu: Record<string, Record<string, number>>; disks: Record<string, Record<string, number>>; gauges: Record<string, number>;
  sampleTimestampMinMs: number | null; sampleTimestampMaxMs: number | null;
  filesystem: {completeSeriesCount: number; minimumAvailableBytes: number | null; minimumAvailableFraction: number | null; maximumSizeBytes: number | null};
};
export type Snapshot = Metrics & {scrapeMidpointMs: number};
export type Report = {status: string; snapshots: Snapshot[]; requests: Record<string, unknown>[]; [key: string]: unknown};
export function parseResourceMetrics(text: string): Metrics;
export function resourceRates(first: Snapshot, second: Snapshot): {cpu: Record<string, unknown>; disk: Record<string, unknown>};
export function runResourceDiagnosis(env?: Record<string, string | undefined>, request?: typeof fetch, onFirstSnapshot?: () => void): Promise<Report>;
export function runResourceMode(env?: Record<string, string | undefined>, request?: typeof fetch,
  historyRunner?: (env: Record<string, string | undefined>) => Promise<{status: string; [key: string]: unknown}>): Promise<{status: string; [key: string]: unknown}>;
