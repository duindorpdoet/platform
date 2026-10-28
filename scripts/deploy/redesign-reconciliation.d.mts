type MetadataRow = Record<string, unknown> & { version: string; runid: string | number; jobid: string | number; status: string };
type Baseline = { migrationHistory: MetadataRow[]; cronHistory: MetadataRow[]; cronJobs: MetadataRow[]; cronBoundary: string; cronTerminal: {rows: number; sha256: string}; mailEventIds: string[]; mailEventOriginal: {rows: number; sha256: string}; addedMailEvents: number; invalidAddedMailEvents: number };
export function releaseMetadataQuery(before?: Baseline): string;
export function reconcileReleaseMetadata(before: Baseline, after: Baseline, expectedVersions: string[]): { failures: string[]; addedMigrationVersions: string[]; addedCronRuns: number; updatedActiveCronRuns: number; addedMailEvents: number };
