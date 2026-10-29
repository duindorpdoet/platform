// Real independent Auth/PostgREST commits against an owned local test stack.
// The shared pgTAP fixture keeps every synthetic family and all start history.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { proposeJointRoutes } from '../../lib/domain/joint-route-planner.ts';
import { requireLocalTogetherDatabase, sql, parallelSql } from './together-fixtures.mjs';

requireLocalTogetherDatabase();
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
if(!url||!key||!['127.0.0.1','localhost','::1'].includes(new URL(url).hostname))throw new Error('LOCAL_JOINT_ROUTE_AUTH_REQUIRED');
const event='duindorp-halloween-2026';
const authOptions={auth:{persistSession:false,autoRefreshToken:false}};
const sessions=await Promise.all([0,1].map(async()=>{
 const client=createClient(url,key,authOptions);
 const result=await client.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'});
 assert.equal(result.error,null,'Synthetic admin must sign in through local Auth');
 return{client,session:result.data.session};
}));
assert.ok(new Set(sessions.map(item=>item.session?.access_token)).size===2,'Two independent authenticated sessions are required');
const admins=sessions.map(item=>item.client);
async function rpc(name,args,client=admins[0]){
 const result=await client.schema('api').rpc(name,args);
 assert.equal(result.error,null,`${name}: ${result.error?.message}`);
 return result.data;
}
async function until(query,expected){
 const deadline=Date.now()+3000;
 while(Date.now()<deadline){
  if(sql(query)===expected)return true;
  await new Promise(resolve=>setTimeout(resolve,25));
 }
 return false;
}
async function concurrentWriters(name,actions){
 const label='joint_route_race_'+randomUUID().replaceAll('-','');
 const blocker=parallelSql(`begin;set local application_name='${label}';
  select 1 from app_private.events where slug='${event}' for update;select pg_sleep(2);commit;`);
 const ready=await until(`select count(*)from pg_stat_activity where application_name='${label}' and wait_event='PgSleep'`,'1');
 if(!ready){await blocker;throw new Error('LOCAL_RACE_BARRIER_NOT_READY');}
 // Start both HTTP requests before inspecting their database wait state.
 const pending=actions.map(action=>Promise.resolve().then(action));
 const queued=await until(`select count(*)from pg_stat_activity where pid<>pg_backend_pid()and wait_event_type='Lock'and query like '%${name}%'`,'2');
 await blocker;
 const results=await Promise.all(pending);
 assert.ok(queued,'Both independent PostgREST writers must overlap behind the held event lock');
 return results;
}
function fixtureSql(path){
 const actual=realpathSync(path);
 return readFileSync(actual,'utf8').replace(/^\\ir\s+(.+)$/gm,(_,relative)=>fixtureSql(resolve(dirname(actual),relative.trim())));
}
assert.equal(sql('select count(*) from app_private.joint_route_plan_versions'),'0','Run this isolated proof after its own reset');
const fixture=JSON.parse(sql(fixtureSql('scripts/acceptance/fixtures/joint-route.sql')+'\nselect pg_temp.joint_canonical_fixture();'));
// A real single physical finale place, never extra capacity. The four existing
// appointments are ten minutes apart and each uses six show plus two turnover.
sql(`update app_private.event_route_settings set finale_max_concurrent_groups=1 where event_id=(select id from app_private.events where slug='${event}');
 update app_private.portal_windows set max_concurrent_groups=1 where portal_id='12000000-0000-0000-0000-000000000030';`);

function preserved(){
 return sql(`select md5(jsonb_build_object(
 'publications',(select jsonb_agg(to_jsonb(p)order by p.id)from app_private.group_start_publications p),
 'startAppointments',(select jsonb_agg(jsonb_build_object('groupId',g.id,'context',app_private.route_group_start_context(g.id)-array['scheduleId','planId','expectedFinaleArrivalAt'])order by g.id)from app_private.walking_groups g),
 'points',(select jsonb_agg(to_jsonb(p)order by p.id)from app_private.start_points p),
 'slots',(select jsonb_agg(to_jsonb(s)order by s.id)from app_private.start_slots s),
 'households',(select jsonb_agg(to_jsonb(h)order by h.id)from app_private.households h),
 'members',(select jsonb_agg(to_jsonb(m)order by m.household_id,m.user_id)from app_private.household_members m),
 'registrations',(select jsonb_agg(to_jsonb(r)order by r.id)from app_private.registrations r),
 'children',(select jsonb_agg(to_jsonb(c)order by c.id)from app_private.children c),
 'registeredChildren',(select jsonb_agg(to_jsonb(c)order by c.registration_id,c.child_id)from app_private.registration_children c),
 'assignments',(select jsonb_agg(to_jsonb(a)order by a.id)from app_private.group_registrations a),
 'payments',(select jsonb_agg(to_jsonb(p)order by p.id)from app_private.payment_requests p),
 'mail',(select jsonb_agg(to_jsonb(o)order by o.id)from app_private.email_outbox o)
 )::text);`);
}
const unchanged=preserved();
const countVersions=()=>Number(sql('select count(*) from app_private.joint_route_plan_versions'));
async function proposal(){
 const input=await rpc('admin_joint_route_planning_input',{_event_slug:event});
 const result=proposeJointRoutes(input);
 assert.equal(result.valid,true,JSON.stringify(result.conflicts.map(item=>item.code)));
 assert.equal(result.groups.length,4,'Every synthetic family must remain in the proposal');
 return result;
}
const args=(value,key=randomUUID())=>({_event_slug:event,_proposal:value,_confirmed:true,_reason:'Synthetic independent joint route concurrency acceptance',_idempotency_key:key});

