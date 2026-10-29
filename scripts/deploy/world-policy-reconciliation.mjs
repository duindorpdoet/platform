import { isDeepStrictEqual } from 'node:util';

export const WORLD_POLICY_MIGRATION='20261029115329';
const tables=['app_private.world_coverage_policies','app_private.audit_events'];
const policyColumns=['event_id','version','missing_worlds','fingerprint','created_at'];
const lifecycleColumns=['policy_status','source_fingerprint','activated_at','activated_by','activation_reason'];

// Works on both sides of the expand migration: no new function or column is
// required on the source database. All returned rows stay in encrypted proofs.
export function worldPolicyInitializationQuery(before) {
  const boundary=String(before?.auditBoundary??'0');
  if(!/^\d+$/.test(boundary))throw new Error('INVALID_COVERAGE_AUDIT_BASELINE');
  const original=before?`a.id<=${boundary}`:'true';
  const added=before?`a.id>${boundary}`:'false';
  return `set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;
  with expected as (
    select e.id event_id,coalesce((e.settings->>'portalRegistrationOpen')::boolean,true) houses_open,
      (select coalesce(max(p.version),0)+1 from app_private.world_coverage_policies p where p.event_id=e.id) version,
      coalesce((select array_agg(required.slug order by required.slug)
        from unnest(array['heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk']) required(slug)
        where not exists(select 1 from app_private.portals p join app_private.worlds w on w.id=p.world_id and w.slug=required.slug
          where p.event_id=e.id and p.approval_status='approved' and p.lifecycle_status='active'
            and exists(select 1 from app_private.portal_private_locations l where l.portal_id=p.id
              and nullif(trim(l.street),'') is not null and nullif(trim(l.house_number),'') is not null
              and (case when l.marker_latitude is not null or l.marker_longitude is not null
                then l.marker_latitude between -90 and 90 and l.marker_longitude between -180 and 180
                when l.geocoded_latitude is not null or l.geocoded_longitude is not null
                then l.geocoded_latitude between -90 and 90 and l.geocoded_longitude between -180 and 180
                else l.latitude between -90 and 90 and l.longitude between -180 and 180 end))
            and exists(select 1 from app_private.portal_windows win where win.portal_id=p.id
              and win.max_concurrent_groups>0 and win.max_children_per_visit>0 and win.opens_at<win.closes_at
              and win.closes_at-win.opens_at>=make_interval(mins=>win.visit_minutes+win.buffer_minutes)
              and win.opens_at<(e.local_date+time '21:30') at time zone 'Europe/Amsterdam'
              and win.closes_at>(e.local_date+time '16:30') at time zone 'Europe/Amsterdam'))),'{}'::text[]) missing
    from app_private.events e
  ) select jsonb_build_object(
    'capturedAt',statement_timestamp(),
    'migrationApplied',exists(select 1 from supabase_migrations.schema_migrations where version='${WORLD_POLICY_MIGRATION}'),
    'policyRows',coalesce((select jsonb_agg(to_jsonb(p) order by p.event_id,p.version) from app_private.world_coverage_policies p),'[]'),
    'expected',coalesce((select jsonb_agg(jsonb_build_object('event_id',event_id,'version',version,'missing_worlds',missing,
      'policy_status',case when houses_open then 'provisional' else 'active' end,'source_fingerprint',md5(missing::text),
      'fingerprint',md5((case when houses_open then 'provisional' else 'active' end)||':'||md5(missing::text))) order by event_id) from expected),'[]'),
    'auditBoundary',(select coalesce(max(id),0)::text from app_private.audit_events),
    'auditOriginal',(select jsonb_build_object('rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex'))
      from (select encode(sha256(convert_to(to_jsonb(a)::text,'UTF8')),'hex') h from app_private.audit_events a where ${original}) hashes),
    'addedAuditRows',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('id',a.id::text) order by a.id)
      from app_private.audit_events a where ${added}),'[]')
  ) as coverage_initialization`;
}

