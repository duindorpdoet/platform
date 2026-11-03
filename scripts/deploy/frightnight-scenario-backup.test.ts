import { readFileSync } from 'node:fs';
import { describe,expect,it } from 'vitest';
import { scenarioBackupEnabled,scenarioBackupQuery,assertScenarioSnapshot,compareScenarioRestore,type ScenarioSnapshot } from './frightnight-scenario-backup.mjs';
const revision='a'.repeat(40);
const env={APP_ENVIRONMENT:'staging',APP_URL:'https://staging-halloween.duindorpdoet.nl',SUPABASE_PROJECT_REF:'nocteiuvohesvqbowchw',NEXT_PUBLIC_SUPABASE_URL:'https://nocteiuvohesvqbowchw.supabase.co',EVENT_SLUG:'frightnight-2027-test',FRIGHTNIGHT_ENABLED:'true',FRIGHTNIGHT_PROJECT_REF:'nocteiuvohesvqbowchw',FRIGHTNIGHT_PAYMENT_PROVIDER:'contract',FRIGHTNIGHT_MAIL_MODE:'sink',FRIGHTNIGHT_HARDWARE_ENABLED:'false',GITHUB_SHA:revision,FRIGHTNIGHT_VERIFIED_RELEASE_SHA:revision,FRIGHTNIGHT_SCENARIO_BACKUP:'true'};
const names=['20261103012453_frightnight_2027_isolated_core.sql','20261103042000_frightnight_2027_edition_access.sql'].flatMap(name=>[...readFileSync('supabase/migrations/'+name,'utf8').matchAll(/create table app_private\.(fn_\w+)/g)].map(match=>match[1]));
const catalog=names.map(name=>({schema:'app_private',name,columns:['event_id','fixture']}));
const state=():ScenarioSnapshot=>({slug:'frightnight-2027-test',date:'2027-10-30',timezone:'Europe/Amsterdam',environment:'staging',isTest:true,seedVersion:1,closed:false,bindingDigest:'a'.repeat(64),unsafeSink:0,tables:names.sort().map(name=>({table:'app_private.'+name,rows:({fn_events:1,fn_registrations:4,fn_zones:5,fn_quests:6,fn_activities:2}as Record<string,number>)[name]??0,sha256:'b'.repeat(64)}))});
describe('post-release encrypted scenario backup gate',()=>{
 it('preserves existing backup behavior unless explicitly enabled',()=>{
  expect(scenarioBackupEnabled({})).toBe(false);expect(scenarioBackupEnabled({FRIGHTNIGHT_SCENARIO_BACKUP:'false'})).toBe(false);expect(scenarioBackupEnabled(env)).toBe(true);
 });
 it('requires the verified exact staging revision and a full source/restore run',()=>{
  for(const change of [{FRIGHTNIGHT_VERIFIED_RELEASE_SHA:'b'.repeat(40)},{RELEASE_BACKUP_MODE:'export'},{APP_ENVIRONMENT:'production'},{SUPABASE_PROJECT_REF:'dtubngvxfbupgvgfrjko'},{EVENT_SLUG:'duindorp-halloween-2026'}])expect(()=>scenarioBackupEnabled({...env,...change})).toThrow();
 });
 it('fingerprints every event-scoped FrightNight table without exposing row values',()=>{
  const query=scenarioBackupQuery(catalog);expect(names).toHaveLength(31);expect(query).toContain('fn_edition_entries');expect(query).toContain('t.event_id=(select id from app_private.events');expect(query).toContain("where e.slug='frightnight-2027-test'");expect(query).toContain('sha256');expect(query).toContain('set local extra_float_digits=3');
  expect(query).not.toMatch(/(?:^|;)\s*(insert|update|delete|alter|grant|truncate|drop)\b/i);
  expect(()=>scenarioBackupQuery(catalog.slice(1))).toThrow('CATALOG_INCOMPLETE');
 });
 it('requires an active seeded isolated scenario with all required records',()=>{
  expect(assertScenarioSnapshot(state())).toBeTruthy();
  for(const change of [{seedVersion:0},{closed:true},{isTest:false},{unsafeSink:1},{environment:'production'}])expect(()=>assertScenarioSnapshot({...state(),...change})).toThrow('ACTIVE_FRIGHTNIGHT_SCENARIO_REQUIRED');
  const missing=state();missing.tables.find(row=>row.table==='app_private.fn_quests')!.rows=0;expect(()=>assertScenarioSnapshot(missing)).toThrow('SEEDED_FRIGHTNIGHT_SCENARIO_REQUIRED');
 });
 it('rejects restored row loss, modification, different scope or incomplete fingerprints',()=>{
  const changed=state();changed.tables[0].sha256='c'.repeat(64);expect(()=>compareScenarioRestore(state(),changed)).toThrow('RESTORE_MISMATCH');
  const lost=state();lost.tables=lost.tables.slice(1);expect(()=>compareScenarioRestore(state(),lost)).toThrow('FINGERPRINTS_REQUIRED');
  const foreign=state();foreign.bindingDigest='d'.repeat(64);expect(()=>compareScenarioRestore(state(),foreign)).toThrow('RESTORE_MISMATCH');
 });
 it('signs only a sanitized summary alongside the existing encrypted artifacts',()=>{
  const proof=compareScenarioRestore(state(),state());expect(proof).toMatchObject({slug:'frightnight-2027-test',seedVersion:1,tables:31,registrations:4,zones:5,restoreVerified:true});expect(proof.sha256).toMatch(/^[a-f0-9]{64}$/);expect(proof).not.toHaveProperty('bindingDigest');expect(proof).not.toHaveProperty('actor');
  const source=readFileSync('scripts/deploy/redesign-backup.mjs','utf8');expect(source).toContain("sourceQuery('frightnight-scenario',scenarioBackupQuery(catalog),snapshot)");expect(source).toContain("save('frightnight-scenario.aes',frightnightScenario)");expect(source.indexOf('proof.frightnightScenario=scenarioProof')).toBeLessThan(source.indexOf("proof.signature=createHmac"));
 });
 it('runs after all published acceptance gates with its own encrypted artifact',()=>{
  const workflow=readFileSync('.github/workflows/deploy-staging.yml','utf8').split('  frightnight-scenario-backup:')[1]?.split('\n  deploy:')[0];expect(workflow).toBeTruthy();expect(workflow).toContain('needs: [deploy, account-app-acceptance, mail-acceptance, frightnight-load-acceptance]');expect(workflow).toContain('FRIGHTNIGHT_SCENARIO_BACKUP: "true"');expect(workflow).toContain('FRIGHTNIGHT_VERIFIED_RELEASE_SHA: ${{ needs.deploy.outputs.verified_revision }}');expect(workflow).toContain('node scripts/deploy/redesign-backup.mjs');expect(workflow).toContain('frightnight-scenario-backup-staging-');expect(workflow).not.toContain('continue-on-error');
 });
});
