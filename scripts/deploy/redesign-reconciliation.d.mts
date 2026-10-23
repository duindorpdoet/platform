type MetadataRow = Record<string, unknown> & { version: string; runid: string | number; jobid: string | number; status: string };
type Baseline = { migrationHistory: MetadataRow[]; cronHistory: MetadataRow[]; cronJobs: MetadataRow[] };
export function releaseMetadataQuery(): string;
export function reconcileReleaseMetadata(before: Baseline, after: Baseline, expectedVersions: string[]): { failures: string[]; addedMigrationVersions: string[]; addedCronRuns: number; updatedActiveCronRuns: number };
