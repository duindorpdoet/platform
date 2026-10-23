import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {createTogetherFixtures,requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';

requireLocalTogetherDatabase();
const eventSlug='duindorp-halloween-2026';
const options={auth:{persistSession:false,autoRefreshToken:false}};
const client=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,options);
const signed=await client.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'});
assert.equal(signed.error,null);
async function rpc(name,args){const result=await client.schema('api').rpc(name,args);if(result.error)throw new Error(`${name}:${result.error.code}:${result.error.message}`);return result.data;}
async function policy(maximum,target=null){
 const preview=await rpc('admin_group_size_policy_preview',{_event_slug:eventSlug,_max_group_size:maximum,_target_group_size:target});
 return rpc('admin_group_size_policy_save',{_event_slug:eventSlug,_max_group_size:maximum,_target_group_size:target,_expected_settings_version:preview.settingsVersion,_expected_impact_hash:preview.impactHash,_reason:'Afzonderlijke lokale grens- en gelijktijdigheidsproef'});
}
function pair(){return [createTogetherFixtures(1,1,14)[0],createTogetherFixtures(1,1,12)[0]];}
async function previewPair(source,target){return rpc('admin_together_merge_preview',{_event_slug:eventSlug,_source_party_id:source.partyId,_target_party_id:target.partyId});}
function mergeArgs(preview,key=randomUUID()){
 return {_event_slug:eventSlug,_source_party_id:preview.source.partyId,_target_party_id:preview.target.partyId,
  _expected_source_state:preview.source.stateToken,_expected_target_state:preview.target.stateToken,
  _reason:'Twee complete gezinnen expliciet samen beoordeeld',_idempotency_key:key};
}

await policy(30);
const [source,target]=pair(),preview=await previewPair(source,target);
assert.equal(preview.projectedChildren,26);assert.equal(preview.maxGroupSize,30);assert.equal(preview.canMerge,true);
const args=mergeArgs(preview),merged=await rpc('admin_merge_together_parties',args);
assert.equal(sql(`select app_private.together_party_child_count('${target.partyId}')`),'26');
assert.deepEqual(await rpc('admin_merge_together_parties',args),merged,'identical retry must return its receipt');
const mismatch=await client.schema('api').rpc('admin_merge_together_parties',{...args,_reason:'Andere inhoud onder dezelfde sleutel wordt geweigerd'});
assert.equal(mismatch.error?.message,'IDEMPOTENCY_CONFLICT');

await policy(25);
const [blockedSource,blockedTarget]=pair(),blocked=await previewPair(blockedSource,blockedTarget);
assert.equal(blocked.canMerge,false);assert.ok(blocked.blockers.includes('over_capacity'));assert.equal(blocked.maxGroupSize,25);
const denied=await client.schema('api').rpc('admin_merge_together_parties',mergeArgs(blocked));
assert.equal(denied.error?.message,'MERGE_BLOCKED');
assert.equal(sql(`select app_private.together_party_child_count('${blockedSource.partyId}')`),'14');
assert.equal(sql(`select app_private.together_party_child_count('${blockedTarget.partyId}')`),'12');

await policy(30);
const stale=await previewPair(blockedSource,blockedTarget);
await policy(18);
const staleResult=await client.schema('api').rpc('admin_merge_together_parties',mergeArgs(stale));
assert.equal(staleResult.error?.code,'40001','a policy change invalidates an open merge preview');
assert.equal(sql(`select app_private.together_party_child_count('${target.partyId}')`),'26','lowering preserves the existing approved bundle');

// Two authenticated administrators prepare against the same event revision.
const privileged=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.SUPABASE_SECRET_KEY,options);
const otherId=randomUUID(),otherEmail=`policy-admin-${otherId}@example.invalid`,password=randomUUID();
const created=await privileged.auth.admin.createUser({id:otherId,email:otherEmail,password,email_confirm:true});
assert.equal(created.error,null);
const actualId=created.data.user.id;
sql(`insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) select id,'${actualId}','groups_manage','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='${eventSlug}';`);
const other=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,options);
assert.equal((await other.auth.signInWithPassword({email:otherEmail,password})).error,null);
const firstPreview=await rpc('admin_group_size_policy_preview',{_event_slug:eventSlug,_max_group_size:30,_target_group_size:null});
const secondPreview=await other.schema('api').rpc('admin_group_size_policy_preview',{_event_slug:eventSlug,_max_group_size:45,_target_group_size:null});
assert.equal(secondPreview.error,null);assert.equal(secondPreview.data.settingsVersion,firstPreview.settingsVersion);
const responses=await Promise.all([
 client.schema('api').rpc('admin_group_size_policy_save',{_event_slug:eventSlug,_max_group_size:30,_target_group_size:null,_expected_settings_version:firstPreview.settingsVersion,_expected_impact_hash:firstPreview.impactHash,_reason:'Eerste beheerder in echte parallelle schrijfproef'}),
 other.schema('api').rpc('admin_group_size_policy_save',{_event_slug:eventSlug,_max_group_size:45,_target_group_size:null,_expected_settings_version:secondPreview.data.settingsVersion,_expected_impact_hash:secondPreview.data.impactHash,_reason:'Tweede beheerder in echte parallelle schrijfproef'}),
]);
assert.equal(responses.filter(result=>!result.error).length,1);
assert.equal(responses.filter(result=>result.error?.code==='40001').length,1);
assert.equal(sql(`select count(*) from app_private.audit_events where action='group_size_limit.updated' and minimal_change->>'reason' in('Eerste beheerder in echte parallelle schrijfproef','Tweede beheerder in echte parallelle schrijfproef')`),'1');
console.log(JSON.stringify({status:'pass',checks:['intact 14+12 bundle at maximum 30','maximum 25 blocks the same 26-child merge','exact retry and mismatched idempotency content','lowering preserves existing members and invalidates stale preview','two real authenticated administrators: one commit and one version conflict']}));
