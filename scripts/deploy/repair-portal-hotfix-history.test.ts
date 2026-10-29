import {afterEach,beforeEach,describe,it,expect,vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
 assertEquivalentHotfix,assertInstalledHotfix,hotfixRepairActions,hotfixProofQuery,
 runHotfixHistoryRepair,sanitizedHotfixProof,type Proof,
} from './repair-portal-hotfix-history.mjs';

vi.mock('node:child_process',()=>({execFileSync:vi.fn()}));
const CANONICAL='20261027033940',LEGACY='20261027032725';
const ENTRANCE='20261029115344',RECEPTION='20261029170035';
const SAVE='admin_manual_portal_save',BASE=`${SAVE}_before_entrance`,INNER=`${SAVE}_before_reception_policy`;
// Independently checked source fingerprints, including the renamed headers.
const core='b173e2e2a2fe8341cb6e146e62be8b99',entrance='ddf28bacf588fc20a6b1b5a832d0df3c',reception='7a7a9fd2d5ba4554f860ee1de2d864dd';
function proof(mode:'core'|'entrance'|'reception'='core',versions=[CANONICAL]):Proof {
 const active=mode==='core'?core:mode==='entrance'?entrance:reception;
 return {
  save_hash:active,save_functions:{
   [SAVE]:{hash:active,normalized_hash:active},
   ...(mode!=='core'?{[BASE]:{hash:'a1edb0b02db2303039d28b614b8e9e13',normalized_hash:core}}:{}),
   ...(mode==='reception'?{[INNER]:{hash:'95ded90b8f8dc6efc3ef08a2fd7ce124',normalized_hash:entrance}}:{}),
  },
  cleanup_hash:'ce66c8115d726e623cd6c638e5eef587',trigger_valid:true,contaminated_drafts:0,
  versions,wrapper_versions:mode==='core'?[]:mode==='entrance'?[ENTRANCE]:[ENTRANCE,RECEPTION],
 };
}
afterEach(()=>{vi.restoreAllMocks();vi.unstubAllGlobals();vi.unstubAllEnvs();vi.mocked(execFileSync).mockReset();});

describe('metadata-only portal history repair',()=>{
 it.each(['core','entrance','reception'] as const)('proves the entire reviewed %s lineage without rewriting canonical history',mode=>{
  expect(()=>assertInstalledHotfix(proof(mode))).not.toThrow();
  expect(hotfixRepairActions(proof(mode),'staging')).toEqual([]);
  expect(hotfixRepairActions(proof(mode),'production')).toEqual([]);
 });
 it('permits different reviewed wrapper stages only when both preserve the exact canonical base',()=>{
  expect(()=>assertEquivalentHotfix(proof('core',[LEGACY]),proof('reception'))).not.toThrow();
 });
 it.each(['core','entrance','reception'] as const)('records canonical before removing legacy after full %s proof',mode=>{
  expect(hotfixRepairActions(proof(mode,[LEGACY]),'staging')).toEqual([
   {version:CANONICAL,status:'applied'},{version:LEGACY,status:'reverted'},
  ]);
  expect(hotfixRepairActions(proof(mode,[CANONICAL,LEGACY]),'staging')).toEqual([{version:LEGACY,status:'reverted'}]);
 });
 it.each([
  {save_hash:'changed'},{cleanup_hash:'changed'},{trigger_valid:false},{contaminated_drafts:1},
  {wrapper_versions:[RECEPTION]},{wrapper_versions:[ENTRANCE,ENTRANCE]},
  {wrapper_versions:[ENTRANCE,RECEPTION,'20261030000000']},
  {wrapper_versions:[]},{save_functions:{}},
 ])('rejects drift even with already canonical history: %j',change=>{
  const row={...proof('reception'),...change};
  expect(()=>hotfixRepairActions(row,'staging')).toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
  expect(()=>hotfixRepairActions(row,'production')).toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
 });
 it.each([SAVE,BASE,INNER])('refuses an edited %s body even when all other fingerprints and history match',name=>{
  const row=proof('reception');row.save_functions[name].normalized_hash='00000000000000000000000000000000';
  expect(()=>assertInstalledHotfix(row)).toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
 });
 it.each([BASE,INNER])('refuses a missing required %s implementation',name=>{
  const row=proof('reception');delete row.save_functions[name];
  expect(()=>assertInstalledHotfix(row)).toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
 });
 it('refuses an unrecorded hidden reception wrapper rather than trusting an approved outer fingerprint',()=>{
  const row=proof('reception');row.wrapper_versions=[ENTRANCE];
  expect(()=>assertInstalledHotfix(row)).toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
 });
 it.each([{versions:[]},{versions:[LEGACY]},{versions:[CANONICAL,LEGACY]}])('requires exactly canonical production history: %j',({versions})=>{
  expect(()=>hotfixRepairActions(proof('reception',versions),'production')).toThrow('PRODUCTION_HISTORY_NOT_CANONICAL');
 });
 it('refuses an absent or unrecognized staging hotfix history',()=>{
  expect(()=>hotfixRepairActions(proof('entrance',[]),'staging')).toThrow('STAGING_HOTFIX_NOT_INSTALLED');
  expect(()=>hotfixRepairActions(proof('entrance',[CANONICAL,'20261030000000']),'staging')).toThrow('HOTFIX_HISTORY_INVALID');
 });
 it('logs only fixed fingerprint/version fields even when a malformed proof contains private-looking text',()=>{
  const row={...proof('reception'),save_hash:'synthetic-private-value',parentName:'synthetic-private-value',
   wrapper_versions:[ENTRANCE,'synthetic-private-value'],save_functions:{...proof('reception').save_functions,
    unexpected:{hash:'synthetic-private-value',normalized_hash:'synthetic-private-value'}}};
  const safe=sanitizedHotfixProof(row);
  expect(JSON.stringify(safe)).not.toContain('synthetic-private-value');
  expect(safe.save_hash).toBeNull();
  expect(safe.wrapper_versions).toEqual([ENTRANCE]);
  expect(Object.keys(safe.save_functions as object)).toEqual([SAVE,BASE,INNER]);
 });
});

