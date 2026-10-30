import { isDeepStrictEqual } from 'node:util';
import { JOINT_ROUTE_SETTINGS_MIGRATION } from './joint-route-settings-reconciliation.mjs';

export const P12_ROUTE_POLICY_MIGRATION='20261030182243';
const settingsTable='app_private.event_route_settings',portalsTable='app_private.portals',windowsTable='app_private.portal_windows';
const tables=[settingsTable,portalsTable,windowsTable];
const initialColumns=['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version'];
const strip=(row,columns)=>Object.fromEntries(Object.entries(row).filter(([column])=>!columns.includes(column)));
function timestampMicros(value) {
  if(typeof value!=='string')return null;
  const match=value.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/);
  if(!match)return null;
  const whole=Date.parse(match[1]+match[3]);
  return Number.isFinite(whole)?BigInt(whole)*1000n+BigInt((match[2]??'').padEnd(6,'0')):null;
}

// Complete rows and the event-local hard closing share the fingerprint's SQL
// statement snapshot. No portal status or caller-provided ID can widen scope.
export function p12RoutePolicyQuery(catalog) {
  const exists=name=>catalog.some(entry=>entry.schema==='app_private'&&entry.name===name);
  const rows=(name,key)=>exists(name)?`coalesce((select jsonb_agg(to_jsonb(r) order by r.${key}) from app_private.${name} r),'[]'::jsonb)`:`'[]'::jsonb`;
  return `select jsonb_build_object('capturedAt',statement_timestamp(),
    'appliedMigrations',coalesce((select jsonb_agg(version::text order by version) from supabase_migrations.schema_migrations),'[]'::jsonb),
    'tablesExist',${tables.map(table=>`to_regclass('${table}') is not null`).join(' and ')},
    'settings',${rows('event_route_settings','event_id')},'portals',${rows('portals','id')},'windows',${rows('portal_windows','id')},
    'targetEvents',${exists('events')?`coalesce((select jsonb_agg(jsonb_build_object('event_id',e.id,
      'close_at',(e.local_date+time '19:00') at time zone e.timezone) order by e.id)
      from app_private.events e where e.slug='duindorp-halloween-2026'),'[]'::jsonb)`:`'[]'::jsonb`}) as p12_route_policy`;
}

