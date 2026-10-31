export function backupKey(secret: string | undefined): Buffer;
export function sealBackup(value: Uint8Array, key: Uint8Array, context: string): Buffer;
export function openBackup(value: Buffer, key: Uint8Array, context: string): Buffer;
export function management(path: string, body?: unknown): Promise<unknown>;
type ReleaseReadBaseline = NonNullable<Parameters<typeof import('./redesign-reconciliation.mjs').releaseMetadataQuery>[0]> & {
  worldPolicyInitialization?: Parameters<typeof import('./redesign-backup.mjs').preservationManagementRequest>[1];
};
export function readReleaseState(
  catalog: Parameters<typeof import('./redesign-backup.mjs').preservationManagementRequest>[0],
  before?: ReleaseReadBaseline,
  request?: typeof management,
): Promise<{ preservation: unknown; metadata: unknown }>;
