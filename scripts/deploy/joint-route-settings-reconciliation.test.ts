import { describe,expect,it } from 'vitest';
import { JOINT_ROUTE_SETTINGS_MIGRATION,jointRouteSettingsInitializationQuery,reconcileJointRouteSettingsInitialization } from './joint-route-settings-reconciliation.mjs';
import { compareFingerprints,preservationQuery } from './redesign-backup.mjs';

const table='app_private.event_route_settings',versions=[JOINT_ROUTE_SETTINGS_MIGRATION];
const old={event_id:'main-event',version:27,updated_at:'2026-10-30T07:17:23.123456Z',final_portal_id:'p38',
  finale_opens_at:'2026-10-31T17:00:00Z',finale_max_concurrent_groups:2,allowed_personal_stop_times:['19:00','20:00'],nested:{unchanged:['one','two']}};
const other={...old,event_id:'other-event',version:12};
const expectedTargets=[{event_id:old.event_id,organizer_coverage_portal_ids:['p02','p12']},{event_id:other.event_id,organizer_coverage_portal_ids:[]}];
const add=(row:typeof old,targets:string[])=>({...row,max_total_walking_seconds:3900,max_early_finish_seconds:1800,organizer_coverage_portal_ids:targets,route_policy_version:1});
const before=()=>({capturedAt:'2026-10-30T08:00:00Z',migrationApplied:false,tableExists:true,rows:[old,other],expectedTargets});
const after=()=>({...before(),capturedAt:'2026-10-30T08:00:01Z',migrationApplied:true,rows:[add(old,['p02','p12']),add(other,[])]});

describe('exact initialization of joint route policy settings',()=>{
  it('accepts exactly the four defaults and ordered, independently derived targets while preserving every original field',()=>{
    expect(reconcileJointRouteSettingsInitialization(before(),after(),versions)).toEqual({failures:[],reconciledTables:[table],initializedSettingsRows:2});
    expect(reconcileJointRouteSettingsInitialization(before(),{...after(),migrationApplied:false},versions).failures).toEqual([]);
    expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[...after().rows].reverse()},versions).failures).toEqual([]);
  });
  it('rejects deleted, added, duplicate and reassigned original rows',()=>{
    for(const rows of [
      after().rows.slice(0,1), [...after().rows,add({...old,event_id:'new-event'},[])],
      [after().rows[0],after().rows[0]], [after().rows[0],{...after().rows[1],event_id:'reassigned'}],
    ])expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows},versions).failures).toEqual([table]);
  });
  it('rejects every old-field mutation, including version, timestamps, arrays and nested values',()=>{
    for(const change of [
      {version:28},{updated_at:'2026-10-30T08:00:01Z'},{final_portal_id:'other-finale'},
      {finale_max_concurrent_groups:3},{allowed_personal_stop_times:['20:00','19:00']},
      {nested:{unchanged:['one','changed']}},{unreviewed_extra_column:true},
    ])expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[{...after().rows[0],...change},after().rows[1]]},versions).failures).toEqual([table]);
    const removed={...after().rows[0]} as Record<string,unknown>&{event_id:string};delete removed.updated_at;
    expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[removed,after().rows[1]]},versions).failures).toEqual([table]);
  });
  it('rejects default tampering, missing new fields, target reordering and targets on unrelated events',()=>{
    for(const change of [
      {max_total_walking_seconds:3600},{max_early_finish_seconds:0},{route_policy_version:2},
      {organizer_coverage_portal_ids:['p12','p02']},{organizer_coverage_portal_ids:['p02']},
      {organizer_coverage_portal_ids:['p02','p12','p38']},
    ])expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[{...after().rows[0],...change},after().rows[1]]},versions).failures).toEqual([table]);
    for(const column of ['max_total_walking_seconds','max_early_finish_seconds','organizer_coverage_portal_ids','route_policy_version']){
      const missing={...after().rows[0]} as Record<string,unknown>&{event_id:string};delete missing[column];
      expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[missing,after().rows[1]]},versions).failures).toEqual([table]);
    }
    expect(reconcileJointRouteSettingsInitialization(before(),{...after(),rows:[after().rows[0],add(other,['p02','p12'])]},versions).failures).toEqual([table]);
  });
  it('requires the reviewed pending migration and never permits row deltas on redeploy',()=>{
    expect(reconcileJointRouteSettingsInitialization(before(),after(),[]).failures).toEqual([table]);
    expect(reconcileJointRouteSettingsInitialization({...before(),migrationApplied:true},after(),versions).failures).toEqual([table]);
    expect(reconcileJointRouteSettingsInitialization(after(),after(),versions)).toEqual({failures:[],reconciledTables:[],initializedSettingsRows:0});
    expect(reconcileJointRouteSettingsInitialization(after(),{...after(),rows:[{...after().rows[0],max_total_walking_seconds:3901},after().rows[1]]},versions).failures).toEqual([table]);
    expect(reconcileJointRouteSettingsInitialization({...before(),rows:after().rows},after(),versions).failures).toEqual([table]);
  });
  it('fails closed for missing or inconsistent source rows and target derivations',()=>{
    for(const changes of [
      {tableExists:false},{expectedTargets:[]},{expectedTargets:[expectedTargets[0],expectedTargets[0]]},
      {expectedTargets:[{...expectedTargets[0],organizer_coverage_portal_ids:['p02','p02']},expectedTargets[1]]},
    ])expect(reconcileJointRouteSettingsInitialization({...before(),...changes},after(),versions).failures).toEqual([table]);
    expect(reconcileJointRouteSettingsInitialization(undefined,after(),versions).failures).toEqual([table]);
  });
  it('derives the exact migration filter and stores full rows in the same snapshot as all other fingerprints',()=>{
    const catalog=[{schema:'app_private',name:'event_route_settings',columns:['event_id','version','updated_at']}];
    const query=jointRouteSettingsInitializationQuery(catalog);
    for(const fragment of ["to_jsonb(s)","e.slug='duindorp-halloween-2026'","p.event_id=s.event_id","p.system_code in('P-02','P-12')",
      "p.lifecycle_status='active'","p.approval_status='approved'","p.operation_status in('open','scheduled')",
      'p.id is distinct from s.final_portal_id',"array_position(array['P-02','P-12'],p.system_code)","else '[]'::jsonb end"])
      expect(query).toContain(fragment);
    expect(query).not.toMatch(/\b(insert|update|delete|alter)\b/i);
    expect(query).not.toContain('portal_location_ready');
    const absent=jointRouteSettingsInitializationQuery([]);
    expect(absent).not.toContain('from app_private.event_route_settings');
    const atomic=preservationQuery(catalog);
    expect(atomic).toContain("'rows',(select jsonb_agg(fingerprint)");
    expect(atomic).toContain("'jointRouteSettingsInitialization',(select joint_route_settings_initialization from route_settings)");
    const reconciliation=reconcileJointRouteSettingsInitialization(before(),after(),versions);
    const original=[{table:'app_private.walking_groups',rows:18,sha256:'unchanged'}];
    expect(compareFingerprints(original,[{...original[0],sha256:'mutation'}]).filter(changed=>!reconciliation.reconciledTables.includes(changed))).toEqual(['app_private.walking_groups']);
  });
});
