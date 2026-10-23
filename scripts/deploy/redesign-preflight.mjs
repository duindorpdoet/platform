import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

export function backupKey(secret) {
  const bytes=Buffer.from(secret??'','base64');
  if(bytes.length!==32||bytes.toString('base64')!==secret)throw new Error('BACKUP_KEY_UNAVAILABLE');
  return createHmac('sha256',bytes).update('duindorp-release-backup-v1').digest();
}
export function sealBackup(value,key,context) {
  const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,nonce);
  cipher.setAAD(Buffer.from(context));
  const encrypted=Buffer.concat([cipher.update(value),cipher.final()]);
  return Buffer.concat([Buffer.from('DDB1'),nonce,cipher.getAuthTag(),encrypted]);
}
export function openBackup(value,key,context) {
  if(value.subarray(0,4).toString()!=='DDB1')throw new Error('INVALID_BACKUP');
  const cipher=createDecipheriv('aes-256-gcm',key,value.subarray(4,16));
  cipher.setAAD(Buffer.from(context));cipher.setAuthTag(value.subarray(16,32));
  return Buffer.concat([cipher.update(value.subarray(32)),cipher.final()]);
}
async function management(path,body) {
  const response=await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}${path}`,{
    method:body?'POST':'GET',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},
    ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(60000),
  });
  if(!response.ok)throw new Error(`PREFLIGHT_API_${response.status}`);
  return response.json();
}
async function main() {
  const environment=process.env.APP_ENVIRONMENT,revision=process.env.GITHUB_SHA;
  if(!['staging','production'].includes(environment)||!/^[a-f0-9]{40}$/.test(revision??'')||!process.env.GITHUB_RUN_ID)throw new Error('DEPLOYMENT_CONTEXT_REQUIRED');
  if(!/^[a-z]{20}$/.test(process.env.SUPABASE_PROJECT_REF??'')||!process.env.SUPABASE_ACCESS_TOKEN)throw new Error('PROJECT_ACCESS_REQUIRED');
  const key=backupKey(process.env.CHILD_CODE_ENCRYPTION_KEY);
  const inventory=await management('/database/query',{read_only:true,query:`select
    pg_catalog.current_setting('server_version') as server_version,
    pg_catalog.pg_database_size(pg_catalog.current_database()) as database_bytes,
    (select pg_catalog.jsonb_agg(version order by version) from supabase_migrations.schema_migrations) as applied_migrations,
    (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('name',extname,'version',extversion)) from pg_catalog.pg_extension) as extensions,
    (select count(*) from storage.objects) as storage_object_count,
    (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(e)) from app_private.events e) as event_configuration`});
  const project=await management('');
  let backups,pooler;
  try{backups=await management('/database/backups');}catch(error){backups={unavailable:error.message};}
  try{pooler=await management('/config/database/pooler');}catch(error){pooler={unavailable:error.message};}
  const tools=Object.fromEntries(['docker','psql','pg_dump','pg_restore','pg_ctl','python3','dpkg-deb','apt-get'].map(name=>{
    const result=spawnSync('sh',['-c','command -v "$1"','probe',name],{encoding:'utf8',env:{PATH:process.env.PATH}});
    return [name,result.status===0];
  }));
  const context=`duindorp-release:${environment}:${revision}:${process.env.GITHUB_RUN_ID}`;
  const directory=join(homedir(),'.local','share','duindorp-release-backups',environment,`${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT??'1'}`);
  await mkdir(directory,{recursive:true,mode:0o700});
  const filename=join(directory,'preflight.json.aes');
  const plaintext=Buffer.from(JSON.stringify({recordedAt:new Date().toISOString(),context,inventory,project,backups,pooler}));
  await writeFile(filename,sealBackup(plaintext,key,context),{mode:0o600,flag:'wx'});
  if(!openBackup(await readFile(filename),key,context).equals(plaintext))throw new Error('ENCRYPTED_INVENTORY_VERIFICATION_FAILED');
  console.log(JSON.stringify({environment,revision,privateEncryptedInventorySaved:true,databaseVersion:project.database?.version,tools,
    backupMetadataShape:Object.keys(backups),poolerMetadataShape:Array.isArray(pooler)?pooler.map(row=>Object.keys(row)):Object.keys(pooler)}));
  // Fail closed until a complete database/object backup and isolated restore
  // have been performed. Installing this probe never authorizes migrations.
  throw new Error('BACKUP_AND_ISOLATED_RESTORE_NOT_YET_PROVEN');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  main().catch(error=>{console.error(error.message);process.exitCode=1;});
}
