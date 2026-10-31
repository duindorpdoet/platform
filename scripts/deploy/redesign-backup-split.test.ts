import {it,expect,vi} from 'vitest';
import {mkdtemp,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash,createHmac} from 'node:crypto';
import {backupKey,sealBackup} from './redesign-preflight.mjs';
import {runReleaseBackup} from './redesign-backup.mjs';
import {REVIEWED_RELEASE_MIGRATIONS} from './release-migrations.mjs';

const secret=Buffer.alloc(32,91).toString('base64'),key=backupKey(secret),kind='duindorp-release-source-export-v1';
async function fixture(withObject=false) {
  const root=await mkdtemp(join(tmpdir(),'duindorp-split-backup-')),directory=join(root,'duindorp-release-backup');
  const {mkdir}=await import('node:fs/promises');await mkdir(directory,{mode:0o700});
  const env={RELEASE_BACKUP_MODE:'restore',APP_ENVIRONMENT:'production',GITHUB_SHA:'a'.repeat(40),GITHUB_RUN_ID:'123',GITHUB_RUN_ATTEMPT:'1',SUPABASE_PROJECT_REF:'dtubngvxfbupgvgfrjko',CHILD_CODE_ENCRYPTION_KEY:secret,RUNNER_TEMP:root};
  const context=`duindorp-release-backup-v1:production:${env.GITHUB_SHA}:123:1`,image='supabase/postgres:17.6.1.167';
  const appliedMigrations=REVIEWED_RELEASE_MIGRATIONS.map(file=>file.split('_')[0]);
  const migrations=await Promise.all(REVIEWED_RELEASE_MIGRATIONS.map(async file=>({file,sha256:createHash('sha256').update(await readFile(join('supabase/migrations',file))).digest('hex')})));
  const objectBytes=Buffer.from('PRIVATE_SYNTHETIC_STORAGE_OBJECT'),object={id:'00000000-0000-4000-8000-000000000001',metadata:{size:objectBytes.length}};
  const values:Record<string,unknown>={'catalog.aes':[{schema:'app_private',name:'events',columns:['id']}],'inventory.aes':[{table:'app_private.events',rows:0,sha256:'b'.repeat(64)}],
    'roles.aes':[],'role-memberships.aes':[],'settings.aes':{private:'PRIVATE_SETTINGS'},'objects.aes':withObject?[object]:[],'vault-root-key.aes':{root_key:'c'.repeat(64)},'vault-inventory.aes':[],
    'database.aes':{private:'PRIVATE_DATABASE'},'object-checks.aes':withObject?[{id:object.id,file:'object-0.aes',sha256:createHash('sha256').update(objectBytes).digest('hex'),bytes:objectBytes.length}]:[],'source-state.aes':{image,appliedMigrations,reviewedMigrations:[...REVIEWED_RELEASE_MIGRATIONS],coverageBefore:{},routePolicyBefore:{},routeSettingsBefore:{},p12PolicyBefore:{}}};
  if(withObject)values['object-0.aes']=objectBytes;
  const files=[];
  for(const [name,value] of Object.entries(values)) {
    const bytes=sealBackup(Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value)),key,context+':'+name);await writeFile(join(directory,name),bytes,{mode:0o600});
    files.push({name,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
  }
  const proof={version:1,kind,environment:'production',revision:env.GITHUB_SHA,context,projectRef:env.SUPABASE_PROJECT_REF,image,sourceExportVerified:true,restoreVerified:false,migrationDryRunVerified:false,tables:1,objects:withObject?1:0,appliedMigrations,migrations,files};
  const save=async()=>writeFile(join(directory,'source-export.json'),JSON.stringify({...proof,signature:createHmac('sha256',key).update(kind+'\0').update(JSON.stringify(proof)).digest('hex')}));
  await save();
  const request=vi.fn<typeof fetch>(async()=>{throw Error('REMOTE_REQUEST_FORBIDDEN');}),captureCommand=vi.fn(async()=>''),startRestore=vi.fn(async()=>{throw Error('RESTORE_GATE_REACHED');});
  return {root,directory,env,proof,save,request,captureCommand,startRestore};
}
it('accepts a fully authenticated exact-context source only before starting a networkless restore, without provider credentials or calls',async()=>{
  const f=await fixture(true);try {
    await expect(runReleaseBackup(f.env,{request:f.request,captureCommand:f.captureCommand,startRestore:f.startRestore})).rejects.toThrow('RESTORE_GATE_REACHED');
    expect(f.request).not.toHaveBeenCalled();expect(f.captureCommand).toHaveBeenCalledExactlyOnceWith('docker',['pull',f.proof.image]);
    expect(f.startRestore).toHaveBeenCalledExactlyOnceWith(f.proof.image,'duindorp-restore-123-1','c'.repeat(64));
    expect(await readdir(f.directory)).not.toContain('proof.json');
    expect(JSON.stringify(f.proof)).not.toContain('PRIVATE');
  }finally{await rm(f.root,{recursive:true,force:true});}
});
it.each(['APP_ENVIRONMENT','GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','SUPABASE_PROJECT_REF'] as const)('rejects a source from another %s before any Docker or provider call',async field=>{
  const f=await fixture();try {
    const values={APP_ENVIRONMENT:'staging',GITHUB_SHA:'d'.repeat(40),GITHUB_RUN_ID:'124',GITHUB_RUN_ATTEMPT:'2',SUPABASE_PROJECT_REF:'z'.repeat(20)};
    await expect(runReleaseBackup({...f.env,[field]:values[field]},{request:f.request,captureCommand:f.captureCommand,startRestore:f.startRestore})).rejects.toThrow('SOURCE_EXPORT_CONTEXT_MISMATCH');
    expect(f.request).not.toHaveBeenCalled();expect(f.captureCommand).not.toHaveBeenCalled();expect(f.startRestore).not.toHaveBeenCalled();
  }finally{await rm(f.root,{recursive:true,force:true});}
});
it.each(['signature','ciphertext','gcm-with-valid-digest','migration','extra-file','duplicate-file','final-proof'] as const)('fails closed on %s without starting restoration',async fault=>{
  const f=await fixture();try {
    if(fault==='signature'){f.proof.tables++;await writeFile(join(f.directory,'source-export.json'),JSON.stringify({...f.proof,signature:'0'.repeat(64)}));}
    if(fault==='ciphertext'||fault==='gcm-with-valid-digest'){
      const name='database.aes',bytes=await readFile(join(f.directory,name));bytes[bytes.length-1]^=1;await writeFile(join(f.directory,name),bytes);
      if(fault==='gcm-with-valid-digest'){f.proof.files.find(x=>x.name===name)!.sha256=createHash('sha256').update(bytes).digest('hex');await f.save();}
    }
    if(fault==='migration'){f.proof.migrations[0].sha256='0'.repeat(64);await f.save();}
    if(fault==='extra-file')await writeFile(join(f.directory,'unreviewed.aes'),'PRIVATE');
    if(fault==='duplicate-file'){f.proof.files[0].name=f.proof.files[1].name;await f.save();}
    if(fault==='final-proof')await writeFile(join(f.directory,'proof.json'),'{}');
    await expect(runReleaseBackup(f.env,{request:f.request,captureCommand:f.captureCommand,startRestore:f.startRestore})).rejects.toThrow();
    expect(f.request).not.toHaveBeenCalled();expect(f.captureCommand).not.toHaveBeenCalled();expect(f.startRestore).not.toHaveBeenCalled();
  }finally{await rm(f.root,{recursive:true,force:true});}
});

