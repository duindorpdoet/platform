import {mkdtempSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {describe,expect,it} from 'vitest';
const scanner=resolve('scripts/acceptance/scan-client-artifacts.mjs');
describe('private Auth allowlist artifact boundary',()=>{
 it.each(['owner@example.invalid','OWNER@EXAMPLE.INVALID'])('rejects one leaked recipient independently of the combined secret without printing it',leaked=>{
  const directory=mkdtempSync(join(tmpdir(),'fn-artifact-policy-'));
  try {
   mkdirSync(join(directory,'.next/static'),{recursive:true});writeFileSync(join(directory,'.next/static/app.js'),`const leak=${JSON.stringify(leaked)}`);
   const result=spawnSync(process.execPath,[scanner],{cwd:directory,encoding:'utf8',env:{PATH:process.env.PATH,NODE_ENV:'test',FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'tester@example.invalid,owner@example.invalid'}});
   expect(result.status).not.toBe(0);expect(result.stderr).toContain('FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS value found');
   expect(result.stderr).not.toContain(leaked);
  } finally {rmSync(directory,{recursive:true});}
 });
 it('accepts artifacts without a configured private recipient',()=>{
  const directory=mkdtempSync(join(tmpdir(),'fn-artifact-policy-'));
  try {
   mkdirSync(join(directory,'.next/static'),{recursive:true});writeFileSync(join(directory,'.next/static/app.js'),'const publicBrand="FrightNight"');
   const result=spawnSync(process.execPath,[scanner],{cwd:directory,encoding:'utf8',env:{PATH:process.env.PATH,NODE_ENV:'test',FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'tester@example.invalid,owner@example.invalid'}});
   expect(result.status).toBe(0);expect(JSON.parse(result.stdout)).toMatchObject({status:'pass',filesScanned:1});
  } finally {rmSync(directory,{recursive:true});}
 });
});
