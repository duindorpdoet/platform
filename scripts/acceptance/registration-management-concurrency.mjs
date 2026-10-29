// Independent Auth/PostgREST writers against a guarded LOCAL synthetic stack.
// No gateway/worker is invoked and no participant communication is delivered.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { requireLocalTogetherDatabase, sql } from './together-fixtures.mjs';

requireLocalTogetherDatabase();
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
if(!url||!key)throw new Error('LOCAL_REGISTRATION_AUTH_REQUIRED');
const event='duindorp-halloween-2026',reg='22000000-0000-0000-0000-000000000001',other='22000000-0000-0000-0000-000000000002';
const options={auth:{persistSession:false,autoRefreshToken:false}};
const admins=await Promise.all([0,1].map(async()=>{
 const client=createClient(url,key,options);
 assert.equal((await client.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'})).error,null);
 return client;
}));
async function rpc(name,args,client=admins[0]){const result=await client.schema('api').rpc(name,args);assert.equal(result.error,null,`${name}: ${result.error?.message}`);return result.data;}
const fixture=JSON.parse(sql(readFileSync('scripts/acceptance/fixtures/registration-management.sql','utf8')+'\nselect pg_temp.registration_management_fixture();'));
const target=fixture.target.groupId;
const third=randomUUID();
sql(`insert into app_private.walking_groups(id,event_id,code,status,route_mode) select '${third}',id,'SYNTHETIC-RACE-DESTINATION','draft','dynamic' from app_private.events where slug='${event}';`);
const initialPublished=sql('select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.group_start_publications p;');
const initialOtherMail=sql(`select coalesce(jsonb_agg(to_jsonb(o) order by o.id),'[]')::text from app_private.email_outbox o where o.payload->>'registrationId' is distinct from '${reg}'`);
const preview=registration=>rpc('admin_registration_management_preview',{_event_slug:event,_registration_id:registration});
function command(registration,action,payload,inputHash){return{_event_slug:event,_registration_id:registration,_action:action,_payload:payload,_input_hash:inputHash,_reason:'Synthetic concurrent household management acceptance',_idempotency_key:randomUUID()};}

// Different target choices on exactly the same preview cannot both win.
const before=await preview(reg);
const moves=[target,third].map(id=>command(reg,'move',{targetGroupId:id},before.inputHash));
const moved=await Promise.all(admins.map((client,index)=>client.schema('api').rpc('admin_registration_manage_apply',moves[index])));
assert.equal(moved.filter(result=>!result.error&&result.data.changed).length,1);
assert.equal(moved.filter(result=>result.error?.message==='STALE_VERSION').length,1);
const winner=moved.findIndex(result=>!result.error);
assert.deepEqual(await rpc('admin_registration_manage_apply',moves[winner],admins[winner]),moved[winner].data);
assert.equal(sql(`select count(*) from app_private.group_registrations where registration_id='${reg}' and superseded_at is null`),'1');
assert.equal(sql(`select count(*) from app_private.email_outbox where message_type='registration_group_changed' and payload->>'registrationId'='${reg}'`),'1');
assert.equal(sql(`select coalesce(jsonb_agg(to_jsonb(o) order by o.id),'[]')::text from app_private.email_outbox o where o.payload->>'registrationId' is distinct from '${reg}'`),initialOtherMail);

// Place both existing families together, then expose exactly one remaining
// physical child place in their already published departure slot.
let current=await preview(reg);
if(current.sourceGroup.id!==target)await rpc('admin_registration_manage_apply',command(reg,'move',{targetGroupId:target},current.inputHash));
const baselineChildren=Number(sql(`select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id='${target}' and a.superseded_at is null`));
sql(`update app_private.start_slots set max_children=${baselineChildren+1} where id=(select start_slot_id from app_private.group_schedule_revisions where id='${fixture.target.scheduleId}');`);
const editPreviews=await Promise.all([reg,other].map(preview));
const edits=editPreviews.map((item,index)=>command([reg,other][index],'edit_children',{children:[...item.children.map(child=>({id:child.id,firstName:child.firstName,ageAtEvent:child.ageAtEvent,accessibilityNote:child.accessibilityNote??''})),{firstName:`Synthetic last place ${index}`,ageAtEvent:8,accessibilityNote:''}]},item.inputHash));
const edited=await Promise.all(admins.map((client,index)=>client.schema('api').rpc('admin_registration_manage_apply',edits[index])));
assert.equal(edited.filter(result=>!result.error&&result.data.changed).length,1);
assert.equal(edited.filter(result=>result.error&&['STALE_VERSION','REGISTRATION_PHYSICAL_CAPACITY_OR_TIME_CONFLICT'].includes(result.error.message)).length,1);
assert.equal(Number(sql(`select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id='${target}' and a.superseded_at is null`)),baselineChildren+1);
assert.equal(sql('select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.group_start_publications p;'),initialPublished);
assert.equal(sql(`select count(*) from app_private.email_outbox where message_type='registration_group_changed' and payload->>'registrationId'='${other}'`),'0');
assert.equal(sql('select count(*) from app_private.registration_management_scopes'),'0');
assert.equal(sql('select count(*) from app_private.start_schedule_capacity_checks'),'0');
assert.equal(sql(`select count(*) from app_private.group_registrations where registration_id='${reg}' and superseded_at is null`),'1');
// A harmless child edit keeps the existing latest assignment mail eligible.
assert.equal(sql(`select api.worker_registration_management_mail_payload(o.id) is not null from app_private.email_outbox o where o.message_type='registration_group_changed' and o.payload->>'registrationId'='${reg}' and o.status='pending' order by o.created_at desc,o.id desc limit 1`),'t');
console.log(JSON.stringify({status:'pass',checks:['two independent move writers share one version-checked result','exact retry preserves one assignment and one family mail event','all other family outbox rows remain byte-for-byte unchanged','two concurrent additions cannot reserve the final physical child place twice','published starts remain immutable and scoped exceptions are cleaned up','child edits preserve the latest valid move notification']}));
