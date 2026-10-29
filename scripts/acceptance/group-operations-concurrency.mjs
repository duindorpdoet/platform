import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { requireLocalTogetherDatabase, sql, parallelSql } from './together-fixtures.mjs';
requireLocalTogetherDatabase();
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,event='duindorp-halloween-2026';
const options={auth:{persistSession:false,autoRefreshToken:false}};
async function actor(email,password='local-test-only'){const client=createClient(url,key,options);assert.equal((await client.auth.signInWithPassword({email,password})).error,null);return client;}
const admin=await actor('admin@example.invalid');
const privileged=createClient(url,process.env.SUPABASE_SECRET_KEY,options),email=`group-ops-${randomUUID()}@example.invalid`,password=randomUUID();
const created=await privileged.auth.admin.createUser({email,password,email_confirm:true});assert.equal(created.error,null);
sql(`insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) select id,'${created.data.user.id}','groups_manage','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='${event}';`);
const clients=[admin,await actor(email,password)];
async function rpc(name,args,client=admin){const result=await client.schema('api').rpc(name,args);assert.equal(result.error,null,`${name}: ${result.error?.message}`);return result.data;}
const before=sql(`select jsonb_build_array((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),(select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p),(select md5(jsonb_agg(to_jsonb(m) order by m.party_id,m.registration_id)::text) from app_private.together_memberships m),(select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p));`);
const preview=await rpc('admin_group_operations_preview',{_event_slug:event});
const commands=clients.map(()=>({_event_slug:event,_action:'reset',_input_hash:preview.inputHash,_payload:{confirmation:'ALLE GROEPEN TERUGZETTEN'},_idempotency_key:randomUUID()}));
const results=await Promise.all(clients.map((client,i)=>client.schema('api').rpc('admin_group_operations_apply',commands[i])));
assert.equal(results.filter(r=>!r.error).length,1);assert.equal(results.filter(r=>r.error?.message==='STALE_GROUP_INPUT').length,1);
const winner=results.findIndex(r=>!r.error);assert.deepEqual(await rpc('admin_group_operations_apply',commands[winner],clients[winner]),results[winner].data);
assert.equal(sql(`select jsonb_build_array((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),(select md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p),(select md5(jsonb_agg(to_jsonb(m) order by m.party_id,m.registration_id)::text) from app_private.together_memberships m),(select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p));`),before);
assert.equal(sql('select count(*) from app_private.group_registrations where superseded_at is null'),'0');
// Real concurrent PostgreSQL dispatches share the production mutex. Both try the same last reception gap.
sql(`update app_private.event_route_settings set first_start_at=date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '1 hour',global_ordinary_stop_at=clock_timestamp()+interval '2 hours',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '3 hours',finale_closes_at=clock_timestamp()+interval '4 hours',finale_max_concurrent_groups=20,finale_max_concurrent_children=500,finale_available=true,planner_mode='dynamic',final_portal_id='12000000-0000-0000-0000-000000000030';
 update app_private.portals set operation_status=case when system_number in (1,30) then 'open'::app_private.portal_operation_status else 'closed'::app_private.portal_operation_status end;
 update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '4 hours',visit_minutes=6,buffer_minutes=2,max_concurrent_groups=1,max_children_per_visit=30;
 -- The contested ordinary gate stays at one place. The separately configured
 -- finale needs its own twenty physical places for these dispatch forecasts.
 update app_private.portal_windows set max_concurrent_groups=20 where portal_id='12000000-0000-0000-0000-000000000030';
 update app_private.start_points set active=true;
 update app_private.walking_groups set retired_at=null,status='draft' where id in ('23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002');
 insert into app_private.group_registrations(group_id,registration_id,assignment_revision) select old.group_id,old.registration_id,(select max(a.assignment_revision)+1 from app_private.group_registrations a where a.registration_id=old.registration_id) from (select distinct on(registration_id) * from app_private.group_registrations where group_id in ('23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002') order by registration_id,assignment_revision desc) old;
`);
const groups=['23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002'];
const pointId='20000000-0000-0000-0000-000000000001';
await rpc('admin_startregie_confirm_point',{_event_slug:event,_point_id:pointId,_expected_version:Number(sql(`select version from app_private.start_points where id='${pointId}'`))});
const runs=[];
for(const [index,group] of groups.entries()){
 const schedule=await rpc('admin_startregie_move_group',{_group_id:group,_start_point_id:pointId,_starts_at:new Date(Math.floor(Date.now()/600000)*600000-(index+1)*600000).toISOString(),_expected_group_version:Number(sql(`select version from app_private.walking_groups where id='${group}'`)),_preference_match:'neutral',_reason:'Isolated concurrent live dispatch reservation test'});
 await rpc('admin_startregie_confirm_and_send',{_event_slug:event,_expected_revisions:[{id:schedule.id,revision:schedule.revision}],_expected_settings_version:Number(sql(`select settings_version from app_private.events where slug='${event}'`)),_idempotency_key:randomUUID()});
 const run=sql(`insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at) values('${group}','${schedule.id}','live',clock_timestamp()) returning id;`);
 sql(`insert into app_private.run_participants(run_id,registration_child_id,attendance) select '${run}',c.id,'present' from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id and a.group_id='${group}' and a.superseded_at is null where c.participation_status='active';`);
 runs.push(run);
}
await Promise.all(runs.map(run=>parallelSql(`begin;select app_private.dispatch_next_stop('${run}',clock_timestamp());commit;`)));
assert.equal(sql(`select count(*) from app_private.portal_reservations where portal_id='12000000-0000-0000-0000-000000000001' and status='active'`),'1');
assert.equal(sql(`select count(*) from app_private.run_stops where portal_id='12000000-0000-0000-0000-000000000001' and run_id in('${runs.join("','")}')`),'1');
console.log(JSON.stringify({status:'pass',checks:['two authorized reset writers commit once or return a stale preview','exact reset retry returns the original receipt','children, payments, together identities and immutable publications reconcile byte-for-byte','two genuinely concurrent dispatch transactions cannot both claim the final physical reception interval']}));
