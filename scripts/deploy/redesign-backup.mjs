import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, open, readFile, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';
import { backupKey, sealBackup } from './redesign-preflight.mjs';

const quote=value=>'"'+value.replaceAll('"','""')+'"';
const literal=value=>"'"+value.replaceAll("'","''")+"'";
const schemas=['app_private','auth','storage','supabase_migrations','vault','cron','supabase_functions','public'];
const catalogSQL=`select coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,'rls',c.relrowsecurity,
 'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)) order by n.nspname,c.relname),'[]')
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in (${schemas.map(literal).join(',')}) and c.relkind in ('r','p')`;

export function fingerprintQuery(catalog) {
  if(!catalog.length)throw new Error('EMPTY_DATABASE_INVENTORY');
  return catalog.map(table=>{
    const key=table.schema+'.'+table.name,columns=table.columns.map(c=>'t.'+quote(c)).join(',');
    return `select jsonb_build_object('table',${literal(key)},'rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) as fingerprint
      from (select encode(sha256(convert_to(to_jsonb(row(${columns}))::text,'UTF8')),'hex') h from ${quote(table.schema)}.${quote(table.name)} t) row_hashes`;
  }).join(' union all ');
}
export function compareFingerprints(before,after) {
  const current=new Map(after.map(row=>[row.table,row]));
  return before.filter(row=>{const next=current.get(row.table);return !next||row.rows!==next.rows||row.sha256!==next.sha256;}).map(row=>row.table);
}
function processCommand(command,args,env={}) {
  const child=spawn(command,args,{env:{...process.env,...env},stdio:['pipe','pipe','pipe']});
  child.stdin.on('error',()=>{});
  let errorBytes=0,firstError='';
  child.stderr.on('data',chunk=>{errorBytes+=chunk.length;if(firstError.length<2048)firstError+=chunk.toString();});
  const done=new Promise((resolve,reject)=>{
    child.once('error',()=>reject(new Error('BACKUP_TOOL_UNAVAILABLE')));
    child.once('close',code=>{
      const parameter=firstError.match(/unrecognized configuration parameter "([a-z0-9_.]+)"/i)?.[1];
      const hint=parameter?'unrecognized configuration parameter '+parameter:firstError.split(/[\r\n]/)[0].replace(/'[^']*'|"[^"]*"|https?:\/\/\S+|[A-Za-z0-9_-]{32,}/g,'[redacted]').slice(0,180);
      return code===0?resolve():reject(new Error(`BACKUP_TOOL_FAILED_${code}_${errorBytes}: ${hint}`));
    });
  });
  // Callers await this promise alongside stream completion; attach a handler
  // immediately so a failing child cannot create an unhandled rejection.
  done.catch(()=>{});
  return {child,done};
}
async function capture(command,args,input='',env={}) {
  const {child,done}=processCommand(command,args,env),chunks=[];let size=0;
  child.stdout.on('data',chunk=>{size+=chunk.length;if(size>64*1024*1024){child.kill();return;}chunks.push(chunk);});
  child.stdin.end(input);await done;
  if(size>64*1024*1024)throw new Error('PRIVATE_METADATA_TOO_LARGE');
  return Buffer.concat(chunks).toString('utf8').trim();
}
export async function encryptStream(source,filename,key,context) {
  const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,nonce);
  cipher.setAAD(Buffer.from(context));
  const output=createWriteStream(filename,{flags:'wx',mode:0o600});
  output.write(Buffer.concat([Buffer.from('DDB1'),nonce,Buffer.alloc(16)]));
  await pipeline(source,cipher,output);
  const fd=await open(filename,'r+');
  try{await fd.write(cipher.getAuthTag(),0,16,16);await fd.sync();}finally{await fd.close();}
}
async function decryptor(filename,key,context) {
  const fd=await open(filename,'r'),header=Buffer.alloc(32);
  try{await fd.read(header,0,32,0);}finally{await fd.close();}
  if(header.subarray(0,4).toString()!=='DDB1')throw new Error('INVALID_BACKUP');
  const cipher=createDecipheriv('aes-256-gcm',key,header.subarray(4,16));
  cipher.setAAD(Buffer.from(context));cipher.setAuthTag(header.subarray(16,32));
  return cipher;
}
export async function verifyBackupFile(filename,key,context) {
  const hash=createHash('sha256');let bytes=0;
  await pipeline(createReadStream(filename,{start:32}),await decryptor(filename,key,context),new Writable({write(chunk,encoding,callback){bytes+=chunk.length;hash.update(chunk);callback();}}));
  return {sha256:hash.digest('hex'),bytes};
}
async function fileDigest(filename) {
  const hash=createHash('sha256');let bytes=0;
  for await(const chunk of createReadStream(filename)){hash.update(chunk);bytes+=chunk.length;}
  return {sha256:hash.digest('hex'),bytes};
}
async function api(path,body) {
  const response=await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}${path}`,{
    method:body?'POST':'GET',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},
    ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(60000),
  });
  if(!response.ok)throw new Error(`BACKUP_API_${response.status}`);
  return response.json();
}
export async function startIsolatedRestore(image,container,rootKey) {
  if(!/^supabase\/postgres:\d+\.\d+\.\d+\.\d+$/.test(image)||!/^duindorp-restore-[a-z0-9-]+$/.test(container)||!/^([a-f0-9]{64})$/.test(rootKey))throw new Error('INVALID_ISOLATED_RESTORE_CONTEXT');
  let created=false;
  try {
    // The project root key travels only over stdin into this private tmpfs.
    // It never appears in argv, Docker configuration, logs or a plaintext file
    // on the runner disk. Cron and every outbound network remain disabled.
    const waitForKey='while [ ! -f /run/duindorp-vault/ready ]; do sleep 0.1; done; exec /usr/local/bin/docker-entrypoint.sh "$@"';
    await capture('docker',['run','--detach','--name',container,'--network','none','--tmpfs','/run/duindorp-vault:rw,exec,nosuid,nodev,size=64k,mode=0700','--env','POSTGRES_USER=supabase_admin','--env','POSTGRES_DB=postgres','--env','POSTGRES_PASSWORD='+randomBytes(32).toString('hex'),'--entrypoint','sh',image,'-c',waitForKey,'isolated-restore','postgres','-c','shared_preload_libraries=pg_stat_statements,pg_cron,pg_net,supabase_vault','-c','vault.getkey_script=/run/duindorp-vault/getkey','-c','cron.database_name=postgres','-c','cron.launch_active_jobs=off']);
    created=true;
    const installKey="umask 077; cat > /run/duindorp-vault/root.key; printf '#!/bin/sh\\ncat /run/duindorp-vault/root.key\\n' > /run/duindorp-vault/getkey; chown -R postgres:postgres /run/duindorp-vault; chmod 700 /run/duindorp-vault/getkey; chmod 600 /run/duindorp-vault/root.key; touch /run/duindorp-vault/ready";
    await capture('docker',['exec','-i',container,'sh','-c',installKey],rootKey+'\n');
    for(let attempt=0;;attempt++) {
      // Ignore the temporary Unix-socket server used during initialization.
      try{await capture('docker',['exec',container,'pg_isready','-h','127.0.0.1','-U','supabase_admin','-d','postgres']);break;}
      catch{if(attempt>=60)throw new Error('ISOLATED_POSTGRES_NOT_READY');await new Promise(resolve=>setTimeout(resolve,1000));}
    }
  } catch(error) {if(created)await capture('docker',['rm','--force',container]);throw error;}
}
const vaultFingerprint="select coalesce(jsonb_agg(jsonb_build_object('id',id,'sha256',encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex')) order by id),'[]') from vault.decrypted_secrets";
async function main() {
  const environment=process.env.APP_ENVIRONMENT,revision=process.env.GITHUB_SHA,run=process.env.GITHUB_RUN_ID;
  if(!['staging','production'].includes(environment)||!/^[a-f0-9]{40}$/.test(revision??'')||!/^\d+$/.test(run??''))throw new Error('DEPLOYMENT_CONTEXT_REQUIRED');
  if(!/^[a-z]{20}$/.test(process.env.SUPABASE_PROJECT_REF??'')||!process.env.SUPABASE_DB_PASSWORD||!process.env.SUPABASE_SERVICE_ROLE_KEY)throw new Error('PROJECT_ACCESS_REQUIRED');
  const key=backupKey(process.env.CHILD_CODE_ENCRYPTION_KEY),context=`duindorp-release-backup-v1:${environment}:${revision}:${run}:${process.env.GITHUB_RUN_ATTEMPT??'1'}`;
  const directory=join(process.env.RUNNER_TEMP,'duindorp-release-backup');
  await mkdir(directory,{recursive:true,mode:0o700});
  const save=async(name,value)=>writeFile(join(directory,name),sealBackup(Buffer.from(JSON.stringify(value)),key,context+':'+name),{flag:'wx',mode:0o600});
  const project=await api(''),poolers=await api('/config/database/pooler');
  const version=project.database?.version;
  if(!/^\d+\.\d+\.\d+\.\d+$/.test(version??''))throw new Error('POSTGRES_IMAGE_VERSION_REQUIRED');
  const pooler=poolers.find(row=>row.pool_mode==='session')??poolers.find(row=>/\.pooler\.supabase\.com$/.test(row.db_host));
  if(!pooler?.db_host||!pooler?.db_user||!pooler?.db_name)throw new Error('SESSION_POOLER_REQUIRED');
  const image='supabase/postgres:'+version;
  await capture('docker',['pull',image]);
  const poolerUser=pooler.db_user==='postgres'?'postgres.'+process.env.SUPABASE_PROJECT_REF:pooler.db_user;
  const sourceEnv={PGHOST:pooler.db_host,PGPORT:'5432',PGDATABASE:pooler.db_name,PGUSER:poolerUser,PGPASSWORD:process.env.SUPABASE_DB_PASSWORD,PGSSLMODE:'require',PGCONNECT_TIMEOUT:'30',PGOPTIONS:'-c statement_timeout=300000 -c lock_timeout=3000 -c jit=off'};
  const clientArgs=['run','--rm','-i','--network','host',...Object.keys(sourceEnv).flatMap(name=>['--env',name]),image];
  const sourceQuery=async(sql,snapshot)=>{
    const prefix="begin isolation level repeatable read read only;"+(snapshot?`set transaction snapshot ${literal(snapshot)};`:'')+"set local timezone='UTC';set local datestyle='ISO';";
    return capture('docker',[...clientArgs,'psql','-X','-qAt','-v','ON_ERROR_STOP=1'],prefix+sql+';commit;',sourceEnv);
  };
  const holder=processCommand('docker',[...clientArgs,'psql','-X','-qAt','-v','ON_ERROR_STOP=1'],sourceEnv);
  const snapshot=await new Promise((resolve,reject)=>{
    let value='';const timer=setTimeout(()=>reject(new Error('SNAPSHOT_TIMEOUT')),60000);
    holder.child.stdout.on('data',chunk=>{value+=chunk.toString();const match=value.match(/^([0-9a-f]+-[0-9a-f]+-\d+)$/im);if(match){clearTimeout(timer);resolve(match[1]);}});
    holder.done.catch(error=>{clearTimeout(timer);reject(error);});
    holder.child.stdin.write('begin isolation level repeatable read read only;select pg_catalog.pg_export_snapshot();\n');
  }).catch(error=>{holder.child.stdin.end();holder.child.kill();throw error;});
  const keepAlive=setInterval(()=>{
    if(!holder.child.stdin.destroyed&&!holder.child.stdin.writableEnded)holder.child.stdin.write('select 1;\n');
  },20000);
  const container=`duindorp-restore-${run}-${process.env.GITHUB_RUN_ATTEMPT??'1'}`;
  let localStarted=false;
  try {
    console.log('Private repeatable-read database snapshot opened.');
    const catalog=JSON.parse(await sourceQuery(catalogSQL,snapshot));
    const repositoryMigrations=(await readdir('supabase/migrations')).filter(name=>name.endsWith('.sql')).sort();
    const appliedMigrations=JSON.parse(await sourceQuery("select coalesce(jsonb_agg(version::text order by version),'[]') from supabase_migrations.schema_migrations",snapshot));
    const knownVersions=new Set(repositoryMigrations.map(name=>name.split('_')[0]));
    if(appliedMigrations.some(version=>!knownVersions.has(version))||repositoryMigrations.filter(name=>!name.startsWith('20261023')).some(name=>!appliedMigrations.includes(name.split('_')[0])))throw new Error('LIVE_MIGRATION_HISTORY_DRIFT');
    const before=(await sourceQuery(fingerprintQuery(catalog),snapshot)).split('\n').map(JSON.parse);
    const roles=JSON.parse(await sourceQuery("select jsonb_agg(jsonb_build_object('name',rolname,'inherit',rolinherit,'bypassrls',rolbypassrls,'superuser',rolsuper,'eventTriggerOwner',exists(select 1 from pg_event_trigger where evtowner=pg_roles.oid))) from pg_roles where rolname not like 'pg_%'",snapshot));
    const memberships=JSON.parse(await sourceQuery("select coalesce(jsonb_agg(jsonb_build_object('role',r.rolname,'member',m.rolname,'adminOption',a.admin_option,'inheritOption',a.inherit_option,'setOption',a.set_option)),'[]') from pg_auth_members a join pg_roles r on r.oid=a.roleid join pg_roles m on m.oid=a.member",snapshot));
    const objects=JSON.parse(await sourceQuery("select coalesce(jsonb_agg(to_jsonb(o) order by o.id),'[]') from storage.objects o",snapshot));
    const settings={project,auth:await api('/config/auth'),rest:await api('/postgrest'),backups:await api('/database/backups')};
    const vaultKey=await api('/pgsodium');
    if(!/^[a-f0-9]{64}$/.test(vaultKey.root_key??''))throw new Error('VAULT_RESTORE_KEY_REQUIRED');
    const vaultBefore=JSON.parse(await sourceQuery(vaultFingerprint,snapshot));
    await save('catalog.aes',catalog);await save('inventory.aes',before);await save('roles.aes',roles);await save('role-memberships.aes',memberships);await save('settings.aes',settings);await save('objects.aes',objects);
    await save('vault-root-key.aes',vaultKey);await save('vault-inventory.aes',vaultBefore);
    const dump=processCommand('docker',[...clientArgs,'pg_dump','--format=custom','--no-subscriptions','--lock-wait-timeout=3000',`--snapshot=${snapshot}`],sourceEnv);
    dump.child.stdin.end();
    await Promise.all([encryptStream(dump.child.stdout,join(directory,'database.aes'),key,context+':database.aes'),dump.done]);
    await verifyBackupFile(join(directory,'database.aes'),key,context+':database.aes');
    console.log('Database backup encrypted and authentication verified.');
    const objectChecks=[];
    for(let i=0;i<objects.length;i++) {
      const object=objects[i],current=JSON.parse(await sourceQuery(`select to_jsonb(o) from storage.objects o where id=${literal(object.id)}::uuid`));
      if(JSON.stringify(current)!==JSON.stringify(object))throw new Error('STORAGE_CHANGED_DURING_BACKUP');
      const name=`object-${i}.aes`,objectPath=[object.bucket_id,...object.name.split('/')].map(encodeURIComponent).join('/');
      const response=await fetch(`https://${process.env.SUPABASE_PROJECT_REF}.supabase.co/storage/v1/object/authenticated/${objectPath}`,{headers:{apikey:process.env.SUPABASE_SERVICE_ROLE_KEY,Authorization:`Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`},signal:AbortSignal.timeout(180000)});
      if(!response.ok||!response.body)throw new Error('STORAGE_BACKUP_FAILED');
      await encryptStream(Readable.fromWeb(response.body),join(directory,name),key,context+':'+name);
      const verified=await verifyBackupFile(join(directory,name),key,context+':'+name);
      if(object.metadata?.size!=null&&Number(object.metadata.size)!==verified.bytes)throw new Error('STORAGE_SIZE_MISMATCH');
      const after=JSON.parse(await sourceQuery(`select to_jsonb(o) from storage.objects o where id=${literal(object.id)}::uuid`));
      if(JSON.stringify(after)!==JSON.stringify(object))throw new Error('STORAGE_CHANGED_DURING_BACKUP');
      objectChecks.push({id:object.id,file:name,...verified});
    }
    await save('object-checks.aes',objectChecks);
    holder.child.stdin.end('commit;\n');await holder.done;
    // No network is attached to the restore database. Its cron launcher is
    // disabled, so restored jobs/messages cannot contact live services.
    await startIsolatedRestore(image,container,vaultKey.root_key);
    localStarted=true;
    const localQuery=sql=>capture('docker',['exec','-i',container,'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],"set timezone='UTC';set datestyle='ISO';"+sql+';');
    console.log('Isolated PostgreSQL version: '+await localQuery("select current_setting('server_version')"));
    console.log('Isolated preload libraries: '+await localQuery("select current_setting('shared_preload_libraries')"));
    for(const role of roles)await localQuery(`do $role$ begin if not exists(select 1 from pg_roles where rolname=${literal(role.name)}) then execute ${literal('create role '+quote(role.name)+' nologin '+(role.inherit?'inherit':'noinherit')+(role.bypassrls?' bypassrls':''))};end if;end $role$`);
    for(const membership of memberships)await localQuery('grant '+quote(membership.role)+' to '+quote(membership.member)+' with admin '+membership.adminOption+', inherit '+membership.inheritOption+', set '+membership.setOption);
    // Managed Supabase roles can own event triggers after their superuser
    // privilege has been removed. PostgreSQL requires that privilege while
    // replaying ALTER EVENT TRIGGER OWNER. Grant it only inside this networkless
    // disposable restore and return every affected role to its source setting.
    for(const role of roles.filter(role=>role.eventTriggerOwner))await localQuery('alter role '+quote(role.name)+' superuser');
    const restore=processCommand('docker',['exec','-i',container,'pg_restore','--clean','--if-exists','--exit-on-error','--no-tablespaces','--username=supabase_admin','--dbname=postgres']);
    const restoredStreams=await Promise.allSettled([pipeline(createReadStream(join(directory,'database.aes'),{start:32}),await decryptor(join(directory,'database.aes'),key,context+':database.aes'),restore.child.stdin),restore.done]);
    if(restoredStreams[1].status==='rejected')throw restoredStreams[1].reason;
    if(restoredStreams[0].status==='rejected')throw restoredStreams[0].reason;
    for(const role of roles.filter(role=>role.eventTriggerOwner&&!role.superuser))await localQuery('alter role '+quote(role.name)+' nosuperuser');
    const restored=(await localQuery(fingerprintQuery(catalog))).split('\n').map(JSON.parse);
    const restoreDifferences=compareFingerprints(before,restored);
    if(restoreDifferences.length)throw new Error('RESTORE_DATA_MISMATCH: '+restoreDifferences.join(', '));
    const vaultAfter=JSON.parse(await localQuery(vaultFingerprint));
    if(JSON.stringify(vaultBefore)!==JSON.stringify(vaultAfter))throw new Error('VAULT_RESTORE_DATA_MISMATCH');
    console.log(`Isolated restore preserved all ${catalog.length} table fingerprints.`);
    const migrations=[];
    for(const filename of (await readdir('supabase/migrations')).filter(name=>/^20261023.*\.sql$/.test(name)).sort()) {
      const sql=await readFile(join('supabase/migrations',filename),'utf8');
      const started=Date.now();await localQuery("begin;set local lock_timeout='3s';set local statement_timeout='5min';"+sql+';commit');
      migrations.push({file:filename,sha256:createHash('sha256').update(sql).digest('hex'),durationMs:Date.now()-started});
    }
    if(migrations.length!==4)throw new Error('REVIEWED_MIGRATION_SET_CHANGED');
    const migrated=(await localQuery(fingerprintQuery(catalog))).split('\n').map(JSON.parse);
    const migrationDifferences=compareFingerprints(before,migrated);
    if(migrationDifferences.length)throw new Error('MIGRATION_DATA_MISMATCH: '+migrationDifferences.join(', '));
    // Preview historical exceptions only on the restored copy. Installing the
    // migrations and producing this report never starts an automatic backfill.
    const backfillPreview=JSON.parse(await localQuery("select coalesce(jsonb_agg(jsonb_build_object('eventId',e.id,'eventSlug',e.slug,'candidates',coalesce((select jsonb_agg(to_jsonb(c)) from app_private.arrival_backfill_candidates(e.id) c),'[]'))),'[]') from app_private.events e"));
    const candidates=backfillPreview.flatMap(event=>event.candidates);
    const backfill={applied:false,candidates:candidates.length,eligible:candidates.filter(row=>row.eligible===true).length,excluded:candidates.filter(row=>row.eligible!==true).length,reasons:{}};
    for(const candidate of candidates)backfill.reasons[candidate.reason]=(backfill.reasons[candidate.reason]??0)+1;
    await save('backfill-preview.aes',backfillPreview);
    const legacyPrint=JSON.parse(await localQuery("select jsonb_build_object('activeCredentials',count(*),'hashOnly',count(*) filter(where not exists(select 1 from app_private.portal_print_material m where m.credential_id=c.id))) from app_private.portal_credentials c where c.revoked_at is null and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())"));
    const files=[];
    for(const name of (await readdir(directory)).filter(name=>name.endsWith('.aes')).sort())files.push({name,...await fileDigest(join(directory,name))});
    const proof={version:1,environment,revision,context,image,appliedMigrations,recordedAt:new Date().toISOString(),restoreVerified:true,migrationDryRunVerified:true,storageVerified:true,vaultVerified:true,vaultSecrets:vaultBefore.length,tables:catalog.length,objects:objects.length,migrations,backfill,legacyPrint,files,
      limits:['Provider runtime secrets remain in the existing secret store.','No live database configuration, migration, credential, or row was changed by this job.','Isolated SQL restore is not an Auth/mail/browser acceptance result.']};
    proof.signature=createHmac('sha256',key).update(JSON.stringify(proof)).digest('hex');
    await writeFile(join(directory,'proof.json'),JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
    console.log(JSON.stringify({backupAndRestore:'passed',environment,revision,tables:catalog.length,objects:objects.length,migrationDryRun:'passed'}));
  } finally {
    clearInterval(keepAlive);
    holder.child.stdin.end();holder.child.kill();
    if(localStarted)await capture('docker',['rm','--force',container]);
  }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(error=>{console.error(error.message);process.exitCode=1;});
