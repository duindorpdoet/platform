import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { assertFrightnightRelease, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL, type FrightnightSafety } from './frightnight-release.mjs';

const env = {APP_ENVIRONMENT:'staging',APP_URL:'https://staging-halloween.duindorpdoet.nl',SUPABASE_PROJECT_REF:'nocteiuvohesvqbowchw',NEXT_PUBLIC_SUPABASE_URL:'https://nocteiuvohesvqbowchw.supabase.co',EVENT_SLUG:'frightnight-2027-test',FRIGHTNIGHT_ENABLED:'true',FRIGHTNIGHT_PROJECT_REF:'nocteiuvohesvqbowchw',FRIGHTNIGHT_PAYMENT_PROVIDER:'contract',FRIGHTNIGHT_MAIL_MODE:'sink',FRIGHTNIGHT_HARDWARE_ENABLED:'false'};
const safety = ():FrightnightSafety => ({tables:23,unsafeTables:0,unsafeFunctions:0,actorFunctions:4,unsafeEvents:0,unsafeSink:0,sinkHasRecipient:false,legacyBindings:0,
 edition:{slug:env.EVENT_SLUG,date:'2027-10-30',timezone:'Europe/Amsterdam',phase:'draft',environment:'staging',isTest:true,retentionUntil:'2027-11-03T00:00:00Z'},
 mailWorker:{active:true,endpoint:env.APP_URL+'/api/jobs/mail',hasSecret:true},
 legacyJobs:['duindorp-halloween-route-dispatch','duindorp-poortkamer-maintenance','duindorp-halloween-mail-outbox'].map(name=>({name,active:true,schedule:'* * * * *'}))});

describe('explicit 2027 staging release binding',()=>{
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
