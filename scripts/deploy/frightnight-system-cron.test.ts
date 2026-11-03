import { describe,expect,it } from 'vitest';
import { summarizeSystemCronFile,unreviewedSystemCron,timerScope } from './frightnight-system-cron.mjs';
describe('bounded read-only system cron inventory',()=>{
 it('records hashes and scope without credential-bearing commands',()=>{
  const command='TOKEN=private-test-value\n* * * * * app curl https://staging-halloween.duindorpdoet.nl/api/jobs';
  const row=summarizeSystemCronFile('/etc/cron.d','frightnight',Buffer.from(command));
  expect(row.scope).toBe('staging-or-frightnight');expect(row.sha256).toMatch(/^[a-f0-9]{64}$/);
  expect(JSON.stringify(row)).not.toContain('private-test-value');expect(JSON.stringify(row)).not.toContain('curl');
  expect(unreviewedSystemCron([row],new Set())).toHaveLength(1);
  expect(unreviewedSystemCron([row],new Set([row.sha256!]))).toHaveLength(0);
  const changed=summarizeSystemCronFile('/etc/cron.d','frightnight',Buffer.from(command+' changed'));
  expect(unreviewedSystemCron([changed],new Set([row.sha256!]))).toHaveLength(1);
 });
 it('does not require a staging review hash for ordinary apt and logrotate jobs',()=>{
  const rows=['apt-compat','logrotate'].map(name=>summarizeSystemCronFile('/etc/cron.daily',name,Buffer.from('#!/bin/sh\n/usr/sbin/'+name)));
  expect(unreviewedSystemCron(rows,new Set())).toHaveLength(0);expect(timerScope('dtubngvxfbupgvgfrjko')).toBe('other-site');
 });
 it('fails closed for an unreadable explicitly staging-scoped cron file',()=>{
  expect(unreviewedSystemCron([{directory:'/etc/cron.d',name:'frightnight',status:'unavailable',scope:'staging-or-frightnight'}],new Set())).toHaveLength(1);
 });
 it('refuses oversized files and a filename outside the bounded directory',()=>{
  expect(()=>summarizeSystemCronFile('/etc','crontab',Buffer.alloc(131073))).toThrow('SYSTEM_CRON_FILE_BOUND_EXCEEDED');
  expect(()=>summarizeSystemCronFile('/etc','../secret',Buffer.from(''))).toThrow('SYSTEM_CRON_FILE_BOUND_EXCEEDED');
 });
});
