import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, open, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';
import { REVIEWED_RELEASE_MIGRATIONS,reviewedRepositoryMigrations,assertReviewedReleaseMigrations } from './release-migrations.mjs';
import { installedStagingHistory } from './staging-installed-history.mjs';
import { backupKey, sealBackup, openBackup } from './redesign-preflight.mjs';
import { reconcileWorldPolicyInitialization,worldPolicyInitializationQuery } from './world-policy-reconciliation.mjs';
import { jointRoutePolicyReleaseQuery,reconcileJointRoutePolicyRelease } from './joint-route-policy-reconciliation.mjs';
import { jointRouteSettingsInitializationQuery,reconcileJointRouteSettingsInitialization } from './joint-route-settings-reconciliation.mjs';
import { p12RoutePolicyQuery,reconcileP12RoutePolicy,jointRouteSettingsBeforeP12Policy } from './p12-route-policy-reconciliation.mjs';

const quote=value=>'"'+value.replaceAll('"','""')+'"';
const literal=value=>"'"+value.replaceAll("'","''")+"'";
const schemas=['app_private','auth','storage','supabase_migrations','vault','cron','supabase_functions','public'];
const catalogSQL=`select coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,'rls',c.relrowsecurity,
 'columns',(select jsonb_agg(a.attname order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)) order by n.nspname,c.relname),'[]')
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in (${schemas.map(literal).join(',')}) and c.relkind in ('r','p')`;

// Pooler startup options are not a substitute for transaction-local policy.
// Preserve one exported MVCC snapshot and the existing administrative bounds.
export function sourceReadPrefix(snapshot) {
  if(snapshot!==undefined&&!/^[0-9a-f]+-[0-9a-f]+-\d+$/i.test(snapshot))throw new Error('INVALID_BACKUP_SNAPSHOT');
  return "begin isolation level repeatable read read only;"+(snapshot?`set transaction snapshot ${literal(snapshot)};`:'')+
    "set local statement_timeout='5min';set local lock_timeout='3s';set local jit=off;set local timezone='UTC';set local datestyle='ISO';";
}
const sourceReadPhases=new Set(['snapshot-export','catalog','migration-history','preservation','roles','role-memberships','storage-objects','vault-fingerprint','storage-before','storage-after']);
export async function withSourceReadPhase(phase,read,report=value=>console.log(JSON.stringify(value)),now=()=>performance.now()) {
  if(!sourceReadPhases.has(phase))throw new Error('INVALID_BACKUP_READ_PHASE');
  const started=now();report({backupRead:phase,status:'started'});
  try {
    const result=await read();report({backupRead:phase,status:'passed',durationMs:Math.round(now()-started)});return result;
  } catch(error) {
    report({backupRead:phase,status:'failed',durationMs:Math.round(now()-started)});throw error;
  }
}

export async function dryRunReleaseMigrations(files,appliedVersions,localQuery) {
  assertReviewedReleaseMigrations(files);
  const applied=new Set(appliedVersions),proof=[];
  for(const file of files) {
    const sql=await readFile(join('supabase/migrations',file),'utf8');
    const alreadyApplied=applied.has(file.split('_')[0]),started=Date.now();
    // Hosted CLI migrations use postgres. The restore connection is the
    // isolated superuser, but CREATE OR REPLACE retains restored ownership:
    // creating new private helpers as that superuser would break their callers.
    if(!alreadyApplied)await localQuery("begin;set local role postgres;set local lock_timeout='3s';set local statement_timeout='5min';"+sql+';commit');
    proof.push({file,sha256:createHash('sha256').update(sql).digest('hex'),execution:alreadyApplied?'already-applied':'dry-run',durationMs:Date.now()-started});
  }
  return proof;
}