describe('actual deployment guard flow',()=>{
 beforeEach(()=>{
  vi.stubEnv('APP_ENVIRONMENT','staging');vi.stubEnv('SUPABASE_PROJECT_REF','nocteiuvohesvqbowchw');
  vi.stubEnv('GITHUB_REF','refs/heads/staging');vi.stubEnv('GITHUB_SHA','a'.repeat(40));
  vi.stubEnv('SUPABASE_ACCESS_TOKEN','synthetic-local-proof');vi.stubEnv('SUPABASE_DB_PASSWORD','synthetic-local-proof');
  vi.stubEnv('GITHUB_STEP_SUMMARY','');
 });
 it('checks the full installed entrance chain with a read-only query and performs no canonical repair',async()=>{
  const fetch=vi.fn().mockResolvedValue({ok:true,json:async()=>[proof('entrance')]});vi.stubGlobal('fetch',fetch);
  const log=vi.spyOn(console,'log').mockImplementation(()=>{});
  await runHotfixHistoryRepair();
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({query:hotfixProofQuery,read_only:true});
  expect(execFileSync).not.toHaveBeenCalled();
  expect(JSON.parse(log.mock.calls[0][0]).hotfixHistoryBefore).toEqual(sanitizedHotfixProof(proof('entrance')));
 });
 it('prints safe diagnostics before a canonical-history source-proof failure and never attempts repair',async()=>{
  const row=proof('entrance');row.save_functions[BASE].normalized_hash='synthetic-private-value';
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue({ok:true,json:async()=>[row]}));
  const log=vi.spyOn(console,'log').mockImplementation(()=>{});
  await expect(runHotfixHistoryRepair()).rejects.toThrow('HOTFIX_EQUIVALENCE_NOT_PROVEN');
  expect(log).toHaveBeenCalledTimes(1);
  expect(log.mock.calls[0][0]).not.toContain('synthetic-private-value');
  expect(JSON.parse(log.mock.calls[0][0]).hotfixHistoryBefore.save_functions[BASE].normalized_hash).toBeNull();
  expect(execFileSync).not.toHaveBeenCalled();
 });
 it('repairs only proven legacy metadata, canonical first, and independently rechecks the resulting proof',async()=>{
  const fetch=vi.fn().mockResolvedValueOnce({ok:true,json:async()=>[proof('entrance',[LEGACY])]})
   .mockResolvedValueOnce({ok:true,json:async()=>[proof('entrance')]});vi.stubGlobal('fetch',fetch);
  vi.spyOn(console,'log').mockImplementation(()=>{});
  await runHotfixHistoryRepair();
  expect(fetch).toHaveBeenCalledTimes(2);expect(execFileSync).toHaveBeenCalledTimes(2);
  expect(vi.mocked(execFileSync).mock.calls.map(call=>(call[1] as string[]).slice(4,9))).toEqual([
   ['migration','repair',CANONICAL,'--status','applied'],['migration','repair',LEGACY,'--status','reverted'],
  ]);
 });
});
