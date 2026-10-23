import type { Readable } from 'node:stream';
type Fingerprint = { table: string; rows: number; sha256: string };
type CatalogEntry = { schema: string; name: string; columns: string[] };
export function fingerprintQuery(catalog: CatalogEntry[]): string;
export function compareFingerprints(before: Fingerprint[], after: Fingerprint[]): string[];
export function encryptStream(source: Readable, filename: string, key: Uint8Array, context: string): Promise<void>;
export function verifyBackupFile(filename: string, key: Uint8Array, context: string): Promise<{sha256:string;bytes:number}>;