export function fingerprintQuery(catalog) {
  if(!catalog.length)throw new Error('EMPTY_DATABASE_INVENTORY');
  // Point/geometric JSON uses extra_float_digits. Managed roles can default
  // to rounded output (0), while an isolated restore defaults to precise (1).
  // Compare the same full-precision representation in a transaction on both
  // sides; never round away a real coordinate change or alter role defaults.
  return "set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;"+catalog.map(table=>{
    const key=table.schema+'.'+table.name,columns=table.columns.map(c=>'t.'+quote(c)).join(',');
    return `select jsonb_build_object('table',${literal(key)},'rows',count(*),'sha256',encode(sha256(convert_to(coalesce(string_agg(h,'' order by h),''),'UTF8')),'hex')) as fingerprint
      from (select encode(sha256(convert_to(to_jsonb(row(${columns}))::text,'UTF8')),'hex') h from ${quote(table.schema)}.${quote(table.name)} t) row_hashes`;
  }).join(' union all ');
}
// Fingerprints and the narrowly reviewed append baseline must share one SQL
// statement snapshot. Separate requests could otherwise miss an intervening audit.
export function preservationQuery(catalog,coverageBefore) {
  const session="set local timezone='UTC';set local datestyle='ISO';set local extra_float_digits=3;";
  const fingerprints=fingerprintQuery(catalog);
  const coverage=worldPolicyInitializationQuery(coverageBefore);
  const routePolicy=jointRoutePolicyReleaseQuery(catalog);
  const routeSettings=jointRouteSettingsInitializationQuery(catalog);
  const p12Policy=p12RoutePolicyQuery(catalog);
  if(!fingerprints.startsWith(session)||!coverage.startsWith(session))throw new Error('PRESERVATION_QUERY_SESSION_REQUIRED');
  return session+`with coverage as (${coverage.slice(session.length)}),route_policy as (${routePolicy}),route_settings as (${routeSettings}),p12_policy as (${p12Policy}) select jsonb_build_object(
    'rows',(select jsonb_agg(fingerprint) from (${fingerprints.slice(session.length)}) fingerprints),
    'worldPolicyInitialization',(select coverage_initialization from coverage),
    'jointRoutePolicyRelease',(select joint_route_policy_release from route_policy),
    'jointRouteSettingsInitialization',(select joint_route_settings_initialization from route_settings),
    'p12RoutePolicy',(select p12_route_policy from p12_policy)) as preservation`;
}
// Management's read_only role cannot execute the existing private location
// helper. Use the deployment owner for this fixed inspection only, while
// PostgreSQL itself rejects writes and SET LOCAL cannot leak into the pool.
function ownerReadOnlyRequest(query) {
  return {read_only:false,query:"begin read only;set local statement_timeout='5min';set local lock_timeout='3s';"+
    "do $preservation_read_only$begin if current_setting('transaction_read_only')<>'on' then raise exception 'PRESERVATION_READ_ONLY_REQUIRED';end if;end $preservation_read_only$;"+
    query+';commit;'};
}
export function preservationManagementRequest(catalog,coverageBefore) {
  return ownerReadOnlyRequest(preservationQuery(catalog,coverageBefore));
}
export function fingerprintManagementRequest(catalog) {
  return ownerReadOnlyRequest(fingerprintQuery(catalog));
}
export function compareFingerprints(before,after) {
  const current=new Map(after.map(row=>[row.table,row]));
  return before.filter(row=>{const next=current.get(row.table);return !next||row.rows!==next.rows||row.sha256!==next.sha256;}).map(row=>row.table);
}
function processCommand(command,args,env={},inheritEnvironment=true) {
  const child=spawn(command,args,{env:inheritEnvironment?{...process.env,...env}:env,stdio:['pipe','pipe','pipe']});
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
async function capture(command,args,input='',env={},inheritEnvironment=true) {
  const {child,done}=processCommand(command,args,env,inheritEnvironment),chunks=[];let size=0;
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
async function api(env,request,path,body) {
  const response=await request(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_REF}${path}`,{
    method:body?'POST':'GET',headers:{Authorization:`Bearer ${env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},
    ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(60000),
  });
  if(!response.ok)throw new Error(`BACKUP_API_${response.status}`);
  return response.json();
}
export async function startIsolatedRestore(image,container,rootKey,execute=capture) {
  if(!/^supabase\/postgres:\d+\.\d+\.\d+\.\d+$/.test(image)||!/^duindorp-restore-[a-z0-9-]+$/.test(container)||!/^([a-f0-9]{64})$/.test(rootKey))throw new Error('INVALID_ISOLATED_RESTORE_CONTEXT');
  let created=false;
  try {
    // The project root key travels only over stdin into this private tmpfs.
    // It never appears in argv, Docker configuration, logs or a plaintext file
    // on the runner disk. Cron and every outbound network remain disabled.
    const waitForKey='while [ ! -f /run/duindorp-vault/ready ]; do sleep 0.1; done; exec /usr/local/bin/docker-entrypoint.sh "$@"';
    await execute('docker',['run','--detach','--name',container,'--network','none','--tmpfs','/run/duindorp-vault:rw,exec,nosuid,nodev,size=64k,mode=0700','--env','POSTGRES_USER=supabase_admin','--env','POSTGRES_DB=postgres','--env','POSTGRES_PASSWORD='+randomBytes(32).toString('hex'),'--entrypoint','sh',image,'-c',waitForKey,'isolated-restore','postgres','-c','shared_preload_libraries=pg_stat_statements,pg_cron,pg_net,supabase_vault','-c','vault.getkey_script=/run/duindorp-vault/getkey','-c','cron.database_name=postgres','-c','cron.launch_active_jobs=off']);
    created=true;
    const installKey="umask 077; cat > /run/duindorp-vault/root.key; printf '#!/bin/sh\\ncat /run/duindorp-vault/root.key\\n' > /run/duindorp-vault/getkey; chown -R postgres:postgres /run/duindorp-vault; chmod 700 /run/duindorp-vault/getkey; chmod 600 /run/duindorp-vault/root.key; touch /run/duindorp-vault/ready";
    await execute('docker',['exec','-i',container,'sh','-c',installKey],rootKey+'\n');
    for(let attempt=0;;attempt++) {
      // Ignore the temporary Unix-socket server used during initialization.
      try{await execute('docker',['exec',container,'pg_isready','-h','127.0.0.1','-U','supabase_admin','-d','postgres']);break;}
      catch{if(attempt>=60)throw new Error('ISOLATED_POSTGRES_NOT_READY');await new Promise(resolve=>setTimeout(resolve,1000));}
    }
  } catch(error) {if(created)await execute('docker',['rm','--force',container]);throw error;}
}
const vaultFingerprint="select coalesce(jsonb_agg(jsonb_build_object('id',id,'sha256',encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex')) order by id),'[]') from vault.decrypted_secrets";
const sourceExportKind='duindorp-release-source-export-v1';
const sourceMetadataFiles=['catalog.aes','inventory.aes','roles.aes','role-memberships.aes','settings.aes','objects.aes','vault-root-key.aes','vault-inventory.aes','database.aes','object-checks.aes','source-state.aes'];
async function migrationDigests(files) {
  assertReviewedReleaseMigrations(files);
  return Promise.all(files.map(async file=>({file,sha256:createHash('sha256').update(await readFile(join('supabase/migrations',file))).digest('hex')})));
}
function sourceSignature(value,key) {
  return createHmac('sha256',key).update(sourceExportKind+'\0').update(JSON.stringify(value)).digest();
}
async function writeSourceExport({env,key,context,directory,save,environment,revision},source) {
  const {image,appliedMigrations,reviewedMigrations,coverageBefore,routePolicyBefore,routeSettingsBefore,p12PolicyBefore}=source;
  await save('source-state.aes',{image,appliedMigrations,reviewedMigrations,coverageBefore,routePolicyBefore,routeSettingsBefore,p12PolicyBefore});
  const files=[];
  for(const name of (await readdir(directory)).filter(name=>name.endsWith('.aes')).sort())files.push({name,...await fileDigest(join(directory,name))});
  const proof={version:1,kind:sourceExportKind,environment,revision,context,projectRef:env.SUPABASE_PROJECT_REF,image,
    sourceExportVerified:true,restoreVerified:false,migrationDryRunVerified:false,tables:source.catalog.length,objects:source.objects.length,
    appliedMigrations,migrations:await migrationDigests(reviewedMigrations),files};
  proof.signature=sourceSignature(proof,key).toString('hex');
  await writeFile(join(directory,'source-export.json'),JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
}
async function readSourceExport({env,key,context,directory,environment,revision}) {
  const entries=await readdir(directory);
  if(entries.includes('proof.json'))throw new Error('SOURCE_EXPORT_ALREADY_RESTORED');
  const signed=JSON.parse(await readFile(join(directory,'source-export.json'),'utf8'));
  const {signature,...proof}=signed,expected=sourceSignature(proof,key);
  if(!/^[a-f0-9]{64}$/.test(signature??'')||!timingSafeEqual(expected,Buffer.from(signature,'hex')))throw new Error('INVALID_SOURCE_EXPORT_SIGNATURE');
  if(proof.version!==1||proof.kind!==sourceExportKind||proof.environment!==environment||proof.revision!==revision||proof.context!==context
    ||proof.projectRef!==env.SUPABASE_PROJECT_REF||proof.sourceExportVerified!==true||proof.restoreVerified!==false||proof.migrationDryRunVerified!==false
    ||!/^supabase\/postgres:\d+\.\d+\.\d+\.\d+$/.test(proof.image??'')
    ||!Number.isSafeInteger(proof.tables)||proof.tables<1||!Number.isSafeInteger(proof.objects)||proof.objects<0
    ||!Array.isArray(proof.files)||!Array.isArray(proof.appliedMigrations)||proof.appliedMigrations.some(v=>typeof v!=='string'||!/^\d+$/.test(v))
    ||!Array.isArray(proof.migrations))throw new Error('SOURCE_EXPORT_CONTEXT_MISMATCH');
  const names=[...sourceMetadataFiles,...Array.from({length:proof.objects},(_,i)=>`object-${i}.aes`)].sort();
  if(proof.files.length!==names.length||entries.length!==names.length+1||entries.filter(n=>n!=='source-export.json').sort().some((n,i)=>n!==names[i])
    ||proof.files.map(file=>file.name).sort().some((name,i)=>name!==names[i]))throw new Error('SOURCE_EXPORT_FILE_SET_MISMATCH');
  const verified=new Map();
  for(const file of proof.files) {
    if(!/^[a-z0-9.-]+\.aes$/.test(file.name)||!/^[a-f0-9]{64}$/.test(file.sha256??'')||!Number.isSafeInteger(file.bytes)||file.bytes<32)throw new Error('INVALID_SOURCE_EXPORT_FILE');
    const digest=await fileDigest(join(directory,file.name));
    if(digest.sha256!==file.sha256||digest.bytes!==file.bytes)throw new Error('SOURCE_EXPORT_FILE_DIGEST_MISMATCH');
    verified.set(file.name,await verifyBackupFile(join(directory,file.name),key,context+':'+file.name));
  }
  const value=async name=>JSON.parse(openBackup(await readFile(join(directory,name)),key,context+':'+name).toString('utf8'));
  const source=await value('source-state.aes');
  const digests=await migrationDigests(source.reviewedMigrations);
  if(JSON.stringify(proof.migrations)!==JSON.stringify(digests)||JSON.stringify(proof.appliedMigrations)!==JSON.stringify(source.appliedMigrations)||source.image!==proof.image)throw new Error('SOURCE_EXPORT_MIGRATION_MISMATCH');
  for(const [field,name] of Object.entries({catalog:'catalog.aes',before:'inventory.aes',roles:'roles.aes',memberships:'role-memberships.aes',objects:'objects.aes',vaultKey:'vault-root-key.aes',vaultBefore:'vault-inventory.aes'}))source[field]=await value(name);
  if(!Array.isArray(source.catalog)||source.catalog.length!==proof.tables||!Array.isArray(source.before)||source.before.length!==proof.tables
    ||!Array.isArray(source.roles)||!Array.isArray(source.memberships)||!Array.isArray(source.objects)||source.objects.length!==proof.objects
    ||!Array.isArray(source.vaultBefore)||!/^[a-f0-9]{64}$/.test(source.vaultKey?.root_key??''))throw new Error('SOURCE_EXPORT_INVENTORY_MISMATCH');
  const objects=await value('object-checks.aes');
  if(!Array.isArray(objects)||objects.length!==source.objects.length)throw new Error('SOURCE_EXPORT_OBJECT_MISMATCH');
  for(let i=0;i<objects.length;i++) {
    const object=source.objects[i],check=objects[i],actual=verified.get(`object-${i}.aes`);
    if(check.id!==object.id||check.file!==`object-${i}.aes`||check.sha256!==actual.sha256||check.bytes!==actual.bytes
      ||(object.metadata?.size!=null&&Number(object.metadata.size)!==actual.bytes))throw new Error('SOURCE_EXPORT_OBJECT_MISMATCH');
  }
  return source;
}

export async function runReleaseBackup(env=process.env,dependencies={}) {
  const mode=env.RELEASE_BACKUP_MODE??'all';
  if(!['all','export','restore'].includes(mode))throw new Error('INVALID_RELEASE_BACKUP_MODE');
  if(env.RELEASE_READ_TRANSPORT&&!['session-pooler','direct'].includes(env.RELEASE_READ_TRANSPORT))throw new Error('INVALID_RELEASE_BACKUP_TRANSPORT');
  const environment=env.APP_ENVIRONMENT,revision=env.GITHUB_SHA,run=env.GITHUB_RUN_ID;
  if(!['staging','production'].includes(environment)||!/^[a-f0-9]{40}$/.test(revision??'')||!/^\d+$/.test(run??''))throw new Error('DEPLOYMENT_CONTEXT_REQUIRED');
  if(!/^[a-z]{20}$/.test(env.SUPABASE_PROJECT_REF??''))throw new Error('PROJECT_ACCESS_REQUIRED');
  if(!/^\d+$/.test(env.GITHUB_RUN_ATTEMPT??'1'))throw new Error('DEPLOYMENT_CONTEXT_REQUIRED');
  const key=backupKey(env.CHILD_CODE_ENCRYPTION_KEY),context=`duindorp-release-backup-v1:${environment}:${revision}:${run}:${env.GITHUB_RUN_ATTEMPT??'1'}`;
  const directory=join(env.RUNNER_TEMP,'duindorp-release-backup');
  await mkdir(directory,{recursive:true,mode:0o700});
  const save=async(name,value)=>writeFile(join(directory,name),sealBackup(Buffer.from(JSON.stringify(value)),key,context+':'+name),{flag:'wx',mode:0o600});
  const request=dependencies.request??fetch,captureCommand=dependencies.captureCommand??capture,spawnCommand=dependencies.processCommand??processCommand;
  const startRestore=dependencies.startRestore??startIsolatedRestore;
  const apiCall=(path,body)=>api(env,request,path,body);
  if(mode!=='restore'&&(!env.SUPABASE_DB_PASSWORD||!env.SUPABASE_SERVICE_ROLE_KEY||!env.SUPABASE_ACCESS_TOKEN))throw new Error('PROJECT_ACCESS_REQUIRED');
  const state={env,key,context,directory,save,request,captureCommand,spawnCommand,startRestore,apiCall,environment,revision};
  const source=mode==='restore'?await readSourceExport(state):await exportSource(state);
  if(mode==='export') {
    await writeSourceExport(state,source);
    console.log(JSON.stringify({sourceBackupExport:'passed',restoreVerified:false,environment,revision,tables:source.catalog.length,objects:source.objects.length}));
    return;
  }
  if(mode==='restore')await captureCommand('docker',['pull',source.image]);
  await restoreSource(state,source);
}

async function exportSource({env,key,context,directory,save,request,captureCommand,spawnCommand,apiCall}) {
  const project=await apiCall('');
  const version=project.database?.version;
  if(!/^\d+\.\d+\.\d+\.\d+$/.test(version??''))throw new Error('POSTGRES_IMAGE_VERSION_REQUIRED');
  const image='supabase/postgres:'+version;
  let sourceEnv,sourceClient,caDirectory;
  try {
    if(env.RELEASE_READ_TRANSPORT==='direct') {
      const {adminDatabasePlan,publicReleaseCaBundle}=await import('./production-read-query.mjs');
      const {validatePortablePostgresClient}=await import('./portable-postgres-clients.mjs');
      const config=await adminDatabasePlan(env,project);
      if(!env.RELEASE_PG_CLIENT_DIRECTORY)throw new Error('PORTABLE_POSTGRES_CLIENT_DIRECTORY_REQUIRED');
      const tools=await validatePortablePostgresClient(env.RELEASE_PG_CLIENT_DIRECTORY);
      if(tools.version!==version.split('.').slice(0,2).join('.'))throw new Error('PORTABLE_POSTGRES_CLIENT_VERSION_MISMATCH');
      caDirectory=await mkdtemp(join(env.RUNNER_TEMP,'duindorp-source-client-ca-'));
      const ca=join(caDirectory,'roots.crt');
      await writeFile(ca,publicReleaseCaBundle(),{flag:'wx',mode:0o600});
      // Native libpq must never merge ambient endpoint/service/TLS settings.
      // A private empty HOME also prevents default client certificates or
      // service files in the runner account from changing this fixed plan.
      sourceEnv={PATH:process.env.PATH,LANG:'C',LC_ALL:'C',HOME:caDirectory,
        PGSERVICE:'',PGSERVICEFILE:'',PGPASSFILE:'',PGHOSTADDR:'',PGSSLCERT:'',PGSSLKEY:'',PGSSLPASSWORD:'',PGGSSENCMODE:'disable',
        PGHOST:config.host,PGPORT:String(config.port),PGDATABASE:config.database,PGUSER:config.user,PGPASSWORD:config.password,
        PGSSLMODE:'verify-full',PGSSLROOTCERT:ca,PGCONNECT_TIMEOUT:'30',PGOPTIONS:'-c statement_timeout=300000 -c lock_timeout=3000 -c jit=off'};
      sourceClient=tool=>({command:tool==='psql'?tools.psql:tools.pgDump,args:[]});
    } else {
      const poolers=await apiCall('/config/database/pooler');
      const pooler=poolers.find(row=>row.pool_mode==='session')??poolers.find(row=>/\.pooler\.supabase\.com$/.test(row.db_host));
      if(!pooler?.db_host||!pooler?.db_user||!pooler?.db_name)throw new Error('SESSION_POOLER_REQUIRED');
      await captureCommand('docker',['pull',image]);
      const poolerUser=pooler.db_user==='postgres'?'postgres.'+env.SUPABASE_PROJECT_REF:pooler.db_user;
      sourceEnv={PGHOST:pooler.db_host,PGPORT:'5432',PGDATABASE:pooler.db_name,PGUSER:poolerUser,PGPASSWORD:env.SUPABASE_DB_PASSWORD,PGSSLMODE:'require',PGCONNECT_TIMEOUT:'30',PGOPTIONS:'-c statement_timeout=300000 -c lock_timeout=3000 -c jit=off'};
      const clientArgs=['run','--rm','-i','--network','host',...Object.keys(sourceEnv).flatMap(name=>['--env',name]),image];
      sourceClient=tool=>({command:'docker',args:[...clientArgs,tool]});
    }
    const psql=sourceClient('psql'),dumpClient=sourceClient('pg_dump'),inheritSourceEnvironment=env.RELEASE_READ_TRANSPORT!=='direct';
  const sourceQuery=(phase,sql,snapshot)=>withSourceReadPhase(phase,()=>
    captureCommand(psql.command,[...psql.args,'-X','-qAt','-v','ON_ERROR_STOP=1'],sourceReadPrefix(snapshot)+sql+';commit;',sourceEnv,inheritSourceEnvironment));
  const holder=spawnCommand(psql.command,[...psql.args,'-X','-qAt','-v','ON_ERROR_STOP=1'],sourceEnv,inheritSourceEnvironment);
  const snapshot=await withSourceReadPhase('snapshot-export',()=>new Promise((resolve,reject)=>{
    let value='';const timer=setTimeout(()=>reject(new Error('SNAPSHOT_TIMEOUT')),60000);
    holder.child.stdout.on('data',chunk=>{value+=chunk.toString();const match=value.match(/^([0-9a-f]+-[0-9a-f]+-\d+)$/im);if(match){clearTimeout(timer);resolve(match[1]);}});
    holder.done.catch(error=>{clearTimeout(timer);reject(error);});
    holder.child.stdin.write(sourceReadPrefix()+'select pg_catalog.pg_export_snapshot();\n');
  })).catch(error=>{holder.child.stdin.end();holder.child.kill();throw error;});
  const keepAlive=setInterval(()=>{
    if(!holder.child.stdin.destroyed&&!holder.child.stdin.writableEnded)holder.child.stdin.write('select 1;\n');
  },20000);
  try {
    console.log('Private repeatable-read database snapshot opened.');
    const catalog=JSON.parse(await sourceQuery('catalog',catalogSQL,snapshot));
    const repositoryMigrations=(await readdir('supabase/migrations')).filter(name=>name.endsWith('.sql')).sort();
    const reviewedMigrations=reviewedRepositoryMigrations(repositoryMigrations);
    const reviewedSet=new Set(reviewedMigrations);
    const appliedMigrations=JSON.parse(await sourceQuery('migration-history',"select coalesce(jsonb_agg(version::text order by version),'[]') from supabase_migrations.schema_migrations",snapshot));
    const knownVersions=new Set([...repositoryMigrations,...installedStagingHistory()].map(name=>name.split('_')[0]));
    if(appliedMigrations.some(version=>!knownVersions.has(version))||repositoryMigrations.filter(name=>!reviewedSet.has(name)).some(name=>!appliedMigrations.includes(name.split('_')[0])))throw new Error('LIVE_MIGRATION_HISTORY_DRIFT');
    const preservationBefore=JSON.parse(await sourceQuery('preservation',preservationQuery(catalog),snapshot));
    const before=preservationBefore.rows,coverageBefore=preservationBefore.worldPolicyInitialization,routePolicyBefore=preservationBefore.jointRoutePolicyRelease,routeSettingsBefore=preservationBefore.jointRouteSettingsInitialization,p12PolicyBefore=preservationBefore.p12RoutePolicy;
    const roles=JSON.parse(await sourceQuery('roles',"select jsonb_agg(jsonb_build_object('name',rolname,'inherit',rolinherit,'bypassrls',rolbypassrls,'superuser',rolsuper,'eventTriggerOwner',exists(select 1 from pg_event_trigger where evtowner=pg_roles.oid))) from pg_roles where rolname not like 'pg_%'",snapshot));
    const memberships=JSON.parse(await sourceQuery('role-memberships',"select coalesce(jsonb_agg(jsonb_build_object('role',r.rolname,'member',m.rolname,'adminOption',a.admin_option,'inheritOption',a.inherit_option,'setOption',a.set_option)),'[]') from pg_auth_members a join pg_roles r on r.oid=a.roleid join pg_roles m on m.oid=a.member",snapshot));
    const objects=JSON.parse(await sourceQuery('storage-objects',"select coalesce(jsonb_agg(to_jsonb(o) order by o.id),'[]') from storage.objects o",snapshot));
    const settings={project,auth:await apiCall('/config/auth'),rest:await apiCall('/postgrest'),backups:await apiCall('/database/backups')};
    const vaultKey=await apiCall('/pgsodium');
    if(!/^[a-f0-9]{64}$/.test(vaultKey.root_key??''))throw new Error('VAULT_RESTORE_KEY_REQUIRED');
    const vaultBefore=JSON.parse(await sourceQuery('vault-fingerprint',vaultFingerprint,snapshot));
    await save('catalog.aes',catalog);await save('inventory.aes',before);await save('roles.aes',roles);await save('role-memberships.aes',memberships);await save('settings.aes',settings);await save('objects.aes',objects);
    await save('vault-root-key.aes',vaultKey);await save('vault-inventory.aes',vaultBefore);
    const dump=spawnCommand(dumpClient.command,[...dumpClient.args,'--format=custom','--no-subscriptions','--lock-wait-timeout=3000',`--snapshot=${snapshot}`],sourceEnv,inheritSourceEnvironment);
    dump.child.stdin.end();
    await Promise.all([encryptStream(dump.child.stdout,join(directory,'database.aes'),key,context+':database.aes'),dump.done]);
    await verifyBackupFile(join(directory,'database.aes'),key,context+':database.aes');
    console.log('Database backup encrypted and authentication verified.');
    const objectChecks=[];
    for(let i=0;i<objects.length;i++) {
      const object=objects[i],current=JSON.parse(await sourceQuery('storage-before',`select to_jsonb(o) from storage.objects o where id=${literal(object.id)}::uuid`));
      if(JSON.stringify(current)!==JSON.stringify(object))throw new Error('STORAGE_CHANGED_DURING_BACKUP');
      const name=`object-${i}.aes`,objectPath=[object.bucket_id,...object.name.split('/')].map(encodeURIComponent).join('/');
      const response=await request(`https://${env.SUPABASE_PROJECT_REF}.supabase.co/storage/v1/object/authenticated/${objectPath}`,{headers:{apikey:env.SUPABASE_SERVICE_ROLE_KEY,Authorization:`Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`},signal:AbortSignal.timeout(180000)});
      if(!response.ok||!response.body)throw new Error('STORAGE_BACKUP_FAILED');
      await encryptStream(Readable.fromWeb(response.body),join(directory,name),key,context+':'+name);
      const verified=await verifyBackupFile(join(directory,name),key,context+':'+name);
      if(object.metadata?.size!=null&&Number(object.metadata.size)!==verified.bytes)throw new Error('STORAGE_SIZE_MISMATCH');
      const after=JSON.parse(await sourceQuery('storage-after',`select to_jsonb(o) from storage.objects o where id=${literal(object.id)}::uuid`));
      if(JSON.stringify(after)!==JSON.stringify(object))throw new Error('STORAGE_CHANGED_DURING_BACKUP');
      objectChecks.push({id:object.id,file:name,...verified});
    }
    await save('object-checks.aes',objectChecks);
    holder.child.stdin.end('commit;\n');await holder.done;
    return {image,appliedMigrations,reviewedMigrations,catalog,before,coverageBefore,routePolicyBefore,routeSettingsBefore,p12PolicyBefore,roles,memberships,objects,vaultKey,vaultBefore};
  } finally {
    clearInterval(keepAlive);
    holder.child.stdin.end();holder.child.kill();
  }
  } finally {
    if(caDirectory)await rm(caDirectory,{recursive:true,force:true});
  }
}

async function restoreSource({env,key,context,directory,save,captureCommand,spawnCommand,startRestore,environment,revision},source) {
  const {image,appliedMigrations,reviewedMigrations,catalog,before,coverageBefore,routePolicyBefore,routeSettingsBefore,p12PolicyBefore,roles,memberships,objects,vaultKey,vaultBefore}=source;
  const container=`duindorp-restore-${env.GITHUB_RUN_ID}-${env.GITHUB_RUN_ATTEMPT??'1'}`;
  let localStarted=false;
  try {
    // No network is attached to the restore database. Its cron launcher is
    // disabled, so restored jobs/messages cannot contact live services.
    await startRestore(image,container,vaultKey.root_key);
    localStarted=true;
    const localQuery=sql=>captureCommand('docker',['exec','-i',container,'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],"set timezone='UTC';set datestyle='ISO';"+sql+';');
    console.log('Isolated PostgreSQL version: '+await localQuery("select current_setting('server_version')"));
    console.log('Isolated preload libraries: '+await localQuery("select current_setting('shared_preload_libraries')"));
    for(const role of roles)await localQuery(`do $role$ begin if not exists(select 1 from pg_roles where rolname=${literal(role.name)}) then execute ${literal('create role '+quote(role.name)+' nologin '+(role.inherit?'inherit':'noinherit')+(role.bypassrls?' bypassrls':''))};end if;end $role$`);
    for(const membership of memberships)await localQuery('grant '+quote(membership.role)+' to '+quote(membership.member)+' with admin '+membership.adminOption+', inherit '+membership.inheritOption+', set '+membership.setOption);
    // Managed Supabase roles can own event triggers after their superuser
    // privilege has been removed. PostgreSQL requires that privilege while
    // replaying ALTER EVENT TRIGGER OWNER. Grant it only inside this networkless
    // disposable restore and return every affected role to its source setting.
    for(const role of roles.filter(role=>role.eventTriggerOwner))await localQuery('alter role '+quote(role.name)+' superuser');
    const restore=spawnCommand('docker',['exec','-i',container,'pg_restore','--clean','--if-exists','--exit-on-error','--no-tablespaces','--username=supabase_admin','--dbname=postgres']);
    const restoredStreams=await Promise.allSettled([pipeline(createReadStream(join(directory,'database.aes'),{start:32}),await decryptor(join(directory,'database.aes'),key,context+':database.aes'),restore.child.stdin),restore.done]);
    if(restoredStreams[1].status==='rejected')throw restoredStreams[1].reason;
    if(restoredStreams[0].status==='rejected')throw restoredStreams[0].reason;
    for(const role of roles.filter(role=>role.eventTriggerOwner&&!role.superuser))await localQuery('alter role '+quote(role.name)+' nosuperuser');
    const restored=(await localQuery('begin;'+fingerprintQuery(catalog)+';commit')).split('\n').map(JSON.parse);
    const restoreDifferences=compareFingerprints(before,restored);
    if(restoreDifferences.length)throw new Error('RESTORE_DATA_MISMATCH: '+restoreDifferences.join(', '));
    const vaultAfter=JSON.parse(await localQuery(vaultFingerprint));
    if(JSON.stringify(vaultBefore)!==JSON.stringify(vaultAfter))throw new Error('VAULT_RESTORE_DATA_MISMATCH');
    console.log(`Isolated restore preserved all ${catalog.length} table fingerprints.`);
    const migrations=await dryRunReleaseMigrations(reviewedMigrations,appliedMigrations,localQuery);
    if(migrations.length!==REVIEWED_RELEASE_MIGRATIONS.length)throw new Error('REVIEWED_MIGRATION_SET_CHANGED');
    const migratedPreservation=JSON.parse(await localQuery('begin;'+preservationQuery(catalog,coverageBefore)+';commit'));
    const migrated=migratedPreservation.rows,coverageAfter=migratedPreservation.worldPolicyInitialization;
    const coverageReconciliation=reconcileWorldPolicyInitialization(coverageBefore,coverageAfter,reviewedMigrations.map(file=>file.split('_')[0]));
    const jointRoutePolicyReconciliation=reconcileJointRoutePolicyRelease(routePolicyBefore,migratedPreservation.jointRoutePolicyRelease,reviewedMigrations.map(file=>file.split('_')[0]));
    const expectedVersions=reviewedMigrations.map(file=>file.split('_')[0]);
    const p12RoutePolicyReconciliation=reconcileP12RoutePolicy(p12PolicyBefore,migratedPreservation.p12RoutePolicy,expectedVersions);
    const settingsBeforeP12Policy=jointRouteSettingsBeforeP12Policy(p12PolicyBefore,migratedPreservation.p12RoutePolicy,expectedVersions,migratedPreservation.jointRouteSettingsInitialization);
    const jointRouteSettingsReconciliation=reconcileJointRouteSettingsInitialization(routeSettingsBefore,settingsBeforeP12Policy,expectedVersions);
    const reconciledTables=new Set([...coverageReconciliation.reconciledTables,...jointRoutePolicyReconciliation.reconciledTables,...jointRouteSettingsReconciliation.reconciledTables,...p12RoutePolicyReconciliation.reconciledTables]);
    const migrationDifferences=[...new Set([...compareFingerprints(before,migrated).filter(table=>!reconciledTables.has(table)),...coverageReconciliation.failures,...jointRoutePolicyReconciliation.failures,...jointRouteSettingsReconciliation.failures,...p12RoutePolicyReconciliation.failures])];
    await save('world-policy-initialization.aes',{before:coverageBefore,after:coverageAfter,reconciliation:coverageReconciliation});
    await save('joint-route-policy-release.aes',{before:routePolicyBefore,after:migratedPreservation.jointRoutePolicyRelease,reconciliation:jointRoutePolicyReconciliation});
    await save('joint-route-settings-initialization.aes',{before:routeSettingsBefore,after:migratedPreservation.jointRouteSettingsInitialization,reconciliation:jointRouteSettingsReconciliation});
    await save('p12-route-policy.aes',{before:p12PolicyBefore,after:migratedPreservation.p12RoutePolicy,reconciliation:p12RoutePolicyReconciliation});
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
    const proof={version:1,environment,revision,context,image,appliedMigrations,recordedAt:new Date().toISOString(),restoreVerified:true,migrationDryRunVerified:true,storageVerified:true,vaultVerified:true,vaultSecrets:vaultBefore.length,tables:catalog.length,objects:objects.length,migrations,coverageReconciliation,jointRoutePolicyReconciliation,jointRouteSettingsReconciliation,p12RoutePolicyReconciliation,backfill,legacyPrint,files,
      limits:['Provider runtime secrets remain in the existing secret store.','No live database configuration, migration, credential, or row was changed by this job.','Isolated SQL restore is not an Auth/mail/browser acceptance result.']};
    proof.signature=createHmac('sha256',key).update(JSON.stringify(proof)).digest('hex');
    await writeFile(join(directory,'proof.json'),JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
    console.log(JSON.stringify({backupAndRestore:'passed',environment,revision,tables:catalog.length,objects:objects.length,migrationDryRun:'passed'}));
  } finally {
    if(localStarted)await captureCommand('docker',['rm','--force',container]);
  }
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)runReleaseBackup().catch(error=>{console.error(error.message);process.exitCode=1;});
