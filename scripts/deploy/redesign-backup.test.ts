import { it, expect } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { createHash } from 'node:crypto';
import { encryptStream, verifyBackupFile, compareFingerprints, dryRunReleaseMigrations, preservationManagementRequest, fingerprintManagementRequest, sourceReadPrefix, withSourceReadPhase } from './redesign-backup.mjs';

it('enforces existing backup policy locally for both exported and imported repeatable-read snapshots',()=>{
  const exported=sourceReadPrefix(),imported=sourceReadPrefix('00000001-00000002-1');
  expect(exported).toMatch(/^begin isolation level repeatable read read only;/);
  expect(exported).not.toContain('set transaction snapshot');
  expect(imported).toMatch(/^begin isolation level repeatable read read only;set transaction snapshot '00000001-00000002-1';/);
  for(const prefix of [exported,imported]) {
    expect(prefix).toContain("set local statement_timeout='5min';set local lock_timeout='3s';set local jit=off;");
    expect(prefix).toContain("set local timezone='UTC';set local datestyle='ISO';");
    expect(prefix).not.toMatch(/\b(alter|insert|update|delete|grant|set role)\b/i);
  }
  expect(()=>sourceReadPrefix("00000001-00000002-1';commit;")).toThrow('INVALID_BACKUP_SNAPSHOT');
});

it('reports fixed source phases and duration on failure without logging query results or error details',async()=>{
  const metadata:unknown[]=[],report=(value:unknown)=>metadata.push(value);let tick=0;
  const now=()=>tick+=7;
  const result=await withSourceReadPhase('preservation',async()=>({private:'PRIVATE_RESULT'}),report,now);
  expect(result).toEqual({private:'PRIVATE_RESULT'});
  const error=new Error('PRIVATE_PROVIDER_DETAIL');
  await expect(withSourceReadPhase('vault-fingerprint',async()=>{throw error;},report,now)).rejects.toBe(error);
  expect(metadata).toEqual([{backupRead:'preservation',status:'started'},{backupRead:'preservation',status:'passed',durationMs:7},
    {backupRead:'vault-fingerprint',status:'started'},{backupRead:'vault-fingerprint',status:'failed',durationMs:7}]);
  expect(JSON.stringify(metadata)).not.toContain('PRIVATE_');
});

it('authenticates a streamed backup and rejects a corrupt archive',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'duindorp-backup-contract-'));
  try {
    const path=join(dir,'fixture.aes'),bytes=Buffer.alloc(200000,42),key=Buffer.alloc(32,11);
    await encryptStream(Readable.from([bytes.subarray(0,30000),bytes.subarray(30000)]),path,key,'isolated-fixture');
    await expect(verifyBackupFile(path,key,'isolated-fixture')).resolves.toEqual({sha256:createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length});
    await expect(verifyBackupFile(path,key,'other-environment')).rejects.toThrow();
    const corrupted=await readFile(path);corrupted[corrupted.length-1]^=1;await writeFile(path,corrupted);
    await expect(verifyBackupFile(path,key,'isolated-fixture')).rejects.toThrow();
  } finally {await rm(dir,{recursive:true});}
});
it('blocks missing or changed original rows while allowing additive tables',()=>{
  const original=[{table:'app_private.events',rows:1,sha256:'original'}];
  expect(compareFingerprints(original,[...original,{table:'new_table',rows:0,sha256:'new'}])).toEqual([]);
  expect(compareFingerprints(original,[])).toEqual(['app_private.events']);
  expect(compareFingerprints(original,[{...original[0],sha256:'changed'}])).toEqual(['app_private.events']);
});

it('bounds the owner-only management inspection with database-enforced read-only state and transaction-local settings',()=>{
  const request=preservationManagementRequest([{schema:'app_private',name:'events',columns:['id','settings']}],{auditBoundary:'42'});
  expect(request.read_only).toBe(false);
  expect(request.query).toMatch(/^begin read only;set local statement_timeout='5min';set local lock_timeout='3s';/);
  expect(request.query).toContain("if current_setting('transaction_read_only')<>'on' then raise exception 'PRESERVATION_READ_ONLY_REQUIRED'");
  expect(request.query).toContain("set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;");
  expect(request.query).toContain('from "app_private"."events" t');
  expect(request.query).toContain('a.id<=42');
  expect(request.query).toContain('app_private.portal_location_ready(p.id)');
  expect(request.query).toMatch(/;commit;$/);
  expect(request.query).not.toMatch(/\b(insert|update|delete|grant|alter|set role)\b/i);
  expect(()=>preservationManagementRequest([{schema:'app_private',name:'events',columns:['id']}],{auditBoundary:'42;commit;delete from app_private.events'})).toThrow('INVALID_COVERAGE_AUDIT_BASELINE');
  const fingerprint=fingerprintManagementRequest([{schema:'app_private',name:'events',columns:['id']}]);
  expect(fingerprint.read_only).toBe(false);
  expect(fingerprint.query).toMatch(/^begin read only;/);
  expect(fingerprint.query).toContain("current_setting('transaction_read_only')<>'on'");
  expect(fingerprint.query).toContain('from "app_private"."events" t');
  expect(fingerprint.query).not.toContain('coverage_initialization');
  expect(fingerprint.query).toMatch(/;commit;$/);
});

it('dry-runs only unapplied migrations and retains a proof for every reviewed file',async()=>{
  const {REVIEWED_RELEASE_MIGRATIONS: files}=await import('./release-migrations.mjs');
  const applied=files.slice(0,-1).map(file=>file.split('_')[0]),executed:string[]=[];
  const proof=await dryRunReleaseMigrations([...files],applied,async sql=>{executed.push(sql);});
  expect(executed).toHaveLength(1);
  expect(executed[0]).toMatch(/^begin;set local role postgres;set local lock_timeout='3s';set local statement_timeout='5min';/);
  expect(executed[0]).toMatch(/;commit$/);
  expect(proof.map(row=>row.file)).toEqual(files);
  expect(proof.slice(0,-1).every(row=>row.execution==='already-applied')).toBe(true);
  expect(proof.at(-1)?.execution).toBe('dry-run');
  expect(proof.every(row=>/^[a-f0-9]{64}$/.test(row.sha256))).toBe(true);
  executed.length=0;
  await dryRunReleaseMigrations([...files],files.map(file=>file.split('_')[0]),async sql=>{executed.push(sql);});
  expect(executed).toEqual([]);
  await expect(dryRunReleaseMigrations(files.slice(1),applied,async()=>{})).rejects.toThrow();
});
