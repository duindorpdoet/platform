export function backupKey(secret: string | undefined): Buffer;
export function sealBackup(value: Uint8Array, key: Uint8Array, context: string): Buffer;
export function openBackup(value: Buffer, key: Uint8Array, context: string): Buffer;
export function management(path: string, body?: unknown): Promise<unknown>;
