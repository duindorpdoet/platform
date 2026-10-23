import { isDeepStrictEqual } from 'node:util';

export function releaseMetadataQuery(before) {
  const active="('starting','connecting','sending','running')";
  const boundary=String(before?.cronBoundary??'0');
  const pending=(before?.cronHistory??[]).map(row=>String(row.runid));
  if(![boundary,...pending].every(value=>/^\d+$/.test(value)))throw new Error('INVALID_CRON_BASELINE');
  const originalActive=pending.length?'r.runid in ('+pending.join(',')+')':'false';
  const terminal=before?`r.runid<=${boundary} and not (${originalActive})`:`coalesce(r.status,'') not in ${active}`;
  const tracked=before?`(${originalActive}) or r.runid>${boundary}`:`r.status in ${active}`;
  return `select jsonb_build_object(
    'migrationHistory',(select coalesce(jsonb_agg(jsonb_build_object('version',m.version,'sha256',encode(sha256(convert_to(to_jsonb(m)::text,'UTF8')),'hex')) order by m.version),'[]') from supabase_migrations.schema_migrations m),
    'cronBoundary',(select coalesce(max(runid),0)::text from cron.job_run_details),
    'cronTerminal',(select jsonb_build_object('rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) from (select encode(sha256(convert_to(to_jsonb(r)::text,'UTF8')),'hex') h from cron.job_run_details r where ${terminal}) hashes),
    'cronHistory',(select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('runid',r.runid::text,'jobid',r.jobid::text) order by r.runid),'[]') from cron.job_run_details r where ${tracked}),
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
  let completedRuns=0,cronChanged=!isDeepStrictEqual(before.cronTerminal,after.cronTerminal);
  for(const [id,row] of oldRuns) {
    const next=newRuns.get(id);
    if(!next){cronChanged=true;continue;}
    if(isDeepStrictEqual(row,next))continue;
    if(!active.has(row.status)||!allowed.has(next.status)||!isDeepStrictEqual(stable(row),stable(next)))cronChanged=true;
    else completedRuns++;
  }
  const addedRuns=after.cronHistory.filter(row=>!oldRuns.has(String(row.runid)));
  const maxRun=BigInt(before.cronBoundary);
  for(const row of addedRuns) {
    const job=jobs.get(String(row.jobid));
    if(!job||!allowed.has(row.status)||BigInt(row.runid)<=maxRun||
      ['database','username','command'].some(name=>row[name]!==job[name]))cronChanged=true;
  }
  if(cronChanged||!isDeepStrictEqual(before.cronJobs,after.cronJobs))failures.push('cron.job_run_details');
  return {failures,addedMigrationVersions:addedVersions.sort(),addedCronRuns:addedRuns.length,updatedActiveCronRuns:completedRuns};
}
