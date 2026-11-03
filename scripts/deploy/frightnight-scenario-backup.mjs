import { createHash } from 'node:crypto';
import { assertFrightnightRelease } from './frightnight-release.mjs';

const slug='frightnight-2027-test';
export function scenarioBackupEnabled(env) {
  if(env.FRIGHTNIGHT_SCENARIO_BACKUP===undefined||env.FRIGHTNIGHT_SCENARIO_BACKUP==='false')return false;
  if(env.FRIGHTNIGHT_SCENARIO_BACKUP!=='true')throw new Error('INVALID_FRIGHTNIGHT_SCENARIO_BACKUP_MODE');
  assertFrightnightRelease(env);
  if((env.RELEASE_BACKUP_MODE??'all')!=='all'||!/^[a-f0-9]{40}$/.test(env.GITHUB_SHA??'')||env.FRIGHTNIGHT_VERIFIED_RELEASE_SHA!==env.GITHUB_SHA)throw new Error('VERIFIED_FULL_SCENARIO_BACKUP_REQUIRED');
  return true;
}
const quote=value=>'"'+value.replaceAll('"','""')+'"';
export function scenarioBackupQuery(catalog) {
  const tables=catalog.filter(table=>table.schema==='app_private'&&/^fn_[a-z_]+$/.test(table.name)).sort((a,b)=>a.name.localeCompare(b.name));
  if(tables.length!==30||tables.some(table=>!table.columns.includes('event_id'))||!['fn_events','fn_registrations','fn_zones','fn_orders','fn_mail_sink','fn_quests','fn_activities'].every(name=>tables.some(table=>table.name===name)))throw new Error('FRIGHTNIGHT_SCENARIO_CATALOG_INCOMPLETE');
  const rows=tables.map(table=>`select jsonb_build_object('table','app_private.${table.name}','rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) item from
   (select encode(sha256(convert_to(to_jsonb(row(${table.columns.map(column=>'t.'+quote(column)).join(',')}))::text,'UTF8')),'hex') h from app_private.${quote(table.name)} t where t.event_id=(select id from app_private.events where slug='${slug}')) hashes`).join(' union all ');
  return `set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;
   select jsonb_build_object('slug',e.slug,'date',e.local_date,'timezone',e.timezone,'environment',f.environment,'isTest',f.is_test,'seedVersion',f.seed_version,'closed',f.closed,
    'bindingDigest',encode(sha256(convert_to(e.id::text||':'||f.run_id::text,'UTF8')),'hex'),
    'unsafeSink',(select count(*) from app_private.fn_mail_sink m where m.event_id=e.id and (m.delivery_mode<>'sink' or m.environment<>'staging')),
    'tables',(select jsonb_agg(item order by item->>'table') from (${rows}) scoped)) as frightnight_scenario
   from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug='${slug}'`;
}
export function assertScenarioSnapshot(value) {
  if(!value||value.slug!==slug||value.date!=='2027-10-30'||value.timezone!=='Europe/Amsterdam'||value.environment!=='staging'||value.isTest!==true||value.closed!==false||!Number.isSafeInteger(value.seedVersion)||value.seedVersion<1||value.unsafeSink!==0||!/^[a-f0-9]{64}$/.test(value.bindingDigest??''))throw new Error('ACTIVE_FRIGHTNIGHT_SCENARIO_REQUIRED');
  if(!Array.isArray(value.tables)||value.tables.length!==30||new Set(value.tables.map(row=>row.table)).size!==30||value.tables.some(row=>!/^app_private\.fn_[a-z_]+$/.test(row.table)||!Number.isSafeInteger(row.rows)||row.rows<0||!/^[a-f0-9]{64}$/.test(row.sha256)))throw new Error('FRIGHTNIGHT_SCENARIO_FINGERPRINTS_REQUIRED');
  const counts=Object.fromEntries(value.tables.map(row=>[row.table,row.rows]));
  if(counts['app_private.fn_events']!==1||[['fn_registrations',4],['fn_zones',5],['fn_quests',6],['fn_activities',2]].some(([name,minimum])=>(counts['app_private.'+name]??-1)<minimum))throw new Error('SEEDED_FRIGHTNIGHT_SCENARIO_REQUIRED');
  return value;
}
export function compareScenarioRestore(before,after) {
  assertScenarioSnapshot(before);assertScenarioSnapshot(after);
  if(JSON.stringify(before)!==JSON.stringify(after))throw new Error('FRIGHTNIGHT_SCENARIO_RESTORE_MISMATCH');
  return {slug:before.slug,seedVersion:before.seedVersion,tables:before.tables.length,registrations:before.tables.find(row=>row.table==='app_private.fn_registrations').rows,zones:before.tables.find(row=>row.table==='app_private.fn_zones').rows,sha256:createHash('sha256').update(JSON.stringify(before)).digest('hex'),restoreVerified:true};
}
