import { it, expect } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { createHash } from 'node:crypto';
import { encryptStream, verifyBackupFile, compareFingerprints,dryRunReleaseMigrations } from './redesign-backup.mjs';
import {REVIEWED_RELEASE_MIGRATIONS} from './release-migrations.mjs';

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
it('rehearses only missing migrations on a restored release while retaining every file hash',async()=>{
  const files=[...REVIEWED_RELEASE_MIGRATIONS],applied=files.slice(0,-12).map(file=>file.split('_')[0]);
  const executed:string[]=[];
  const proof=await dryRunReleaseMigrations(files,applied,async sql=>{executed.push(sql);});
  expect(executed).toHaveLength(12);
  expect(proof.map(row=>row.file)).toEqual(files);
  expect(proof.slice(0,-12).every(row=>row.execution==='already-applied')).toBe(true);
  expect(proof.slice(-12).every(row=>row.execution==='dry-run')).toBe(true);
  expect(proof.every(row=>/^[a-f0-9]{64}$/.test(row.sha256))).toBe(true);
  executed.length=0;
  const repeated=await dryRunReleaseMigrations(files,files.map(file=>file.split('_')[0]),async sql=>{executed.push(sql);});
  expect(executed).toEqual([]);
  expect(repeated.map(row=>row.sha256)).toEqual(proof.map(row=>row.sha256));
  expect(repeated.every(row=>row.execution==='already-applied')).toBe(true);
  await expect(dryRunReleaseMigrations(files.slice(1),applied,async()=>{})).rejects.toThrow('REVIEWED_MIGRATION_SET_CHANGED');
});
