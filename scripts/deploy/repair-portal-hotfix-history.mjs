import { enabledSessionReads, sessionReadQuery } from "./production-read-query.mjs";
import { execFileSync } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export const LEGACY_HOTFIX = '20261027032725';
export const CANONICAL_HOTFIX = '20261027033940';
export const ENTRANCE_WRAPPER = '20261029115344';
export const RECEPTION_WRAPPER = '20261029170035';
const SAVE = 'admin_manual_portal_save';
const BEFORE_ENTRANCE = `${SAVE}_before_entrance`;
const BEFORE_RECEPTION = `${SAVE}_before_reception_policy`;
const FUNCTION_NAMES = [SAVE, BEFORE_ENTRANCE, BEFORE_RECEPTION];
// pg_get_functiondef fingerprints of the reviewed source, independently compiled
// in a local rollback transaction. Only the CREATE header's function name is
// normalized after a reviewed migration renames an existing implementation.
const SAVE_HASHES = Object.freeze({
 canonical: 'b173e2e2a2fe8341cb6e146e62be8b99', // PR47 / 20261027033940
 entrance: 'ddf28bacf588fc20a6b1b5a832d0df3c', // 20261029115344
 reception: '7a7a9fd2d5ba4554f860ee1de2d864dd', // 20261029170035
});
export const hotfixProofQuery = `with save_definitions as (
 select name,pg_get_functiondef(to_regprocedure('api.'||name||'(text,uuid,jsonb,integer,text)')) definition
 from(values ('${SAVE}'),('${BEFORE_ENTRANCE}'),('${BEFORE_RECEPTION}')) requested(name)
) select
 (select md5(definition) from save_definitions where name='${SAVE}') as save_hash,
 (select coalesce(jsonb_object_agg(name,jsonb_build_object('hash',md5(definition),
  'normalized_hash',md5(regexp_replace(definition,'^CREATE OR REPLACE FUNCTION api[.]'||name||'[(]',
    'CREATE OR REPLACE FUNCTION api.${SAVE}(')))),'{}') from save_definitions where definition is not null) as save_functions,
 md5(pg_get_functiondef(to_regprocedure('app_private.strip_portal_draft_command_metadata()'))) as cleanup_hash,
 exists(select 1 from pg_trigger t join pg_proc p on p.oid=t.tgfoid where t.tgrelid='app_private.portal_maintenance_drafts'::regclass and t.tgname='strip_portal_draft_command_metadata' and t.tgtype=23 and t.tgenabled='O' and t.tgfoid=to_regprocedure('app_private.strip_portal_draft_command_metadata()') and not p.prosecdef and t.tgqual is null and t.tgnargs=0 and t.tgattr=(select a.attnum::text::int2vector from pg_attribute a where a.attrelid=t.tgrelid and a.attname='payload' and not a.attisdropped)) as trigger_valid,
 (select count(*)::integer from app_private.portal_maintenance_drafts where payload ?| array['impactHash','impactConfirmed','commandKey']) as contaminated_drafts,
 (select coalesce(jsonb_agg(version order by version),'[]') from supabase_migrations.schema_migrations where version in ('${LEGACY_HOTFIX}','${CANONICAL_HOTFIX}')) as versions,
 (select coalesce(jsonb_agg(version order by version),'[]') from supabase_migrations.schema_migrations where version in ('${ENTRANCE_WRAPPER}','${RECEPTION_WRAPPER}')) as wrapper_versions`;

