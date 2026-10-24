import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';

// Commits only synthetic local fixtures. CI resets this isolated database after
// the probe; this script cannot target a hosted database or use a remote URL.
const container=requireLocalTogetherDatabase();
const groups=['23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002'];
const portal='12000000-0000-0000-0000-000000000028';
assert.equal(sql(`select count(*) from app_private.group_runs where group_id=any(array['${groups.join("','")}']::uuid[])`),'0','requires fresh, isolated fixtures');
const protectedRows=()=>sql(`select jsonb_build_object(
 'plans',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.route_plan_stops p),
 'arrivals',(select md5(coalesce(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id),'[]')::text) from app_private.run_stop_arrivals a),
 'payments',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.payment_requests p),
 'credentials',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]')::text) from app_private.portal_credentials c))`);
const before=protectedRows();
sql(`begin;
 update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours';
 update app_private.start_slots set starts_at=now()-interval '1 minute';
 update app_private.event_route_settings set first_start_at=now()-interval '1 hour',global_ordinary_stop_at=now()+interval '2 hours',
  allowed_personal_stop_times=array[now()+interval '1 hour'],ordinary_visit_seconds=60,route_buffer_seconds=0,
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=now()-interval '10 minutes',
  finale_last_arrival_at=now()+interval '4 hours',finale_closes_at=now()+interval '5 hours',finale_show_seconds=60,
  finale_turnover_seconds=0,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
 update app_private.portals set operation_status='closed' where id not in ('${portal}','12000000-0000-0000-0000-000000000030');
 update app_private.portal_windows set max_children_per_visit=6,max_concurrent_groups=1 where portal_id='${portal}';
 insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
  select g.id,coalesce((select max(s.revision) from app_private.group_schedule_revisions s where s.group_id=g.id),0)+1,
   'published',g.start_slot_id,now()+interval '2 hours',now()+interval '1 hour','neutral',now()
  from app_private.walking_groups g where g.id=any(array['${groups.join("','")}']::uuid[]);
 update app_private.walking_groups g set route_mode='dynamic',current_schedule_revision_id=(select id from app_private.group_schedule_revisions s where s.group_id=g.id order by revision desc limit 1)
  where g.id=any(array['${groups.join("','")}']::uuid[]);
 commit;`);
const observer='evening-capacity-'+randomUUID();
function start(group) {
 return `set local role authenticated;select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
  select api.run_start('${group}',array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster('${group}')) v),
   (api.group_snapshot('${group}')#>>'{group,version}')::integer,'${randomUUID()}','physical-last-slot');`;
}
function transaction(query,onOutput=()=>{}) {
 const child=spawn('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1']);
 let output='',error='';
 const done=new Promise((resolve,reject)=>{child.stdout.on('data',value=>{output+=value;onOutput(output);});child.stderr.on('data',value=>{error+=value;});child.on('error',reject);child.on('close',code=>code===0?resolve(output):reject(new Error(error||`Transaction exited ${code}`)));});
 child.stdin.end(query);return done;
}
let second;
const first=transaction(`begin;set local lock_timeout='4s';set local statement_timeout='12s';
 select 1 from app_private.events where slug='duindorp-halloween-2026' for no key update;
 select 'CAPACITY_LOCKED';
 do $$begin for tick in 1..200 loop
  perform pg_stat_clear_snapshot();
  if exists(select 1 from pg_stat_activity where application_name='${observer}' and wait_event_type='Lock') then return; end if;
  perform pg_sleep(.01);
 end loop;raise exception 'SECOND_GROUP_DID_NOT_CONTEND';end $$;
 ${start(groups[0])}commit;`,output=>{
 if(output.includes('CAPACITY_LOCKED')&&!second)second=transaction(`begin;set local lock_timeout='4s';set local statement_timeout='12s';set local application_name='${observer}';${start(groups[1])}commit;`);
});
await first;
assert.ok(second,'second real run-start command reached the lock barrier');
await second;
const result=JSON.parse(sql(`select jsonb_build_object(
 'bookings',(select count(*) from app_private.portal_reservations where portal_id='${portal}' and status in ('held','active')),
 'children',(select sum(child_count) from app_private.portal_reservations where portal_id='${portal}' and status in ('held','active')),
 'runs',(select count(*) from app_private.group_runs where group_id=any(array['${groups.join("','")}']::uuid[])),
 'released',(select count(*) from app_private.group_runs r join app_private.run_stops s on s.id=r.current_stop_id where coalesce(s.portal_id,(select p.portal_id from app_private.route_plan_stops p where p.id=s.plan_stop_id))='${portal}'),
 'waiting',(select count(*) from app_private.group_runs where group_id='${groups[1]}' and current_stop_id is null and status='live'),
 'previewEligible',(select (app_private.assess_ordinary_portal(event_id,'${groups[1]}','${portal}',(select reserved_from from app_private.portal_reservations where portal_id='${portal}' and status='active' limit 1),5)->>'eligible')::boolean from app_private.walking_groups where id='${groups[1]}'))`));
assert.deepEqual(result,{bookings:1,children:1,runs:2,released:1,waiting:1,previewEligible:false});
assert.equal(protectedRows(),before,'concurrent starts preserve original plans, actual arrivals, payments and QR credentials');
console.log(JSON.stringify({status:'pass',checks:['two actual run-start commands contend for the final physical group slot','one reservation and one released destination commit','other group waits without overbooking or an unsuitable address','capacity preview agrees after the competing commit','existing plans, arrivals, payments and credentials are unchanged']}));
