import { isDeepStrictEqual } from 'node:util';

export function releaseMetadataQuery(before) {
  const active="('starting','connecting','sending','running')";
  const boundary=String(before?.cronBoundary??'0');
  const pending=(before?.cronHistory??[]).map(row=>String(row.runid));
  if(![boundary,...pending].every(value=>/^\d+$/.test(value)))throw new Error('INVALID_CRON_BASELINE');
  const originalActive=pending.length?'r.runid in ('+pending.join(',')+')':'false';
  const terminal=before?`r.runid<=${boundary} and not (${originalActive})`:`coalesce(r.status,'') not in ${active}`;
  const tracked=before?`(${originalActive}) or r.runid>${boundary}`:`r.status in ${active}`;
  const mailIds=before?.mailEventIds;
  if(before&&(!Array.isArray(mailIds)||mailIds.some(id=>typeof id!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))))throw new Error('MAIL_EVENT_BASELINE_REQUIRED');
  const originalIds=before?`array[${mailIds.map(id=>`'${id}'::uuid`).join(',')}]::uuid[]`:'array[]::uuid[]';
  const originalMail=before?'e.id in (select id from original_mail_ids)':'true';
  const addedMail=before?`not (${originalMail})`:'false';
  return `set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;with original_mail_ids as (select unnest(${originalIds}) as id) select jsonb_build_object(
    'migrationHistory',(select coalesce(jsonb_agg(jsonb_build_object('version',m.version,'sha256',encode(sha256(convert_to(to_jsonb(m)::text,'UTF8')),'hex')) order by m.version),'[]') from supabase_migrations.schema_migrations m),
    'cronBoundary',(select coalesce(max(runid),0)::text from cron.job_run_details),
    'cronTerminal',(select jsonb_build_object('rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) from (select encode(sha256(convert_to(to_jsonb(r)::text,'UTF8')),'hex') h from cron.job_run_details r where ${terminal}) hashes),
    'cronHistory',(select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('runid',r.runid::text,'jobid',r.jobid::text) order by r.runid),'[]') from cron.job_run_details r where ${tracked}),
    'cronJobs',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('jobid',j.jobid::text) order by j.jobid),'[]') from cron.job j),
    'mailEventIds',(select coalesce(jsonb_agg(e.id order by e.id),'[]') from app_private.email_events e where ${originalMail}),
    'mailEventOriginal',(select jsonb_build_object('rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) from (select encode(sha256(convert_to(to_jsonb(e)::text,'UTF8')),'hex') h from app_private.email_events e where ${originalMail}) hashes),
    'addedMailEvents',(select count(*) from app_private.email_events e where ${addedMail}),
    'invalidAddedMailEvents',(select count(*) from app_private.email_events e where ${addedMail} and (e.provider is distinct from 'resend' or e.verification_key_hash is null or e.verification_key_hash !~ '^[0-9a-f]{64}$' or e.kind not in ('email.sent','email.delivered','email.delivery_delayed','email.bounced','email.complained','email.failed','email.suppressed')))
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
  // Preserve every original event byte-for-byte, including unlinked receipts.
  // Only newly appended receipts verified by the existing signed webhook may
  // arrive while a release runs. This is never a table-wide preservation waiver.
  if(!Array.isArray(before.mailEventIds)||!before.mailEventOriginal||
    !isDeepStrictEqual(before.mailEventIds,after.mailEventIds)||!isDeepStrictEqual(before.mailEventOriginal,after.mailEventOriginal)||
    !Number.isSafeInteger(after.addedMailEvents)||after.addedMailEvents<0||after.invalidAddedMailEvents!==0)failures.push('app_private.email_events');
  return {failures,addedMigrationVersions:addedVersions.sort(),addedCronRuns:addedRuns.length,updatedActiveCronRuns:completedRuns,addedMailEvents:after.addedMailEvents};
}
