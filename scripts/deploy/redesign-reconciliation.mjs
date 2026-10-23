import { isDeepStrictEqual } from 'node:util';

export function releaseMetadataQuery() {
  return `select jsonb_build_object(
    'migrationHistory',(select coalesce(jsonb_agg(to_jsonb(m) order by m.version),'[]') from supabase_migrations.schema_migrations m),
    'cronHistory',(select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('runid',r.runid::text,'jobid',r.jobid::text) order by r.runid),'[]') from cron.job_run_details r),
    'cronJobs',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('jobid',j.jobid::text) order by j.jobid),'[]') from cron.job j)
  ) as metadata`;
}

// These are the only metadata changes caused by this deployment or by the
// running scheduler. Original migration records and completed cron records
// remain immutable; additions and in-flight completions are reported separately.
export function reconcileReleaseMetadata(before, after, expectedVersions) {
  const failures=[];
  const oldMigrations=new Map(before.migrationHistory.map(row=>[row.version,row]));
  const newMigrations=new Map(after.migrationHistory.map(row=>[row.version,row]));
  const addedVersions=after.migrationHistory.filter(row=>!oldMigrations.has(row.version)).map(row=>row.version);
  if([...oldMigrations].some(([id,row])=>!isDeepStrictEqual(row,newMigrations.get(id))) ||
    addedVersions.some(version=>!expectedVersions.includes(version)) ||
    expectedVersions.some(version=>!newMigrations.has(version)))failures.push('supabase_migrations.schema_migrations');

  const oldRuns=new Map(before.cronHistory.map(row=>[String(row.runid),row]));
  const newRuns=new Map(after.cronHistory.map(row=>[String(row.runid),row]));
  const jobs=new Map(before.cronJobs.map(row=>[String(row.jobid),row]));
  const active=new Set(['starting','connecting','sending','running']);
  const allowed=new Set([...active,'succeeded','failed']);
  const mutable=new Set(['job_pid','status','return_message','start_time','end_time']);
  const stable=row=>Object.fromEntries(Object.entries(row).filter(([name])=>!mutable.has(name)));
  let completedRuns=0,cronChanged=false;
  for(const [id,row] of oldRuns) {
    const next=newRuns.get(id);
    if(!next){cronChanged=true;continue;}
    if(isDeepStrictEqual(row,next))continue;
    if(!active.has(row.status)||!allowed.has(next.status)||!isDeepStrictEqual(stable(row),stable(next)))cronChanged=true;
    else completedRuns++;
  }
  const addedRuns=after.cronHistory.filter(row=>!oldRuns.has(String(row.runid)));
  const maxRun=before.cronHistory.reduce((maximum,row)=>BigInt(row.runid)>maximum?BigInt(row.runid):maximum,0n);
  for(const row of addedRuns) {
    const job=jobs.get(String(row.jobid));
    if(!job||!allowed.has(row.status)||BigInt(row.runid)<=maxRun||
      ['database','username','command'].some(name=>row[name]!==job[name]))cronChanged=true;
  }
  if(cronChanged||!isDeepStrictEqual(before.cronJobs,after.cronJobs))failures.push('cron.job_run_details');
  return {failures,addedMigrationVersions:addedVersions.sort(),addedCronRuns:addedRuns.length,updatedActiveCronRuns:completedRuns};
}