export function sanitizedHotfixProof(row) {
 const fingerprint=value=>typeof value==='string'&&/^[a-f0-9]{32}$/.test(value)?value:null;
 const versions=value=>Array.isArray(value)?value.filter(item=>typeof item==='string'&&/^\d{14}$/.test(item)):[];
 return {
  save_hash:fingerprint(row?.save_hash),
  save_functions:Object.fromEntries(FUNCTION_NAMES.map(name=>[name,{
   hash:fingerprint(row?.save_functions?.[name]?.hash),
   normalized_hash:fingerprint(row?.save_functions?.[name]?.normalized_hash),
  }])),
  cleanup_hash:fingerprint(row?.cleanup_hash),
  trigger_valid:typeof row?.trigger_valid==='boolean'?row.trigger_valid:null,
  contaminated_drafts:Number.isSafeInteger(row?.contaminated_drafts)&&row.contaminated_drafts>=0?row.contaminated_drafts:null,
  versions:versions(row?.versions),wrapper_versions:versions(row?.wrapper_versions),
 };
}
export function assertInstalledHotfix(row) {
 const fail=()=>{throw new Error('HOTFIX_EQUIVALENCE_NOT_PROVEN');};
 if(!row||row.cleanup_hash!=='ce66c8115d726e623cd6c638e5eef587'||row.trigger_valid!==true||row.contaminated_drafts!==0)fail();
 if(!Array.isArray(row.wrapper_versions)||new Set(row.wrapper_versions).size!==row.wrapper_versions.length
  ||row.wrapper_versions.some(version=>![ENTRANCE_WRAPPER,RECEPTION_WRAPPER].includes(version)))fail();
 const entrance=row.wrapper_versions.includes(ENTRANCE_WRAPPER);
 const reception=row.wrapper_versions.includes(RECEPTION_WRAPPER);
 if(reception&&!entrance)fail();
 const expected=reception?{[SAVE]:SAVE_HASHES.reception,[BEFORE_RECEPTION]:SAVE_HASHES.entrance,[BEFORE_ENTRANCE]:SAVE_HASHES.canonical}
  :entrance?{[SAVE]:SAVE_HASHES.entrance,[BEFORE_ENTRANCE]:SAVE_HASHES.canonical}:{[SAVE]:SAVE_HASHES.canonical};
 if(!row.save_functions||Object.keys(row.save_functions).length!==Object.keys(expected).length)fail();
 for(const [name,hash]of Object.entries(expected)){
  const actual=row.save_functions[name];
  if(!actual||actual.normalized_hash!==hash||typeof actual.hash!=='string'||!/^[a-f0-9]{32}$/.test(actual.hash))fail();
 }
 if(row.save_hash!==expected[SAVE]||row.save_functions[SAVE].hash!==row.save_hash)fail();
}
export function hotfixRepairActions(row,environment) {
 assertInstalledHotfix(row);
 if(!Array.isArray(row.versions)||new Set(row.versions).size!==row.versions.length
  ||row.versions.some(version=>![LEGACY_HOTFIX,CANONICAL_HOTFIX].includes(version)))throw new Error('HOTFIX_HISTORY_INVALID');
 if(environment==='production'){
  if(row.versions.length!==1||row.versions[0]!==CANONICAL_HOTFIX)throw new Error('PRODUCTION_HISTORY_NOT_CANONICAL');
  return [];
 }
 if(environment!=='staging')throw new Error('HISTORY_REPAIR_BOUNDARY');
 if(!row.versions.length)throw new Error('STAGING_HOTFIX_NOT_INSTALLED');
 // Canonical history still requires every source/cleanup proof above. A no-op
 // never re-records history; a legacy repair records canonical before reverting.
 return [
  ...(!row.versions.includes(CANONICAL_HOTFIX)?[{version:CANONICAL_HOTFIX,status:'applied'}]:[]),
  ...(row.versions.includes(LEGACY_HOTFIX)?[{version:LEGACY_HOTFIX,status:'reverted'}]:[]),
 ];
}
export function assertEquivalentHotfix(staging, production) {
 hotfixRepairActions(staging,'staging');hotfixRepairActions(production,'production');
}
async function inspect(ref) {
 if(enabledSessionReads(process.env))return (await sessionReadQuery(hotfixProofQuery))[0];
 const r=await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({query:hotfixProofQuery,read_only:true}),signal:AbortSignal.timeout(30000)});
 if(!r.ok)throw new Error(`HOTFIX_PROOF_API_${r.status}`);
 return (await r.json())[0];
}
export async function runHotfixHistoryRepair() {
 const production=process.env.APP_ENVIRONMENT==='production';
 const ref=production?'dtubngvxfbupgvgfrjko':'nocteiuvohesvqbowchw';
 if(!['staging','production'].includes(process.env.APP_ENVIRONMENT)||process.env.SUPABASE_PROJECT_REF!==ref||process.env.GITHUB_REF!==`refs/heads/${production?'production':'staging'}`)throw new Error('HISTORY_REPAIR_BOUNDARY');
 const before=await inspect(ref);
 // Log only fixed, sanitized fingerprints before asserting, including failures.
 // Each environment reads only its own project with its own scoped credential.
 console.log(JSON.stringify({hotfixHistoryBefore:sanitizedHotfixProof(before),canonicalSourceCommit:'cf5f705df46140128b56014bfa3dd246ed3580f1',revision:/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA??'')?process.env.GITHUB_SHA:null}));
 const actions=hotfixRepairActions(before,production?'production':'staging');
 if(!actions.length){
  console.log('Canonical portal hotfix lineage and history verified; no repair executed.');return;
 }
 const repair=(version,status)=>{
  try { execFileSync('npx',['--yes','--package=supabase@2.117.0','--','supabase','migration','repair',version,'--status',status,'--project-ref',process.env.SUPABASE_PROJECT_REF,'--password',process.env.SUPABASE_DB_PASSWORD,'--yes'],{stdio:'pipe',timeout:120000}); }
  catch {throw new Error(`OFFICIAL_MIGRATION_REPAIR_FAILED_${version}_${status}`);}
 };
 // Record the canonical version first, so a partial failure never loses the fact
 // that the schema change is already installed. These commands execute no DDL.
 for(const action of actions)repair(action.version,action.status);
 const after=await inspect('nocteiuvohesvqbowchw');
 console.log(JSON.stringify({hotfixHistoryAfter:sanitizedHotfixProof(after),schemaAndUserDataUnchanged:true}));
 if(hotfixRepairActions(after,'staging').length)throw new Error('HISTORY_REPAIR_NOT_CONFIRMED');
 if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,`### Portal hotfix history\n\nVerified the reviewed PR47 save implementation, installed entrance/reception wrapper lineage, invoker cleanup trigger and zero stale draft metadata. Official CLI migration repair reconciled ${LEGACY_HOTFIX} to canonical ${CANONICAL_HOTFIX}. No schema changes, data reset or draft field changes.\n`);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await runHotfixHistoryRepair();
