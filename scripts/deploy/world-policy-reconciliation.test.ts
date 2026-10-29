import { expect, it } from 'vitest';
import { WORLD_POLICY_MIGRATION, reconcileWorldPolicyInitialization, worldPolicyInitializationQuery } from './world-policy-reconciliation.mjs';
import { compareFingerprints, preservationQuery } from './redesign-backup.mjs';

const start='2026-10-29T12:00:00Z',during='2026-10-29T12:01:00Z',end='2026-10-29T12:02:00Z';
const old={event_id:'10000000-0000-0000-0000-000000000001',version:1,missing_worlds:['vampierrijk'],fingerprint:'old-fingerprint',created_at:'2026-10-01T12:00:00Z'};
const retired={...old,policy_status:'retired',source_fingerprint:null,activated_at:null,activated_by:null,activation_reason:null};
const expected={event_id:old.event_id,version:2,missing_worlds:['geestenwereld','vampierrijk'],policy_status:'active',source_fingerprint:'derived-source',fingerprint:'derived-active'};
const added={...expected,created_at:during,activated_at:during,activated_by:null,activation_reason:'Definitief huizenaanbod bij gesloten huisinschrijving'};
const audit={id:'11',event_id:old.event_id,actor_id:null,action:'world.coverage.active',resource_type:'event',resource_id:old.event_id,correlation_id:null,minimal_change:{policyVersion:2,missingWorlds:expected.missing_worlds,previousPolicyVersion:null},created_at:during};
const before={capturedAt:start,migrationApplied:false,policyRows:[old],expected:[expected],auditBoundary:'10',auditOriginal:{rows:10,sha256:'every-original-audit-field'},addedAuditRows:[]};
const after={...before,capturedAt:end,migrationApplied:true,policyRows:[retired,added],auditBoundary:'11',addedAuditRows:[audit]};
const versions=[WORLD_POLICY_MIGRATION];

it('permits only one derived initial policy per event and its exact closed-event audit append',()=>{
  expect(reconcileWorldPolicyInitialization(before,after,versions)).toEqual({failures:[],reconciledTables:['app_private.world_coverage_policies','app_private.audit_events'],addedPolicies:1,addedCoverageAuditEvents:1});
  const provisional={...expected,policy_status:'provisional',fingerprint:'derived-provisional'};
  const openBefore={...before,expected:[provisional]};
  const openAfter={...after,policyRows:[retired,{...added,...provisional,activated_at:null,activation_reason:null}],addedAuditRows:[]};
  expect(reconcileWorldPolicyInitialization(openBefore,openAfter,versions).failures).toEqual([]);
});

it('preserves every old policy column and row, including the original version, worlds and timestamps',()=>{
  for(const policyRows of [
    [added], [retired], [retired,added,added],
    [{...retired,missing_worlds:[]},added], [{...retired,fingerprint:'rewritten'},added],
    [{...retired,created_at:during},added], [{...retired,version:3},added],
    [{...retired,policy_status:'active'},added],
  ]) expect(reconcileWorldPolicyInitialization(before,{...after,policyRows},versions).failures).toContain('app_private.world_coverage_policies');
});

it('rejects invented, missing, extra or materially different initialization policies',()=>{
  for(const change of [
    {version:3},{event_id:'other'},{missing_worlds:[]},{fingerprint:'invented'},
    {source_fingerprint:'invented'},{policy_status:'pending'},{activated_by:'user'},
    {activation_reason:'approved automatically'},{activated_at:null},{created_at:'2026-10-01T12:00:00Z'},
    {created_at:'2026-10-29T12:05:00Z'},{unexpected:'hidden-data'},
  ]) expect(reconcileWorldPolicyInitialization(before,{...after,policyRows:[retired,{...added,...change}]},versions).failures).toContain('app_private.world_coverage_policies');
});

it('never waives original audits or unrelated audit additions',()=>{
  for(const change of [
    {auditOriginal:{rows:9,sha256:'deleted'}},{auditOriginal:{rows:10,sha256:'rewritten'}},
    {addedAuditRows:[]},{addedAuditRows:[audit,audit]},
    ...[{actor_id:'admin'},{resource_id:'other'},{action:'group_schedule.published'},
      {minimal_change:{...audit.minimal_change,policyVersion:3}},{correlation_id:'unrelated'},
      {created_at:'2026-10-01T12:00:00Z'},{id:'9'}].map(change=>({addedAuditRows:[{...audit,...change}]})),
  ]) expect(reconcileWorldPolicyInitialization(before,{...after,...change},versions).failures).toContain('app_private.audit_events');
});

it('requires the exact pending reviewed migration and refuses another initialization on redeploy',()=>{
  expect(reconcileWorldPolicyInitialization(before,after,[]).failures).not.toEqual([]);
  const installed={...after,expected:[],addedAuditRows:[]};
  expect(reconcileWorldPolicyInitialization(installed,installed,versions)).toMatchObject({failures:[],reconciledTables:[],addedPolicies:0,addedCoverageAuditEvents:0});
  expect(reconcileWorldPolicyInitialization(installed,{...installed,policyRows:[...installed.policyRows,{...added,version:3}]},versions).failures).toContain('app_private.world_coverage_policies');
});

it('keeps every unrelated table fingerprint strict and needs no new migration helper on the source database',()=>{
  const original=[{table:'app_private.walking_groups',rows:18,sha256:'original'}];
  const reconciliation=reconcileWorldPolicyInitialization(before,after,versions);
  expect(compareFingerprints(original,[{...original[0],sha256:'changed'}]).filter(table=>!reconciliation.reconciledTables.includes(table))).toEqual(['app_private.walking_groups']);
  const query=worldPolicyInitializationQuery(before);
  expect(query).not.toContain('app_private.routing_position(');
  expect(query).not.toContain('app_private.refresh_world_coverage(');
  expect(query).toContain('app_private.portal_location_ready(p.id)');
  expect(query).not.toContain('app_private.world_coverage_missing_now(');
  expect(()=>worldPolicyInitializationQuery({...before,auditBoundary:'0; delete from app_private.events'})).toThrow('INVALID_COVERAGE_AUDIT_BASELINE');
  const atomic=preservationQuery([{schema:'app_private',name:'audit_events',columns:['id','minimal_change']}],before);
  expect(atomic).toContain("'rows',(select jsonb_agg(fingerprint)");
  expect(atomic).toContain("'worldPolicyInitialization',(select coverage_initialization from coverage)");
});