/** Authorize only this pending event-specific migration's exact row changes. */
export function reconcileP12RoutePolicy(before,after,expectedVersions) {
  const failure=(failed=tables)=>({failures:failed,reconciledTables:[],changedSettingsRows:0,changedPortalRows:0,changedWindowRows:0});
  if(!before||!after||before.tablesExist!==true||after.tablesExist!==true||!Array.isArray(expectedVersions)
    ||!Array.isArray(before.appliedMigrations)||before.appliedMigrations.some(version=>typeof version!=='string')
    ||new Set(before.appliedMigrations).size!==before.appliedMigrations.length||!Array.isArray(before.targetEvents))return failure();
  const maps={};
  for(const [name,key]of [['settings','event_id'],['portals','id'],['windows','id']]) {
    const valid=row=>row!==null&&typeof row==='object'&&!Array.isArray(row)&&typeof row[key]==='string'&&row[key].length>0;
    if(!Array.isArray(before[name])||!Array.isArray(after[name])||!before[name].every(valid)||!after[name].every(valid))return failure();
    const old=new Map(before[name].map(row=>[row[key],row])),next=new Map(after[name].map(row=>[row[key],row]));
    if(old.size!==before[name].length||next.size!==after[name].length||old.size!==next.size||[...old.keys()].some(id=>!next.has(id)))return failure();
    maps[name]={old,next};
  }
  const pending=!before.appliedMigrations.includes(P12_ROUTE_POLICY_MIGRATION)&&expectedVersions.includes(P12_ROUTE_POLICY_MIGRATION);
  if(!pending) {
    for(const [index,name]of ['settings','portals','windows'].entries())for(const [id,row]of maps[name].old)
      if(!isDeepStrictEqual(row,maps[name].next.get(id)))return failure([tables[index]]);
    return {...failure([]),reconciledTables:[]};
  }
  if(!before.targetEvents.every(row=>row&&Object.keys(row).length===2&&typeof row.event_id==='string'&&row.event_id.length>0&&timestampMicros(row.close_at)!==null))return failure();
  const events=new Map(before.targetEvents.map(row=>[row.event_id,row.close_at]));
  if(events.size!==before.targetEvents.length)return failure();
  const earliest=timestampMicros(before.capturedAt),latest=timestampMicros(after.capturedAt);
  if(earliest===null||latest===null||latest<earliest)return failure();
  let migrationAt=null;
  const updatedInMigration=value=>{
    const at=timestampMicros(value);
    if(at===null||at<earliest||at>latest||(migrationAt!==null&&at!==migrationAt))return false;
    migrationAt=at;return true;
  };
  const initializing=!before.appliedMigrations.includes(JOINT_ROUTE_SETTINGS_MIGRATION)&&expectedVersions.includes(JOINT_ROUTE_SETTINGS_MIGRATION);
  const counts={changedSettingsRows:0,changedPortalRows:0,changedWindowRows:0};
  for(const [id,row]of maps.settings.old) {
    const next=maps.settings.next.get(id);
    const added=initializing&&initialColumns.every(column=>!Object.hasOwn(row,column));
    const oldBudget=added?3900:row.max_total_walking_seconds,oldVersion=added?1:row.route_policy_version;
    if(events.has(id)&&oldBudget!==4500) {
      if(oldBudget!==3900||!Number.isSafeInteger(oldVersion)||oldVersion<1||next.max_total_walking_seconds!==4500
        ||next.route_policy_version!==oldVersion+1)return failure([settingsTable]);
      const ignored=['max_total_walking_seconds','route_policy_version',...(added?initialColumns:[])];
      if(!isDeepStrictEqual(strip(row,ignored),strip(next,ignored)))return failure([settingsTable]);
      counts.changedSettingsRows++;
    } else {
      const ignored=added?initialColumns:[];
      if(!isDeepStrictEqual(strip(row,ignored),strip(next,ignored)))return failure([settingsTable]);
    }
  }
  const targetPortals=new Set();
  for(const [id,row]of maps.portals.old) {
    const next=maps.portals.next.get(id),target=events.has(row.event_id)&&row.system_code==='P-12';
    if(target)targetPortals.add(id);
    if(target&&(row.ordinary_hard_close===false||row.ordinary_end_grace_seconds!==0)) {
      if(typeof row.ordinary_hard_close!=='boolean'||!Number.isSafeInteger(row.ordinary_end_grace_seconds)
        ||!Number.isSafeInteger(row.version)||next.ordinary_hard_close!==true||next.ordinary_end_grace_seconds!==0
        ||next.version!==row.version+1||!updatedInMigration(next.updated_at)
        ||!isDeepStrictEqual(strip(row,['ordinary_hard_close','ordinary_end_grace_seconds','version','updated_at']),strip(next,['ordinary_hard_close','ordinary_end_grace_seconds','version','updated_at'])))return failure([portalsTable]);
      counts.changedPortalRows++;
    } else if(!isDeepStrictEqual(row,next))return failure([portalsTable]);
  }
  for(const [id,row]of maps.windows.old) {
    const next=maps.windows.next.get(id);
    if(targetPortals.has(row.portal_id)) {
      const closeAt=events.get(maps.portals.old.get(row.portal_id).event_id);
      const previousClose=timestampMicros(row.closes_at),hardClose=timestampMicros(closeAt);
      if(previousClose!==hardClose&&previousClose!==hardClose+600000000n)return failure([windowsTable]);
      if(!isDeepStrictEqual({...row,closes_at:closeAt},next))return failure([windowsTable]);
      if(row.closes_at!==closeAt)counts.changedWindowRows++;
    } else if(!isDeepStrictEqual(row,next))return failure([windowsTable]);
  }
  return {failures:[],reconciledTables:tables.filter((_,index)=>Object.values(counts)[index]>0),...counts};
}

// The pre-existing v3 initializer must still verify every old column and all
// four defaults. Reverse only the separately verified 75-minute overlay, so it
// never becomes a broad exception for settings.version/updated_by/other data.
export function jointRouteSettingsBeforeP12Policy(before,after,expectedVersions,settingsAfter) {
  const result=reconcileP12RoutePolicy(before,after,expectedVersions);
  if(result.failures.length||!settingsAfter||!isDeepStrictEqual(settingsAfter.rows,after.settings))return undefined;
  if(!result.changedSettingsRows)return settingsAfter;
  const original=new Map(before.settings.map(row=>[row.event_id,row]));
  const targets=new Set(before.targetEvents.map(row=>row.event_id));
  return {...settingsAfter,rows:settingsAfter.rows.map(row=>{
    const old=original.get(row.event_id);
    if(!targets.has(row.event_id)||old.max_total_walking_seconds===4500)return row;
    return {...row,max_total_walking_seconds:old.max_total_walking_seconds??3900,
      route_policy_version:old.route_policy_version??1};
  })};
}