it('keeps the default monolithic pooler path and reaches restore without requiring a split manifest',async()=>{
  const f=await fixture();try {
    await rm(f.directory,{recursive:true});
    const {PassThrough}=await import('node:stream');
    const inventory=[{table:'app_private.events',rows:0,sha256:'b'.repeat(64)}];
    const migrations=(await readdir('supabase/migrations')).filter(x=>x.endsWith('.sql')).map(x=>x.split('_')[0]);
    const request=vi.fn<typeof fetch>(async input=>{
      const path=new URL(String(input)).pathname;
      return Response.json(path.endsWith('/pooler')?[{pool_mode:'session',db_host:'aws-1-eu-west-2.pooler.supabase.com',db_user:'postgres',db_name:'postgres'}]
        :path.endsWith('/pgsodium')?{root_key:'c'.repeat(64)}:{database:{version:'17.6.1.167'}});
    });
    const reads:string[]=[];
    const captureCommand=vi.fn(async (_command:string,args:string[],input='')=>{
      if(args[0]==='pull')return '';
      reads.push(input);
      expect(input).toMatch(/^begin isolation level repeatable read read only;set transaction snapshot '00000001-00000002-1';/);
      expect(input).toContain("set local statement_timeout='5min';set local lock_timeout='3s';set local jit=off;");
      if(input.includes("'worldPolicyInitialization'"))return JSON.stringify({rows:inventory,worldPolicyInitialization:{},jointRoutePolicyRelease:{},jointRouteSettingsInitialization:{},p12RoutePolicy:{}});
      if(input.includes("'columns'"))return JSON.stringify([{schema:'app_private',name:'events',columns:['id']}]);
      if(input.includes('from supabase_migrations.schema_migrations'))return JSON.stringify(migrations);
      return '[]';
    });
    const processCommand=(_command:string,args:string[])=>{
      const stdin=new PassThrough(),stdout=new PassThrough(),stderr=new PassThrough();
      const dump=args.includes('pg_dump');
      const done=dump?Promise.resolve():new Promise<void>(resolve=>stdin.once('finish',resolve));
      if(dump){expect(args).toContain('--snapshot=00000001-00000002-1');stdout.end('LOCAL_SYNTHETIC_ARCHIVE');}
      else stdin.on('data',bytes=>{if(String(bytes).includes('pg_export_snapshot'))stdout.write('00000001-00000002-1\n');});
      return {child:{stdin,stdout,stderr,kill:()=>true} as unknown as import('node:child_process').ChildProcessWithoutNullStreams,done};
    };
    const env={...f.env,RELEASE_BACKUP_MODE:undefined,SUPABASE_ACCESS_TOKEN:'PRIVATE',SUPABASE_SERVICE_ROLE_KEY:'PRIVATE',SUPABASE_DB_PASSWORD:'PRIVATE'};
    await expect(runReleaseBackup(env,{request,captureCommand,processCommand,startRestore:f.startRestore})).rejects.toThrow('RESTORE_GATE_REACHED');
    expect(reads).toHaveLength(7);expect(f.startRestore).toHaveBeenCalledOnce();
    expect((await readdir(f.directory)).every(name=>name.endsWith('.aes'))).toBe(true);
  }finally{await rm(f.root,{recursive:true,force:true});}
});
