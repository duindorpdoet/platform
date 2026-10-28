import { expect, it } from 'vitest';
import { reconcileReleaseMetadata, releaseMetadataQuery } from './redesign-reconciliation.mjs';

const row = {version:'old',runid:1,jobid:1,status:'running',database:'postgres',username:'scheduler',command:'select scheduled_task()',start_time:'2026-10-23T12:00:00Z',end_time:null,return_message:null};
const before={migrationHistory:[{...row,version:'old'}],cronHistory:[row],cronJobs:[{...row}],cronBoundary:'1',cronTerminal:{rows:200000,sha256:'original-archive'},mailEventIds:['94000000-0000-0000-0000-000000000001'],mailEventOriginal:{rows:1,sha256:'original-events'},addedMailEvents:0,invalidAddedMailEvents:0};
it('accounts only for reviewed migration additions and legitimate scheduler activity',()=>{
  const after={...before,migrationHistory:[...before.migrationHistory,{...row,version:'reviewed'}],cronHistory:[{...row,status:'succeeded',end_time:'2026-10-23T12:00:01Z',return_message:'1 row'}, {...row,runid:2}]};
  expect(reconcileReleaseMetadata(before,after,['reviewed'])).toEqual({failures:[],addedMigrationVersions:['reviewed'],addedCronRuns:1,updatedActiveCronRuns:1,addedMailEvents:0});
});
it('allows only verified append activity while retaining the complete original event fingerprint',()=>{
  expect(reconcileReleaseMetadata(before,{...before,addedMailEvents:7},['old'])).toMatchObject({failures:[],addedMailEvents:7});
  for(const change of [{mailEventIds:[]},{mailEventOriginal:{rows:1,sha256:'rewritten'}},{mailEventOriginal:{rows:0,sha256:'deleted'}},{invalidAddedMailEvents:1},{addedMailEvents:-1}]) {
    expect(reconcileReleaseMetadata(before,{...before,...change},['old']).failures).toContain('app_private.email_events');
  }
  expect(()=>releaseMetadataQuery({...before,mailEventIds:["';select 1;"]})).toThrow('MAIL_EVENT_BASELINE_REQUIRED');
});
it('blocks deleted history, rewritten migrations and unreviewed migration versions',()=>{
  expect(reconcileReleaseMetadata(before,{...before,cronHistory:[]},['old']).failures).toContain('cron.job_run_details');
  expect(reconcileReleaseMetadata(before,{...before,cronTerminal:{...before.cronTerminal,sha256:'changed'}},['old']).failures).toContain('cron.job_run_details');
  expect(reconcileReleaseMetadata(before,{...before,migrationHistory:[{...row,command:'changed'}]},['old']).failures).toContain('supabase_migrations.schema_migrations');
  expect(reconcileReleaseMetadata(before,{...before,migrationHistory:[...before.migrationHistory,{...row,version:'unknown'}]},['old']).failures).toContain('supabase_migrations.schema_migrations');
});
it('blocks changed completed cron records, commands and invented job executions',()=>{
  const finished={...before,cronHistory:[{...row,status:'succeeded'}]};
  expect(reconcileReleaseMetadata(finished,{...finished,cronHistory:[{...row,status:'succeeded',return_message:'rewritten'}]},['old']).failures).toContain('cron.job_run_details');
  expect(reconcileReleaseMetadata(before,{...before,cronHistory:[{...row,command:'different'}]},['old']).failures).toContain('cron.job_run_details');
  expect(reconcileReleaseMetadata(before,{...before,cronHistory:[row,{...row,runid:2,jobid:42}]},['old']).failures).toContain('cron.job_run_details');
});