/** Accept only the one reviewed initialization row per event, never a table waiver. */
export function reconcileWorldPolicyInitialization(before,after,expectedVersions) {
  const failures=[];
  if(!before||!after||!Array.isArray(before.policyRows)||!Array.isArray(after.policyRows)||!Array.isArray(before.expected)
    ||!before.auditOriginal||!after.auditOriginal||!Array.isArray(after.addedAuditRows)||!/^\d+$/.test(String(before.auditBoundary))) {
    return {failures:[...tables],reconciledTables:[],addedPolicies:0,addedCoverageAuditEvents:0};
  }
  const initializing=before.migrationApplied===false&&expectedVersions.includes(WORLD_POLICY_MIGRATION);
  const old=new Map(before.policyRows.map(row=>[`${row.event_id}:${row.version}`,row]));
  const current=new Map(after.policyRows.map(row=>[`${row.event_id}:${row.version}`,row]));
  let policyBad=current.size!==after.policyRows.length;
  for(const [key,row] of old) {
    const next=current.get(key);
    if(!next||Object.keys(row).some(column=>!isDeepStrictEqual(row[column],next[column])))policyBad=true;
    if(initializing&&lifecycleColumns.some(column=>next?.[column]!== (column==='policy_status'?'retired':null)))policyBad=true;
    if(!initializing&&next&&!isDeepStrictEqual(row,next))policyBad=true;
  }
  const additions=after.policyRows.filter(row=>!old.has(`${row.event_id}:${row.version}`));
  const expected=new Map((initializing?before.expected:[]).map(row=>[`${row.event_id}:${row.version}`,row]));
  const earliest=Date.parse(before.capturedAt),latest=Date.parse(after.capturedAt);
  const during=value=>typeof value==='string'&&Number.isFinite(earliest)&&Number.isFinite(latest)&&latest>=earliest
    &&Date.parse(value)>=earliest&&Date.parse(value)<=latest;
  if(additions.length!==expected.size)policyBad=true;
  for(const row of additions) {
    const wanted=expected.get(`${row.event_id}:${row.version}`);
    if(!wanted||[...policyColumns,...lifecycleColumns].length!==Object.keys(row).length
      ||Object.keys(wanted).some(column=>!isDeepStrictEqual(wanted[column],row[column]))||!during(row.created_at)
      ||row.activated_by!==null||row.activation_reason!==(row.policy_status==='active'?'Definitief huizenaanbod bij gesloten huisinschrijving':null)
      ||(row.policy_status==='active'?!during(row.activated_at):row.activated_at!==null))policyBad=true;
  }
  if(policyBad)failures.push(tables[0]);
  const closed=new Map((initializing?before.expected:[]).filter(row=>row.policy_status==='active').map(row=>[row.event_id,row]));
  let auditBad=!isDeepStrictEqual(before.auditOriginal,after.auditOriginal)||after.addedAuditRows.length!==closed.size;
  const seen=new Set();
  for(const row of after.addedAuditRows) {
    const wanted=closed.get(row.event_id);
    if(!wanted||seen.has(row.event_id)||!/^[1-9]\d*$/.test(row.id)||BigInt(row.id)<=BigInt(before.auditBoundary)
      ||Object.keys(row).length!==9||row.action!=='world.coverage.active'||row.actor_id!==null||row.resource_type!=='event'
      ||row.resource_id!==row.event_id||row.correlation_id!==null||!during(row.created_at)
      ||!isDeepStrictEqual(row.minimal_change,{policyVersion:wanted?.version,missingWorlds:wanted?.missing_worlds,previousPolicyVersion:null}))auditBad=true;
    seen.add(row.event_id);
  }
  if(auditBad)failures.push(tables[1]);
  return {failures,reconciledTables:failures.length?[]:initializing?[...tables]:[],
    addedPolicies:additions.length,addedCoverageAuditEvents:after.addedAuditRows.length};
}
