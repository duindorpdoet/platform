import type { Readable } from 'node:stream';
import type { WorldPolicyInitialization } from './world-policy-reconciliation.mjs';
type Fingerprint = { table: string; rows: number; sha256: string };
type CatalogEntry = { schema: string; name: string; columns: string[] };
export function sourceReadPrefix(snapshot?: string): string;
type SourceReadPhase = 'snapshot-export' | 'catalog' | 'migration-history' | 'preservation' | 'roles' | 'role-memberships' | 'storage-objects' | 'vault-fingerprint' | 'storage-before' | 'storage-after';
export function withSourceReadPhase<T>(phase: SourceReadPhase, read: () => Promise<T>, report?: (metadata: {backupRead: SourceReadPhase; status: 'started' | 'passed' | 'failed'; durationMs?: number}) => void, now?: () => number): Promise<T>;
export function fingerprintQuery(catalog: CatalogEntry[]): string;
export function preservationQuery(catalog: CatalogEntry[], coverageBefore?: Pick<WorldPolicyInitialization, 'auditBoundary'>): string;
export function preservationManagementRequest(catalog: CatalogEntry[], coverageBefore?: Pick<WorldPolicyInitialization, 'auditBoundary'>): {read_only: false; query: string};
export function fingerprintManagementRequest(catalog: CatalogEntry[]): {read_only: false; query: string};
export function startIsolatedRestore(image: string, container: string, rootKey: string, execute?: (command: string,args: string[],input?: string,env?: Record<string,string>)=>Promise<string>): Promise<void>;
export function compareFingerprints(before: Fingerprint[], after: Fingerprint[]): string[];
export function encryptStream(source: Readable, filename: string, key: Uint8Array, context: string): Promise<void>;
export function verifyBackupFile(filename: string, key: Uint8Array, context: string): Promise<{sha256:string;bytes:number}>;

export function dryRunReleaseMigrations(files: string[], appliedVersions: string[], localQuery: (sql: string) => Promise<unknown>): Promise<Array<{file: string; sha256: string; execution: string; durationMs: number}>>;
export function runReleaseBackup(env?: Record<string,string|undefined>, dependencies?: {
 request?: typeof fetch;
 captureCommand?: (command: string,args: string[],input?: string,env?: Record<string,string|undefined>,inheritEnvironment?: boolean)=>Promise<string>;
 processCommand?: (command: string,args: string[],env?: Record<string,string|undefined>,inheritEnvironment?: boolean)=>{child: import('node:child_process').ChildProcessWithoutNullStreams;done: Promise<void>};
 startRestore?: (image: string,container: string,rootKey: string)=>Promise<void>;
}): Promise<void>;
