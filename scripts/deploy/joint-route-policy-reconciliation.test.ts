import { describe,it,expect } from 'vitest';
import { JOINT_ROUTE_POLICY_MIGRATION,reconcileJointRoutePolicyRelease,jointRoutePolicyReleaseQuery } from './joint-route-policy-reconciliation.mjs';

const old={policy_version:'joint-reception-v1',activated_at:'2026-10-29T17:00:00.000Z'};
const release={policy_version:'joint-reception-v2',activated_at:'2026-10-30T08:00:01.000Z'};
const baseline=()=>({capturedAt:'2026-10-30T08:00:00.000Z',migrationApplied:false,tableExists:true,rows:[{...old}]});
const migrated=()=>({capturedAt:'2026-10-30T08:00:02.000Z',migrationApplied:true,tableExists:true,rows:[{...old},{...release}]});
const table='app_private.joint_route_policy_releases';
const versions=[JOINT_ROUTE_POLICY_MIGRATION];
describe('the exact joint policy metadata append',()=>{
  it('accepts only the reviewed v2 append and unchanged complete original rows',()=>{
    expect(reconcileJointRoutePolicyRelease(baseline(),migrated(),versions)).toEqual({failures:[],reconciledTables:[table],addedPolicyReleases:1});
    // Local SQL dry runs deliberately do not write hosted migration history.
    expect(reconcileJointRoutePolicyRelease(baseline(),{...migrated(),migrationApplied:false},versions).failures).toEqual([]);
  });
  it('retains strict comparison when the migration is already installed',()=>{
    const before={...migrated(),capturedAt:'2026-10-30T08:00:03Z'};
    expect(reconcileJointRoutePolicyRelease(before,{...before,capturedAt:'2026-10-30T08:00:04Z'},versions)).toEqual({failures:[],reconciledTables:[],addedPolicyReleases:0});
    expect(reconcileJointRoutePolicyRelease(before,{...before,rows:[...before.rows,{...release,policy_version:'unreviewed'}]},versions).failures).toEqual([table]);
  });
  it('rejects old-row mutation, deletion, duplicate rows and unrelated appends',()=>{
    for(const rows of [
      [{...old,activated_at:release.activated_at},release],
      [release],
      [old,old,release],
      [old,release,release],
      [old,release,{...release,policy_version:'unreviewed'}],
      [old,{...release,policy_version:'joint-reception-v3'}],
      [old,{...release,extra:'unreviewed metadata'}],
    ])expect(reconcileJointRoutePolicyRelease(baseline(),{...migrated(),rows},versions).failures).toEqual([table]);
  });
  it('requires this migration, its missing prior row and an actual in-window timestamp',()=>{
    expect(reconcileJointRoutePolicyRelease(baseline(),migrated(),[]).failures).toEqual([table]);
    expect(reconcileJointRoutePolicyRelease({...baseline(),rows:[old,release]},migrated(),versions).failures).toEqual([table]);
    expect(reconcileJointRoutePolicyRelease(baseline(),{...migrated(),rows:[old]},versions).failures).toEqual([table]);
    for(const activated_at of ['2026-10-29T08:00:00Z','2026-10-30T08:00:03Z','not a timestamp'])
      expect(reconcileJointRoutePolicyRelease(baseline(),{...migrated(),rows:[old,{...release,activated_at}]},versions).failures).toEqual([table]);
    expect(reconcileJointRoutePolicyRelease(baseline(),{...migrated(),capturedAt:'2026-10-29T08:00:00Z'},versions).failures).toEqual([table]);
    expect(reconcileJointRoutePolicyRelease({...baseline(),tableExists:false},migrated(),versions).failures).toEqual([table]);
  });
  it('rejects an activation one microsecond before or after the captured window',()=>{
    const before={...baseline(),capturedAt:'2026-10-30T08:00:00.123456+00:00'};
    const after={...migrated(),capturedAt:'2026-10-30T08:00:00.123458+00:00'};
    for(const activated_at of ['2026-10-30T08:00:00.123455Z','2026-10-30T08:00:00.123459Z'])
      expect(reconcileJointRoutePolicyRelease(before,{...after,rows:[old,{...release,activated_at}]},versions).failures).toEqual([table]);
    for(const activated_at of ['2026-10-30T08:00:00.123456Z','2026-10-30T08:00:00.123458Z'])
      expect(reconcileJointRoutePolicyRelease(before,{...after,rows:[old,{...release,activated_at}]},versions).failures).toEqual([]);
  });
  it('uses fixed identifiers and returns an explicit missing-prerequisite snapshot',()=>{
    const query=jointRoutePolicyReleaseQuery([{schema:'app_private',name:'joint_route_policy_releases'}]);
    expect(query).toContain('from app_private.joint_route_policy_releases p');
    expect(query).toContain(`version='${JOINT_ROUTE_POLICY_MIGRATION}'`);
    expect(query).not.toMatch(/\b(insert|update|delete|grant|alter)\b/i);
    const absent=jointRoutePolicyReleaseQuery([]);
    expect(absent).not.toContain('from app_private.joint_route_policy_releases');
    expect(absent).toContain("to_regclass('app_private.joint_route_policy_releases') is not null");
  });
});
