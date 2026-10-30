import { isDeepStrictEqual } from 'node:util';

export const JOINT_ROUTE_SETTINGS_MIGRATION='20261030131348';
const table='app_private.event_route_settings';
const newColumns=['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version'];

// Full rows and independently derived initialization targets share the row
// fingerprint's statement snapshot. This uses only pre-migration columns.
export function jointRouteSettingsInitializationQuery(catalog) {
  const exists=catalog.some(entry=>entry.schema==='app_private'&&entry.name==='event_route_settings');
  return `select jsonb_build_object('capturedAt',statement_timestamp(),
    'migrationApplied',exists(select 1 from supabase_migrations.schema_migrations where version='${JOINT_ROUTE_SETTINGS_MIGRATION}'),
    'tableExists',to_regclass('${table}') is not null,
    'rows',${exists?`coalesce((select jsonb_agg(to_jsonb(s) order by s.event_id) from ${table} s),'[]'::jsonb)`:`'[]'::jsonb`},
    'expectedTargets',${exists?`coalesce((select jsonb_agg(jsonb_build_object('event_id',s.event_id,
      'organizer_coverage_portal_ids',case when e.slug='duindorp-halloween-2026' then coalesce((
        select jsonb_agg(p.id order by array_position(array['P-02','P-12'],p.system_code))
        from app_private.portals p where p.event_id=s.event_id and p.system_code in('P-02','P-12')
          and p.lifecycle_status='active' and p.approval_status='approved' and p.operation_status in('open','scheduled')
          and p.id is distinct from s.final_portal_id),'[]'::jsonb) else '[]'::jsonb end) order by s.event_id)
      from ${table} s join app_private.events e on e.id=s.event_id),'[]'::jsonb)`:`'[]'::jsonb`}) as joint_route_settings_initialization`;
}

/** Accept exactly the four reviewed initial fields; preserve all original JSON. */
export function reconcileJointRouteSettingsInitialization(before,after,expectedVersions) {
  const failure=()=>({failures:[table],reconciledTables:[],initializedSettingsRows:0});
  if(!before||!after||before.tableExists!==true||after.tableExists!==true||typeof before.migrationApplied!=='boolean'
    ||!Array.isArray(before.rows)||!Array.isArray(after.rows)||!Array.isArray(before.expectedTargets)||!Array.isArray(expectedVersions))return failure();
  const validRow=row=>row!==null&&typeof row==='object'&&!Array.isArray(row)&&typeof row.event_id==='string'&&row.event_id.length>0;
  if(!before.rows.every(validRow)||!after.rows.every(validRow))return failure();
  const original=new Map(before.rows.map(row=>[row.event_id,row])),current=new Map(after.rows.map(row=>[row.event_id,row]));
  if(original.size!==before.rows.length||current.size!==after.rows.length||original.size!==current.size)return failure();
  const initializing=!before.migrationApplied&&expectedVersions.includes(JOINT_ROUTE_SETTINGS_MIGRATION);
  if(!initializing) {
    for(const [eventId,row]of original)if(!isDeepStrictEqual(row,current.get(eventId)))return failure();
    return {failures:[],reconciledTables:[],initializedSettingsRows:0};
  }
  if(!before.expectedTargets.every(row=>validRow(row)&&Object.keys(row).length===2&&Array.isArray(row.organizer_coverage_portal_ids)
    &&row.organizer_coverage_portal_ids.every(id=>typeof id==='string'&&id.length>0)&&new Set(row.organizer_coverage_portal_ids).size===row.organizer_coverage_portal_ids.length))return failure();
  const expected=new Map(before.expectedTargets.map(row=>[row.event_id,row.organizer_coverage_portal_ids]));
  if(expected.size!==before.expectedTargets.length||expected.size!==original.size)return failure();
  for(const [eventId,row]of original) {
    const next=current.get(eventId),targets=expected.get(eventId);
    if(!next||!targets||newColumns.some(column=>Object.hasOwn(row,column)||!Object.hasOwn(next,column)))return failure();
    const oldProjection=Object.fromEntries(Object.entries(next).filter(([column])=>!newColumns.includes(column)));
    if(!isDeepStrictEqual(row,oldProjection)||next.max_total_walking_seconds!==3900||next.max_early_finish_seconds!==1800
      ||next.route_policy_version!==1||!isDeepStrictEqual(next.organizer_coverage_portal_ids,targets))return failure();
  }
  return {failures:[],reconciledTables:[table],initializedSettingsRows:original.size};
}
