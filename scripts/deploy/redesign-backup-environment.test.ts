import {afterEach,expect,it,vi} from 'vitest';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {mkdtemp,readdir,rm} from 'node:fs/promises';
import {readdirSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import type {ChildProcessWithoutNullStreams,SpawnOptions} from 'node:child_process';
const mocks=vi.hoisted(()=>({spawn:vi.fn()}));
vi.mock('node:child_process',()=>({spawn:mocks.spawn}));
vi.mock('./portable-postgres-clients.mjs',()=>({validatePortablePostgresClient:vi.fn(async()=>({version:'17.6',psql:'/trusted/bin/psql',pgDump:'/trusted/bin/pg_dump'}))}));
import {runReleaseBackup} from './redesign-backup.mjs';

afterEach(()=>{vi.unstubAllEnvs();vi.clearAllMocks();});
const ref='dtubngvxfbupgvgfrjko';
const project={id:ref,region:'eu-west-2',database:{host:`db.${ref}.supabase.co`,version:'17.6.1.167'}};
function poison() {
  for(const name of ['PGHOSTADDR','PGSERVICE','PGSERVICEFILE','PGPASSFILE','PGSSLCERT','PGSSLKEY','PGSSLPASSWORD','PGSSLCRL','PGSSLCRLDIR','PGSSLMODE','PGSSLROOTCERT',
    'PGGSSENCMODE','PGOPTIONS','PGCLIENTENCODING','PGFUTURE_CONNECTION_OVERRIDE','SSL_CERT_FILE','SSL_CERT_DIR','OPENSSL_CONF','OPENSSL_MODULES','LD_PRELOAD','LD_LIBRARY_PATH','DATABASE_URL','SUPABASE_DB_URL','PRIVATE_UNRELATED_SECRET'])vi.stubEnv(name,`PRIVATE_AMBIENT_${name}`);
}
function environment(root:string) {
  return {APP_ENVIRONMENT:'production',GITHUB_SHA:'a'.repeat(40),GITHUB_RUN_ID:'123',GITHUB_RUN_ATTEMPT:'1',GITHUB_EVENT_NAME:'workflow_dispatch',GITHUB_REF:'refs/heads/production',GITHUB_REPOSITORY:'duindorpdoet/platform',
    SUPABASE_PROJECT_REF:ref,SUPABASE_ACCESS_TOKEN:'PRIVATE_TOKEN',SUPABASE_DB_PASSWORD:'PRIVATE_PASSWORD',SUPABASE_SERVICE_ROLE_KEY:'PRIVATE_SERVICE',CHILD_CODE_ENCRYPTION_KEY:Buffer.alloc(32,17).toString('base64'),RUNNER_TEMP:root,RELEASE_BACKUP_MODE:'export',RELEASE_READ_TRANSPORT:'direct',RELEASE_PG_CLIENT_DIRECTORY:'/trusted'};
}
it('passes an exact isolated environment through both actual native spawn and capture without remerging ambient libpq, service or TLS overrides',async()=>{
  poison();const root=await mkdtemp(join(tmpdir(),'duindorp-native-env-'));
  try {
    const environments:Array<Record<string,string|undefined>>=[],homes:string[]=[];
    mocks.spawn.mockImplementation((command:string,_args:string[],options:SpawnOptions)=>{
      expect(command).toBe('/trusted/bin/psql');const env={...options.env};environments.push(env);homes.push(env.HOME!);
      expect(readdirSync(env.HOME!)).toEqual(['roots.crt']);
      if(environments.length===2)throw Error('NATIVE_CAPTURE_STOP');
      const stdin=new PassThrough(),stdout=new PassThrough(),stderr=new PassThrough(),child=new EventEmitter();
      stdin.on('data',bytes=>{if(String(bytes).includes('pg_export_snapshot'))stdout.write('00000001-00000002-1\n');});
      return Object.assign(child,{stdin,stdout,stderr,kill:()=>{stdin.end();child.emit('close',0);return true;}}) as unknown as ChildProcessWithoutNullStreams;
    });
    const request=vi.fn<typeof fetch>(async()=>Response.json(project));
    await expect(runReleaseBackup(environment(root),{request})).rejects.toThrow('NATIVE_CAPTURE_STOP');
    expect(mocks.spawn).toHaveBeenCalledTimes(2);expect(request).toHaveBeenCalledOnce();
    for(const env of environments) {
      expect(env).toMatchObject({PGHOST:project.database.host,PGPORT:'5432',PGDATABASE:'postgres',PGUSER:'postgres',PGPASSWORD:'PRIVATE_PASSWORD',PGCONNECT_TIMEOUT:'30',PGSSLMODE:'verify-full',PGGSSENCMODE:'disable',
        LANG:'C',LC_ALL:'C',PGSERVICE:'',PGSERVICEFILE:'',PGPASSFILE:'',PGHOSTADDR:'',PGSSLCERT:'',PGSSLKEY:'',PGSSLPASSWORD:''});
      expect(env.PGSSLROOTCERT).toBe(join(env.HOME!,'roots.crt'));
      expect(env.PGOPTIONS).toBe('-c statement_timeout=300000 -c lock_timeout=3000 -c jit=off');
      expect(JSON.stringify(env)).not.toContain('PRIVATE_AMBIENT_');
      expect(Object.keys(env).sort()).toEqual(['HOME','LANG','LC_ALL','PATH','PGCONNECT_TIMEOUT','PGDATABASE','PGGSSENCMODE','PGHOST','PGHOSTADDR','PGOPTIONS','PGPASSFILE','PGPASSWORD','PGPORT','PGSERVICE','PGSERVICEFILE','PGSSLCERT','PGSSLKEY','PGSSLMODE','PGSSLPASSWORD','PGSSLROOTCERT','PGUSER'].sort());
    }
    expect(new Set(homes).size).toBe(1);expect((await readdir(root)).filter(n=>n.startsWith('duindorp-source-client-ca-'))).toEqual([]);
  }finally{await rm(root,{recursive:true,force:true});}
});
it('preserves the original ambient environment merge for the default Docker path',async()=>{
  poison();const root=await mkdtemp(join(tmpdir(),'duindorp-docker-env-'));
  try {
    mocks.spawn.mockImplementation((command:string,_args:string[],options:SpawnOptions)=>{
      expect(command).toBe('docker');expect(options.env?.PGHOSTADDR).toBe('PRIVATE_AMBIENT_PGHOSTADDR');expect(options.env?.PRIVATE_UNRELATED_SECRET).toBe('PRIVATE_AMBIENT_PRIVATE_UNRELATED_SECRET');throw Error('DEFAULT_DOCKER_STOP');
    });
    const request=vi.fn<typeof fetch>(async input=>Response.json(String(input).endsWith('/pooler')?[{pool_mode:'session',db_host:'aws-1-eu-west-2.pooler.supabase.com',db_user:'postgres',db_name:'postgres'}]:project));
    await expect(runReleaseBackup({...environment(root),RELEASE_READ_TRANSPORT:undefined},{request})).rejects.toThrow('DEFAULT_DOCKER_STOP');
    expect(mocks.spawn).toHaveBeenCalledOnce();expect(request).toHaveBeenCalledTimes(2);
  }finally{await rm(root,{recursive:true,force:true});}
});
