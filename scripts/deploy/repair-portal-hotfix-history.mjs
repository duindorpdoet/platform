import { execFileSync } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export const LEGACY_HOTFIX = '20261027032725';
export const CANONICAL_HOTFIX = '20261027033940';
export const hotfixProofQuery = `select
 md5(pg_get_functiondef('api.admin_manual_portal_save(text,uuid,jsonb,integer,text)'::regprocedure)) as save_hash,
 md5(pg_get_functiondef('app_private.strip_portal_draft_command_metadata()'::regprocedure)) as cleanup_hash,
 exists(select 1 from pg_trigger t join pg_proc p on p.oid=t.tgfoid where t.tgrelid='app_private.portal_maintenance_drafts'::regclass and t.tgname='strip_portal_draft_command_metadata' and t.tgtype=23 and t.tgenabled='O' and not p.prosecdef) as trigger_valid,
 (select count(*)::integer from app_private.portal_maintenance_drafts where payload ?| array['impactHash','impactConfirmed','commandKey']) as contaminated_drafts,
 (select coalesce(jsonb_agg(version order by version),'[]') from supabase_migrations.schema_migrations where version in ('${LEGACY_HOTFIX}','${CANONICAL_HOTFIX}')) as versions`;
export function assertEquivalentHotfix(staging, production) {
 for (const row of [staging,production]) {
  if(row.save_hash!=='b173e2e2a2fe8341cb6e146e62be8b99'||row.cleanup_hash!=='ce66c8115d726e623cd6c638e5eef587'||row.trigger_valid!==true||row.contaminated_drafts!==0) throw new Error('HOTFIX_EQUIVALENCE_NOT_PROVEN');
 }
 if(!production.versions.includes(CANONICAL_HOTFIX)||production.versions.includes(LEGACY_HOTFIX))throw new Error('PRODUCTION_HISTORY_NOT_CANONICAL');
 if(!staging.versions.length)throw new Error('STAGING_HOTFIX_NOT_INSTALLED');
}
async function inspect(ref) {
 const r=await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({query:hotfixProofQuery,read_only:true}),signal:AbortSignal.timeout(30000)});
 if(!r.ok)throw new Error(`HOTFIX_PROOF_API_${r.status}`);
 return (await r.json())[0];
}
async function main() {
 if(process.env.APP_ENVIRONMENT!=='staging'||process.env.SUPABASE_PROJECT_REF!=='nocteiuvohesvqbowchw'||process.env.GITHUB_REF!=='refs/heads/staging')throw new Error('STAGING_HISTORY_REPAIR_BOUNDARY');
 const [before,production]=await Promise.all([inspect('nocteiuvohesvqbowchw'),inspect('dtubngvxfbupgvgfrjko')]);
 assertEquivalentHotfix(before,production);
 console.log(JSON.stringify({hotfixHistoryBefore:before,productionProof:production,revision:process.env.GITHUB_SHA}));
 const repair=(version,status)=>{
  try { execFileSync('npx',['--yes','--package=supabase@2.117.0','--','supabase','migration','repair',version,'--status',status,'--project-ref',process.env.SUPABASE_PROJECT_REF,'--password',process.env.SUPABASE_DB_PASSWORD,'--yes'],{stdio:'pipe',timeout:120000}); }
  catch {throw new Error(`OFFICIAL_MIGRATION_REPAIR_FAILED_${version}_${status}`);}
 };
 // Record the canonical version first, so a partial failure never loses the fact
 // that the schema change is already installed. These commands execute no DDL.
 if(!before.versions.includes(CANONICAL_HOTFIX))repair(CANONICAL_HOTFIX,'applied');
 if(before.versions.includes(LEGACY_HOTFIX))repair(LEGACY_HOTFIX,'reverted');
 const after=await inspect('nocteiuvohesvqbowchw');
 assertEquivalentHotfix(after,production);
 if(after.versions.length!==1||after.versions[0]!==CANONICAL_HOTFIX)throw new Error('HISTORY_REPAIR_NOT_CONFIRMED');
 console.log(JSON.stringify({hotfixHistoryAfter:after,schemaAndUserDataUnchanged:true}));
 if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,`### Portal hotfix history\n\nVerified identical production/staging save function, invoker cleanup trigger and zero stale draft metadata. Official CLI migration repair reconciled ${LEGACY_HOTFIX} to canonical ${CANONICAL_HOTFIX}. No schema changes, data reset or draft field changes.\n`);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await main();
