import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { assertFrightnightRelease, assertFrightnightHostedContract, assertFrightnightHostedRelease, assertFrightnightContractArm, assertFrightnightContractSnapshot, assertFrightnightContractOrder, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL, type FrightnightSafety } from './frightnight-release.mjs';

const env = {APP_ENVIRONMENT:'staging',APP_URL:'https://staging-halloween.duindorpdoet.nl',SUPABASE_PROJECT_REF:'nocteiuvohesvqbowchw',NEXT_PUBLIC_SUPABASE_URL:'https://nocteiuvohesvqbowchw.supabase.co',EVENT_SLUG:'frightnight-2027-test',FRIGHTNIGHT_ENABLED:'true',FRIGHTNIGHT_PROJECT_REF:'nocteiuvohesvqbowchw',FRIGHTNIGHT_PAYMENT_PROVIDER:'contract',FRIGHTNIGHT_MAIL_MODE:'sink',FRIGHTNIGHT_HARDWARE_ENABLED:'false'};
const safety = ():FrightnightSafety => ({tables:31,unsafeTables:0,unsafeFunctions:0,actorFunctions:4,unsafeEvents:0,unsafeSink:0,sinkHasRecipient:false,legacyBindings:0,
 edition:{slug:env.EVENT_SLUG,date:'2027-10-30',timezone:'Europe/Amsterdam',phase:'draft',environment:'staging',isTest:true,retentionUntil:'2027-11-03T00:00:00Z'},
 mailWorker:{active:true,endpoint:env.APP_URL+'/api/jobs/mail',hasSecret:true},
 legacyJobs:['duindorp-halloween-route-dispatch','duindorp-poortkamer-maintenance','duindorp-halloween-mail-outbox'].map(name=>({name,active:true,schedule:'* * * * *'}))});

describe('explicit 2027 staging release binding',()=>{
 it('requires the actual runtime contract provider before creating hosted fixtures',()=>{
  const revision='a'.repeat(40),health={revision,status:'ok',service:'duindorphalloween',environment:'staging',eventSlug:env.EVENT_SLUG,brand:'frightnight-2027-v7',paymentProvider:'contract'};
  expect(()=>assertFrightnightHostedContract(health,revision)).not.toThrow();
  for(const change of [{paymentProvider:'mollie'},{paymentProvider:undefined},{revision:'b'.repeat(40)},{environment:'production'},{eventSlug:'duindorp-halloween-2026'},{brand:'legacy'}])expect(()=>assertFrightnightHostedContract({...health,...change},revision)).toThrow('LIVE_CONTRACT_RELEASE_BINDING_REQUIRED_BEFORE_FIXTURES');
  const source=readFileSync('scripts/acceptance/frightnight-staging.mjs','utf8');
  expect(source.indexOf('assertFrightnightHostedRelease(health,process.env.GITHUB_SHA,process.env.FRIGHTNIGHT_PAYMENT_PROVIDER)')).toBeGreaterThan(0);
  expect(source.indexOf('assertFrightnightHostedRelease(health,process.env.GITHUB_SHA,process.env.FRIGHTNIGHT_PAYMENT_PROVIDER)')).toBeLessThan(source.indexOf("const admin=await actor('regie')"));
 });
 it('accepts only a safe staging configuration',()=>expect(assertFrightnightRelease(env).slug).toBe('frightnight-2027-test'));
 it.each([
  {APP_ENVIRONMENT:'production'},{APP_URL:'https://halloween.duindorpdoet.nl'},{SUPABASE_PROJECT_REF:'dtubngvxfbupgvgfrjko'},
  {NEXT_PUBLIC_SUPABASE_URL:'https://dtubngvxfbupgvgfrjko.supabase.co'},{EVENT_SLUG:'duindorp-halloween-2026'},
  {FRIGHTNIGHT_PROJECT_REF:'dtubngvxfbupgvgfrjko'},{FRIGHTNIGHT_ENABLED:'false'},
 ])('refuses a mismatched target before mutation: %o',change=>expect(()=>assertFrightnightRelease({...env,...change})).toThrow('FRIGHTNIGHT_STAGING_BINDING_REQUIRED'));
 it('requires sink delivery, locally controlled hardware and test-only credentials',()=>{
  for(const change of [{FRIGHTNIGHT_MAIL_MODE:'allowlist'},{FRIGHTNIGHT_HARDWARE_ENABLED:'true'}])expect(()=>assertFrightnightRelease({...env,...change})).toThrow('FRIGHTNIGHT_SINK_AND_LOCAL_HARDWARE_REQUIRED');
  expect(()=>assertFrightnightRelease({...env,MOLLIE_TEST_API_KEY:'live_'+'a'.repeat(30)})).toThrow('FRIGHTNIGHT_LIVE_PAYMENT_FORBIDDEN');
  expect(()=>assertFrightnightRelease({...env,FRIGHTNIGHT_PAYMENT_PROVIDER:'mollie'})).toThrow('MOLLIE_TEST_API_KEY_REQUIRED');
  expect(assertFrightnightRelease({...env,FRIGHTNIGHT_PAYMENT_PROVIDER:'mollie',MOLLIE_TEST_API_KEY:'test_'+'a'.repeat(30)})).toBeTruthy();
 });
 it('never derives a bootstrap administrator from historical data',()=>{
  expect(()=>assertFrightnightRelease({...env,FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID:'first-admin'})).toThrow('FRIGHTNIGHT_BOOTSTRAP_ACTOR_INVALID');
  const source=readFileSync('scripts/deploy/bootstrap-frightnight.mjs','utf8');
  expect(source).toContain('FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID_REQUIRED');
  expect(source).not.toContain('from auth.users');
 });
});