// Identical retries arriving in separate real sessions commit one immutable
// version. The receipt is checked under the same event lock before staleness.
const first=await proposal(),sameCommand=args(first);
const retries=await concurrentWriters('admin_joint_route_plan_apply',admins.map(client=>()=>client.schema('api').rpc('admin_joint_route_plan_apply',sameCommand)));
assert.ok(retries.every(result=>!result.error),'Both identical real callbacks must succeed');
assert.deepEqual(retries[0].data,retries[1].data);
assert.equal(countVersions(),1,'An identical command creates exactly one accepted version');
assert.equal(preserved(),unchanged,'Route acceptance preserves starts, families, payments and all mail');

// Different reviewed commands for the same board cannot both replace it.
const fresh=await proposal();
const competing=await concurrentWriters('admin_joint_route_plan_apply',admins.map(client=>()=>client.schema('api').rpc('admin_joint_route_plan_apply',args(fresh))));
assert.equal(competing.filter(result=>!result.error).length,1);
assert.equal(competing.filter(result=>result.error?.message==='JOINT_ROUTE_PROPOSAL_STALE'&&result.error.code==='40001').length,1);
assert.equal(countVersions(),2);
assert.deepEqual(await rpc('admin_joint_route_plan_apply',sameCommand),retries[0].data,'An old exact retry still returns its original receipt without rewriting the newer board');
assert.equal(countVersions(),2);
assert.equal(preserved(),unchanged,'Concurrent proposals preserve every participant and published appointment');

// Neither draft has an active publication. Each independent direct schedule
// API writer asks for the same previously free finale place; only one may
// commit, including the deferred database capacity check at transaction end.
const draftGroups=[fixture.third.groupId,fixture.fourth.groupId];
assert.equal(sql(`select count(*)from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id)p where g.id in('${draftGroups[0]}','${draftGroups[1]}')`),'0');
const scheduleChoices=JSON.parse(sql(`select jsonb_agg(jsonb_build_object('groupId',g.id,'slotId',s.start_slot_id,'stopAt',settings.global_ordinary_stop_at,
 'finaleAt',settings.global_ordinary_stop_at+interval '50 minutes')order by g.id)
 from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
 join app_private.event_route_settings settings on settings.event_id=g.event_id where g.id in('${draftGroups[0]}','${draftGroups[1]}');`));
const finalWrites=await concurrentWriters('admin_save_group_schedule',admins.map((client,index)=>()=>{
 const choice=scheduleChoices[index];
 return client.schema('api').rpc('admin_save_group_schedule',{_group_id:choice.groupId,_start_slot_id:choice.slotId,
  _effective_stop_at:choice.stopAt,_expected_finale_arrival_at:choice.finaleAt,_queue_number:null,_preference_match:'neutral',
  _reason:'Synthetic direct schedule writers compete for one physical finale place'});
}));
assert.equal(finalWrites.filter(result=>!result.error).length,1);
assert.equal(finalWrites.filter(result=>result.error?.message==='FINALE_CAPACITY_EXCEEDED'&&result.error.code==='23514').length,1);
assert.equal(sql(`select count(*)from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
 join app_private.event_route_settings settings on settings.event_id=g.event_id where g.id in('${draftGroups[0]}','${draftGroups[1]}')
 and s.expected_finale_arrival_at=settings.global_ordinary_stop_at+interval '50 minutes'`),'1');
assert.equal(sql('select count(*)from app_private.start_schedule_capacity_checks'),'0','Commit-time collector leaves no scoped rows');
assert.equal(sql('select count(*)from app_private.registration_management_scopes'),'0');
assert.equal(preserved(),unchanged,'Direct finale corrections preserve start times, publications, families, payment and mail');
assert.equal(sql('select count(*)from app_private.group_runs'),'0','No route was started by a proposal or draft correction');
console.log(JSON.stringify({code:'JOINT_ROUTE_CONCURRENCY_VERIFIED',realSessions:2,observedConcurrentLockWaiters:2,sameCommandVersions:1,differentCommandWinners:1,
 directFinaleWinners:1,finaleCapacity:1,capacityCollectorRows:0,allFamiliesRetained:true,publishedStartsUnchanged:true,paymentUnchanged:true,noExternalDeliveries:true}));
