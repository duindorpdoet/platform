// Read-only production inventory. Never returns row contents or credentials.
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fingerprintQuery } from './redesign-backup.mjs';

async function query(sql) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`, {
    method: 'POST', headers: {Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type':'application/json'},
    body: JSON.stringify({query:sql, read_only:true}), signal:AbortSignal.timeout(60000),
  });
  if (!response.ok) throw new Error(`BASELINE_READ_${response.status}`);
  return response.json();
}
const schemas="'app_private','api','auth','storage','supabase_migrations','vault','cron','supabase_functions','public'";
const [tables, migrations, functions, constraints, policies, indexes, jobs] = await Promise.all([
  query(`select n.nspname as schema,c.relname as name,c.relrowsecurity as rls,
    (select jsonb_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped) as columns
    from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in (${schemas}) and c.relkind in ('r','p') order by 1,2`),
  query('select version,name from supabase_migrations.schema_migrations order by version'),
  query(`select n.nspname as schema,p.proname as name,pg_get_function_identity_arguments(p.oid) as arguments,p.prosecdef as definer,p.proconfig as configuration,p.proacl::text as grants,
    encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') as sha256
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('app_private','api') and p.prokind='f' order by 1,2,3`),
  query(`select n.nspname as schema,c.relname as table_name,k.conname,pg_get_constraintdef(k.oid) as definition from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in (${schemas}) order by 1,2,3`),
  query(`select * from pg_policies where schemaname in (${schemas}) order by schemaname,tablename,policyname`),
  query(`select * from pg_indexes where schemaname in (${schemas}) order by schemaname,tablename,indexname`),
  query("select jobid,schedule,active,encode(sha256(convert_to(command,'UTF8')),'hex') as command_sha256 from cron.job order by jobid"),
]);
const fingerprints = await query(fingerprintQuery(tables));
const directory=join(process.env.RUNNER_TEMP ?? '/tmp','duindorp-evening-baseline');
await mkdir(directory,{recursive:true,mode:0o700});
await writeFile(join(directory,'baseline.json'),JSON.stringify({capturedAt:new Date().toISOString(),revision:process.env.GITHUB_SHA,tables,migrations,functions,constraints,policies,indexes,jobs,fingerprints},null,2),{mode:0o600});
console.log(JSON.stringify({readOnly:true,tables:tables.length,migrations:migrations.length,functions:functions.length,latestMigration:migrations.at(-1)?.version}));