describe('read-only schema, sink and legacy-job release proof',()=>{
 it('requires a correctly scoped 2027 edition after the schema-only gate',()=>{
  expect(assertFrightnightSafety(safety()).edition?.slug).toBe(env.EVENT_SLUG);
  const noEdition={...safety(),edition:null};
  expect(assertFrightnightSafety(noEdition,false)).toBe(noEdition);
  expect(()=>assertFrightnightSafety(noEdition)).toThrow('FRIGHTNIGHT_EDITION_BOOTSTRAP_REQUIRED');
  expect(()=>assertFrightnightSafety({...safety(),edition:{...safety().edition!,date:'2026-10-31'}})).toThrow('FRIGHTNIGHT_EDITION_BOOTSTRAP_REQUIRED');
 });
 it.each(['unsafeTables','unsafeFunctions','unsafeEvents','unsafeSink','legacyBindings'] as const)('blocks an unsafe database state: %s',key=>expect(()=>assertFrightnightSafety({...safety(),[key]:1})).toThrow('FRIGHTNIGHT_DATABASE_ISOLATION_FAILED'));
 it('blocks direct recipient delivery and lost actor grants',()=>{
  expect(()=>assertFrightnightSafety({...safety(),tables:30})).toThrow();
  expect(()=>assertFrightnightSafety({...safety(),tables:32})).toThrow();
  expect(()=>assertFrightnightSafety({...safety(),sinkHasRecipient:true})).toThrow();
  expect(()=>assertFrightnightSafety({...safety(),actorFunctions:2})).toThrow();
 });
 it('preserves every legacy job and the dedicated staging endpoint',()=>{
  for(const state of [{...safety(),legacyJobs:safety().legacyJobs.slice(1)},
    {...safety(),legacyJobs:safety().legacyJobs.map(job=>({...job,active:false}))},
    {...safety(),mailWorker:{...safety().mailWorker,endpoint:'https://halloween.duindorpdoet.nl/api/jobs/mail'}}]) expect(()=>assertFrightnightSafety(state)).toThrow('FRIGHTNIGHT_LEGACY_JOBS_CHANGED');
 });
 it('reads metadata and aggregate scope without invoking delivery or retention',()=>{
  expect(FRIGHTNIGHT_SAFETY_SQL).not.toMatch(/(?:^|;)\s*(insert|update|delete|truncate|alter|grant|drop)\b/i);
  expect(FRIGHTNIGHT_SAFETY_SQL).not.toMatch(/\b(dispatch_mail_worker|worker_claim_outbox)\s*\(/i);
  expect(FRIGHTNIGHT_SAFETY_SQL).not.toContain('from auth.users');
  expect(FRIGHTNIGHT_SAFETY_SQL).toContain('has_function_privilege');
  expect(FRIGHTNIGHT_SAFETY_SQL).toContain("to_regprocedure('api.frightnight_admin_list(text,text,integer,integer,text,jsonb)')");
  expect(FRIGHTNIGHT_SAFETY_SQL).not.toContain("to_regprocedure('api.frightnight_admin_list(text,text,integer,integer)')");
  expect(FRIGHTNIGHT_SAFETY_SQL).toContain('legacyBindings');
 });
 it('replaces automatic OTP and historical-actor acceptance while retaining mandatory gates',()=>{
  const workflow=readFileSync('.github/workflows/deploy-staging.yml','utf8');
  expect(workflow).not.toContain('scripts/acceptance/staging_mail.py');
  expect(workflow).not.toContain('node scripts/deploy/accept-account-app.mjs');
  for(const script of ['redesign-backup','redesign-preflight','redesign-postmigration','check-security-advisors','verify-deployment','accept-frightnight','check-frightnight-safety','check-frightnight-public-rpc'])expect(workflow).toContain(`${script}.mjs`);
  expect(workflow).toContain('FRIGHTNIGHT_RELEASE: "true"');
  expect(workflow).toContain('EVENT_SLUG: frightnight-2027-test');
 });
});


describe('authoritative contract sandbox evidence under either configured provider',()=>{
 const revision='a'.repeat(40);
 const binding={slug:'frightnight-2027-test-acceptance-fixture',eventId:'00000000-0000-4000-8000-000000000001',runId:'00000000-0000-4000-8000-000000000002'};
 const arm={...binding,paymentPolicy:'contract_sandbox',sandboxRunId:binding.runId,provider:'contract',armed:true};
 const snapshot={event:{id:binding.eventId,slug:binding.slug,runId:binding.runId,environment:'staging',test:true,paymentPolicy:'contract_sandbox',sandboxRunId:binding.runId,contractSandboxArmed:true}};
 const order={order_id:'00000000-0000-4000-8000-000000000003',event_id:binding.eventId,provider:'contract',provider_claimed:true};
 it.each(['contract','mollie'])('requires runtime to match trusted configured provider %s before actor creation',provider=>{
  const health={revision,status:'ok',service:'duindorphalloween',environment:'staging',eventSlug:env.EVENT_SLUG,brand:'frightnight-2027-v7',paymentProvider:provider};
  expect(()=>assertFrightnightHostedRelease(health,revision,provider)).not.toThrow();
  for(const change of [{paymentProvider:provider==='mollie'?'contract':'mollie'},{paymentProvider:undefined},{revision:'b'.repeat(40)},{environment:'production'},{eventSlug:'duindorp-halloween-2026'},{brand:'legacy'}])expect(()=>assertFrightnightHostedRelease({...health,...change},revision,provider)).toThrow('LIVE_CONFIGURED_RELEASE_BINDING_REQUIRED_BEFORE_FIXTURES');
  expect(()=>assertFrightnightHostedRelease(health,revision,'unknown')).toThrow();
 });
 it('requires independent service arm and actor readback on the same private edition and current run',()=>{
  expect(()=>assertFrightnightContractArm(arm,binding)).not.toThrow();
  expect(()=>assertFrightnightContractSnapshot(snapshot,binding)).not.toThrow();
  for(const change of [{slug:env.EVENT_SLUG},{eventId:'00000000-0000-4000-8000-000000000099'},{runId:'00000000-0000-4000-8000-000000000099'},{paymentPolicy:'configured'},{sandboxRunId:null},{provider:'mollie'},{armed:false}])expect(()=>assertFrightnightContractArm({...arm,...change},binding)).toThrow();
  for(const change of [{id:'00000000-0000-4000-8000-000000000099'},{slug:env.EVENT_SLUG},{runId:'00000000-0000-4000-8000-000000000099'},{environment:'production'},{test:false},{paymentPolicy:'configured'},{sandboxRunId:null},{contractSandboxArmed:false}])expect(()=>assertFrightnightContractSnapshot({event:{...snapshot.event,...change}},binding)).toThrow();
  for(const scope of [{...binding,slug:env.EVENT_SLUG},{...binding,slug:'duindorp-halloween-2026'},{...binding,runId:''}])expect(()=>assertFrightnightContractArm(arm,scope)).toThrow('PRIVATE_CONTRACT_EDITION_RUN_BINDING_REQUIRED');
 });
 it('arms only the owned private scope before every seed including after reset',()=>{
  const source=readFileSync('scripts/acceptance/frightnight-staging.mjs','utf8');
  expect(source).toContain('OWN_SYNTHETIC_SANDBOX_CONTROLLER_REQUIRED');
  expect(source).toContain('OWN_PRIVATE_SANDBOX_EDITION_REQUIRED');
  expect(source).toContain("await armContract({slug,eventId,actor:admin});\n  await app(admin,'test.seed')");
  expect(source).toContain('directory,armContract});');
 });
 it('rejects stale reset evidence and any unclaimed or external order before simulated provider effects',()=>{
  expect(()=>assertFrightnightContractOrder(order,binding)).not.toThrow();
  const next={...binding,runId:'00000000-0000-4000-8000-000000000004'};
  expect(()=>assertFrightnightContractArm(arm,next)).toThrow('AUTHORITATIVE_CONTRACT_ARM_REQUIRED');
  expect(()=>assertFrightnightContractSnapshot(snapshot,next)).toThrow('AUTHORITATIVE_CONTRACT_READBACK_REQUIRED');
  for(const change of [{provider:'mollie'},{provider_claimed:false},{event_id:'00000000-0000-4000-8000-000000000099'},{order_id:null}])expect(()=>assertFrightnightContractOrder({...order,...change},binding)).toThrow('PERSISTED_CONTRACT_ORDER_REQUIRED_BEFORE_CONFIRMATION');
 });
});
